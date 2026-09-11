import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import '../models/beacon.dart';
import '../models/store_map.dart';
import 'ble_scanner_service.dart';
import 'motion_service.dart';
import 'activity_logger.dart';
import 'pathfinding_service.dart';
import 'zone_snap_service.dart';

enum NavigationStatus { idle, navigating, checkingLocation, rerouting, arrived }

/// Central MVP state: current zone (from BLE), chosen destination, the
/// resulting route, and the live PDR-tracked position. Rebuilds the UI via
/// [ChangeNotifier] whenever any of those change.
class NavigationController extends ChangeNotifier {
  NavigationController({
    required this.storeMap,
    required this.bleScanner,
    required this.motionService,
    ZoneSnapService? zoneSnap,
    PathfindingService? pathfinder,
    this.allowOffRouteBeacons = true,
    this.logger,
  })  : _zoneSnap = zoneSnap ?? ZoneSnapService(),
        _pathfinder = pathfinder ?? PathfindingService() {
    _rssiSub = bleScanner.rssiStream.listen(_onRssiUpdate);
    _stepSub = motionService.stepDistances.listen(_onStep);
    _motionErrorSub = motionService.errors.listen(
          (e) => _log('NAV## motion error: $e'),
    );
    // TODO: wire up motionService.headingStream once movement-direction-based
    // backward-walking detection is implemented — see earlier discussion.
    // dispose() below intentionally still cancels this subscription so the
    // wiring only needs to happen in one place once it's added.
  }

  /// A newly-"nearest" beacon must win this many consecutive RSSI updates
  /// before it's actually committed to [currentBeacon] — a single noisy
  /// reading was enough to flip zones (and misreport which beacon you were
  /// near) without this.
  static const int _requiredConsecutiveReadings = 2;

  /// How much stronger a new candidate beacon's RSSI must be before the app
  /// is willing to switch away from the current one.
  static const double _beaconSwitchThresholdDb = 8.0;
  static const Duration _candidatePersistence = Duration(milliseconds: 900);
  static const Duration _beaconSwitchCooldown = Duration(milliseconds: 1500);
  static const double _visualBlendPerTick = 0.35;
  static const double _maxBeaconCorrectionResetMeters = 8.0;
  static const Duration _followTickInterval = Duration(milliseconds: 50);

  /// Extra buffer (meters) added on top of "plausible distance walked" when
  /// deciding whether a candidate beacon is physically reachable. Without
  /// this, a slightly under-calibrated stride length, or a candidate
  /// confirming a beat or two later than the very first step, could reject
  /// a beacon the user has genuinely just reached.
  static const double _reachabilityToleranceMeters = 2.5;

  final StoreMap storeMap;
  final BleScannerService bleScanner;
  final MotionService motionService;
  final ZoneSnapService _zoneSnap;
  final PathfindingService _pathfinder;
  bool allowOffRouteBeacons;
  final ActivityLogger? logger;
  StreamSubscription<Map<String, double>>? _rssiSub;
  StreamSubscription<double>? _stepSub;
  StreamSubscription<String>? _motionErrorSub;
  StreamSubscription<double>? _headingSub; // reserved — see TODO in constructor
  Timer? _followTimer;

  final _zoneEnteredController = StreamController<Beacon>.broadcast();

  /// Fires exactly once each time [currentBeacon] is freshly confirmed as a
  /// *new* zone (not on every RSSI update while already in one) — the UI
  /// listens for this to show zone-arrival notifications (e.g. nearby
  /// offers) without re-showing one on every rebuild.
  Stream<Beacon> get zoneEnteredStream => _zoneEnteredController.stream;

  String? _pendingBeaconId;
  int _pendingBeaconCount = 0;
  DateTime? _pendingBeaconSince;
  DateTime? _lastBeaconSwitchAt;
  int _rssiUpdateCount = 0;

  Beacon? currentBeacon;
  Beacon? destinationBeacon;
  List<Beacon> currentPath = [];
  double _segmentProgressMeters = 0.0;
  int _segmentStepCount = 0;

  /// Raw, unclamped distance walked (meters) since the last confirmed
  /// beacon. Unlike [_segmentProgressMeters] — which is clamped to the
  /// *current route edge's* length purely for arrow-positioning — this is
  /// used only to judge whether a *different* candidate beacon is
  /// physically plausible to have reached, so it must never be capped to
  /// any one edge.
  double _metersSinceBeacon = 0.0;

  /// Total distance of [currentPath], in meters. Null when there's no route.
  double? currentDistanceMeters;

  /// Where the arrow is gliding toward — set on each beacon confirmation.
  Offset? _targetPosition;

  /// Arrow position — eased toward [_targetPosition] by the follow timer.
  Offset? liveUserPosition;
  NavigationStatus status = NavigationStatus.idle;
  DateTime? _segmentBoundarySince;

  double get calibratedStepLengthMeters => motionService.calibratedStepLengthMeters;

  int get strideCalibrationSampleCount => motionService.strideCalibrationSampleCount;

  /// Arrow heading derived from route geometry: current position → next waypoint.
  /// More reliable indoors than the magnetic compass.
  double? get headingDegrees {
    final live = liveUserPosition;
    final next = _nextRouteWaypoint();
    if (live == null || next == null) return null;
    final dx = next.dx - live.dx;
    final dy = next.dy - live.dy;
    if (dx * dx + dy * dy < 1.0) return null;
    // map y increases downward; convert map-space vector to compass heading
    final mapAngleDeg = math.atan2(dx, -dy) * 180 / math.pi;
    return ((mapAngleDeg + storeMap.mapNorthOffsetDegrees) % 360 + 360) % 360;
  }

  void start() {
    bleScanner.startScan();
    motionService.start();
    _followTimer ??= Timer.periodic(_followTickInterval, (_) => _advanceTowardTarget());
    _log('NAV: started — ${storeMap.beacons.length} beacons, metersPerUnit=${storeMap.metersPerUnit}');
  }

  void setDestination(Beacon beacon) {
    destinationBeacon = beacon;
    status = NavigationStatus.rerouting;
    _log('NAV## destination set → ${beacon.name}');
    _recomputePath();
    notifyListeners();
  }

  void setOffRouteDetection(bool enabled) {
    if (allowOffRouteBeacons == enabled) return;
    allowOffRouteBeacons = enabled;
    _log('NAV## off-route beacon candidates ${enabled ? "enabled" : "disabled"}');
    notifyListeners();
  }

  void clearDestination() {
    _log('NAV## route cleared (was: ${destinationBeacon?.name ?? "none"})');
    destinationBeacon = null;
    currentPath = [];
    currentDistanceMeters = null;
    status = NavigationStatus.idle;
    _segmentBoundarySince = null;
    notifyListeners();
  }

  void _onRssiUpdate(Map<String, double> rssiByBleId) {
    _rssiUpdateCount++;
    final now = DateTime.now();
    final candidate = _selectBeaconCandidate(rssiByBleId);
    // Heartbeat: log RSSI state + route snapshot so log gaps make route problems visible.
    if (_rssiUpdateCount == 1 || _rssiUpdateCount % 30 == 0) {
      _log('NAV: RSSI #$_rssiUpdateCount — ${rssiByBleId.length} beacons visible'
          ' | beacon=${currentBeacon?.name ?? "none"}'
          ' | currentRssi=${_rssiForBeacon(currentBeacon, rssiByBleId)?.toStringAsFixed(1) ?? "none"}'
          ' | candidate=${candidate?.name ?? "none"}'
          ' | candidateRssi=${candidate == null ? "none" : _rssiForBeacon(candidate, rssiByBleId)?.toStringAsFixed(1) ?? "none"}'
          ' | dest=${destinationBeacon?.name ?? "none"}'
          ' | path=${currentPath.length} nodes'
          ' | metersSinceBeacon=${_metersSinceBeacon.toStringAsFixed(1)}'
          ' | livePos=${liveUserPosition != null ? "set" : "null"}');
    }
    // Prefer the strongest visible beacon as the current location source,
    // but still require stability before switching to avoid noisy oscillation.
    var justConfirmedBeacon = false;
    // Once arrived, lock the beacon so RSSI noise doesn't flip us back to a
    // neighbouring beacon, causing the route line to flicker on and off.
    final arrived = currentBeacon != null &&
        currentBeacon?.id == destinationBeacon?.id;
    if (arrived && candidate != null && candidate.id != currentBeacon?.id) {
      return;
    }
    if (candidate != null) {
      if (candidate.id == currentBeacon?.id) {
        _pendingBeaconId = null;
        _pendingBeaconCount = 0;
        _pendingBeaconSince = null;
      } else if (_shouldSwitchBeacon(currentBeacon, candidate, rssiByBleId)) {
        if (candidate.id == _pendingBeaconId) {
          _pendingBeaconCount++;
        } else {
          _pendingBeaconId = candidate.id;
          _pendingBeaconCount = 1;
          _pendingBeaconSince = now;
          _log('NAV## candidate ${candidate.name} vs ${currentBeacon?.name ?? "none"}'
              ' current=${_rssiForBeacon(currentBeacon, rssiByBleId)?.toStringAsFixed(1) ?? "none"}dBm'
              ' candidate=${_rssiForBeacon(candidate, rssiByBleId)?.toStringAsFixed(1) ?? "none"}dBm'
              ' — persistence started');
        }
        final candidateAge = _pendingBeaconSince == null
            ? Duration.zero
            : now.difference(_pendingBeaconSince!);
        final inCooldown = _lastBeaconSwitchAt != null &&
            now.difference(_lastBeaconSwitchAt!) < _beaconSwitchCooldown;
        if (_pendingBeaconCount >= _requiredConsecutiveReadings &&
            candidateAge >= _candidatePersistence &&
            !inCooldown) {
          final prevPath = List<Beacon>.from(currentPath);
          final previousBeacon = currentBeacon;
          _pendingBeaconId = null;
          _pendingBeaconCount = 0;
          _pendingBeaconSince = null;
          // Ignore entirely only if the beacon is behind the user on the route.
          final alreadyPassed = liveUserPosition != null &&
              _isAlreadyPassed(candidate, prevPath, liveUserPosition!);
          if (alreadyPassed) {
            _log('NAV: beacon ${candidate.name} confirmed — ignored (already passed)');
          } else {
            _recordCompletedSegmentCalibration(previousBeacon, candidate);
            currentBeacon = candidate;
            _lastBeaconSwitchAt = now;
            _recomputePath();
            _snapToCurrentBeacon();
            status = candidate.id == destinationBeacon?.id ? NavigationStatus.arrived : NavigationStatus.navigating;
            justConfirmedBeacon = true;
            _zoneEnteredController.add(candidate);
            _log('NAV## beacon confirmed → ${candidate.name}');
          }
        } else if (_pendingBeaconCount >= _requiredConsecutiveReadings &&
            (_rssiUpdateCount == 1 || _rssiUpdateCount % 30 == 0)) {
          _log('NAV## candidate ${candidate.name} held ${candidateAge.inMilliseconds}ms'
              ' cooldown=$inCooldown — waiting for stable zone decision');
        }
      } else {
        _pendingBeaconId = null;
        _pendingBeaconCount = 0;
        _pendingBeaconSince = null;
      }
    }

    if (justConfirmedBeacon) notifyListeners();
  }

  Beacon? _selectBeaconCandidate(Map<String, double> rssiByBleId) {
    final navigating = destinationBeacon != null && currentPath.length > 1;
    if (!navigating || allowOffRouteBeacons) {
      return _zoneSnap.strongestBeacon(rssiByBleId, storeMap);
    }

    // Strict on-route mode: only the current beacon or the immediate next
    // beacon on the route are eligible — not the whole remaining path — so
    // a strong-but-noisy RSSI reading from a beacon several stops ahead
    // can't cause the route to "skip ahead."
    final allowedIds = <String>{};
    final cb = currentBeacon;
    if (cb != null) {
      allowedIds.add(cb.id);
      final next = _pathBeaconAfter(cb.id);
      if (next != null) allowedIds.add(next.id);
    } else {
      // No fix yet — allow any beacon already on the route for the first confirmation.
      allowedIds.addAll(currentPath.map((beacon) => beacon.id));
    }

    Beacon? candidate;
    double? bestRssi;
    for (final entry in rssiByBleId.entries) {
      final beacon = storeMap.beaconByBleId(entry.key);
      if (beacon == null || !allowedIds.contains(beacon.id)) continue;
      if (bestRssi == null || entry.value > bestRssi) {
        bestRssi = entry.value;
        candidate = beacon;
      }
    }

    if (candidate == null) {
      _log('NAV## route-only candidate none — off-route detection disabled');
    }
    return candidate;
  }

  /// True if, given how far the user has actually walked since the last
  /// confirmed beacon, [candidate] is a plausible beacon to have reached —
  /// i.e. its real walking distance from [currentBeacon] (via the corridor
  /// graph, not a straight line through walls) does not exceed what the
  /// pedometer says was physically covered, plus tolerance. This is what
  /// stops a strong-but-implausible RSSI reading (e.g. bleeding through a
  /// thin wall from an adjacent room, or a destination beacon's signal
  /// spiking) from being accepted as a real position jump — RSSI stability
  /// alone can never catch this, since the reading can be perfectly stable
  /// and still physically impossible.
  bool _isPhysicallyReachable(Beacon candidate) {
    final anchor = currentBeacon;
    if (anchor == null) return true; // no fix yet — nothing to compare against
    if (anchor.id == candidate.id) return true;

    double walkingDistanceMeters;
    final routeResult = _pathfinder.findPath(storeMap, anchor.id, candidate.id);
    if (routeResult.path.isNotEmpty) {
      walkingDistanceMeters = routeResult.distanceMeters;
    } else {
      // No known corridor route between them in the graph — fall back to
      // straight-line distance as a rough plausibility bound rather than
      // auto-rejecting, since the graph may simply be missing an edge.
      walkingDistanceMeters =
          (candidate.position - anchor.position).distance * storeMap.metersPerUnit;
    }

    final plausibleMeters = _metersSinceBeacon + _reachabilityToleranceMeters;
    final reachable = walkingDistanceMeters <= plausibleMeters;
    if (!reachable) {
      _log('NAV## candidate ${candidate.name} rejected — reachability check failed: '
          '${walkingDistanceMeters.toStringAsFixed(1)}m away via graph, only '
          '${_metersSinceBeacon.toStringAsFixed(1)}m walked since ${anchor.name} '
          '(tolerance ${_reachabilityToleranceMeters}m)');
    }
    return reachable;
  }

  void _snapToCurrentBeacon() {
    final beacon = currentBeacon;
    if (beacon == null) return;
    final snap = beacon.position;
    final current = liveUserPosition ?? _targetPosition ?? beacon.position;
    final drift = (current - snap).distance;

    // Never hard-jump the visual position on a routine beacon confirmation.
    // Keep the previously rendered point as the start of the correction and
    // let the normal route-following interpolation pull the user dot toward
    // the newly-confirmed beacon. Only do a full reset when the discrepancy is
    // large enough to indicate the tracker actually lost the route.
    _targetPosition = snap;
    _segmentProgressMeters = 0.0;
    _segmentStepCount = 0;
    _segmentBoundarySince = null;
    _metersSinceBeacon = 0.0;

    if (drift > _maxBeaconCorrectionResetMeters) {
      // This is a real recovery case: move to the anchor immediately so the
      // route doesn't stretch across a wide gap, but still keep it as a
      // single-target motion correction rather than a direct map-space jump.
      liveUserPosition = snap;
    }
  }

  /// Advances the user along the currently active route segment using a known,
  /// bounded segment length rather than raw step distance. This keeps the dot
  /// from overshooting the next beacon purely because the pedometer slightly
  /// overestimates the user's stride on the current walk segment.
  void _onStep(double distanceMeters) {
    // Unclamped odometer, used only for the beacon-reachability check —
    // must accumulate regardless of whether there's an active route segment
    // to move the arrow along.
    _metersSinceBeacon += distanceMeters;

    final startBeacon = currentBeacon;
    if (startBeacon == null) return;
    final next = _nextRouteWaypoint();
    if (next == null) return;

    final segment = _segmentLengthMeters(startBeacon, next);
    if (segment <= 0.0) return;

    _segmentStepCount++;
    final segmentProgress = (_segmentProgressMeters + distanceMeters).clamp(0.0, segment);
    _segmentProgressMeters = segmentProgress;

    final fraction = (segmentProgress / segment).clamp(0.0, 1.0);
    final projected = _pointAlongCurrentEdge(startBeacon, next, fraction);
    _targetPosition = projected;
    liveUserPosition ??= projected;
    if (status != NavigationStatus.arrived) status = NavigationStatus.navigating;
  }

  void _recordCompletedSegmentCalibration(Beacon? previous, Beacon candidate) {
    if (previous == null || _segmentStepCount <= 0 || currentPath.length < 2) return;
    final nextIndex = currentPath.indexWhere((beacon) => beacon.id == previous.id) + 1;
    if (nextIndex <= 0 || nextIndex >= currentPath.length || currentPath[nextIndex].id != candidate.id) return;
    final edge = storeMap.edgeBetween(previous.id, candidate.id);
    if (edge == null || _segmentProgressMeters < edge.distanceMeters * 0.5) return;
    motionService.recordStrideCalibration(distanceMeters: edge.distanceMeters, steps: _segmentStepCount);
  }

  /// Applies a small visual blend toward the step-driven target. The target is
  /// the single source of truth; the blend only smooths the rendered position so
  /// the dot doesn't twitch, and it never reintroduces a fixed wall-clock speed
  /// assumption (which would drift away from the actual measured step path).
  void _advanceTowardTarget() {
    final target = _targetPosition;
    if (target == null) return;
    final current = liveUserPosition ?? target;
    final toTarget = target - current;
    final remaining = toTarget.distance;
    if (remaining < 0.001) {
      _updateStallStatus();
      return;
    }
    final moveBy = remaining * _visualBlendPerTick;
    liveUserPosition = current + toTarget / remaining * moveBy;
    _updateStallStatus();
    notifyListeners();
  }

  double _segmentLengthMeters(Beacon start, Offset endPosition) {
    final endBeacon = _pathBeaconAfter(start.id);
    if (endBeacon != null) {
      final edge = storeMap.edgeBetween(start.id, endBeacon.id);
      if (edge != null) return edge.distanceMeters;
      return (endBeacon.position - start.position).distance * storeMap.metersPerUnit;
    }
    final direct = (endPosition - start.position).distance * storeMap.metersPerUnit;
    return direct > 0 ? direct : 0.0;
  }

  List<Offset> _currentEdgePolyline(Beacon start, Offset endPosition) {
    final endBeacon = _pathBeaconAfter(start.id);
    final edge = endBeacon == null ? null : storeMap.edgeBetween(start.id, endBeacon.id);
    final waypoints = edge == null
        ? const <Offset>[]
        : edge.from == start.id
        ? edge.waypoints
        : edge.waypoints.reversed.toList();
    return [start.position, ...waypoints, endPosition];
  }

  Offset _pointAlongCurrentEdge(Beacon start, Offset endPosition, double fraction) {
    final points = _currentEdgePolyline(start, endPosition);
    if (points.length < 2) return endPosition;
    final lengths = <double>[0.0];
    for (var i = 1; i < points.length; i++) {
      lengths.add(lengths.last + (points[i] - points[i - 1]).distance);
    }
    final total = lengths.last;
    if (total <= 0) return points.first;
    final target = total * fraction;
    for (var i = 1; i < lengths.length; i++) {
      if (target <= lengths[i]) {
        final span = lengths[i] - lengths[i - 1];
        final local = span <= 0 ? 0.0 : (target - lengths[i - 1]) / span;
        return Offset.lerp(points[i - 1], points[i], local)!;
      }
    }
    return points.last;
  }

  void _updateStallStatus() {
    final start = currentBeacon;
    final next = start == null ? null : _nextRouteWaypoint();
    if (start == null || next == null || _segmentProgressMeters < _segmentLengthMeters(start, next) - 0.05) {
      _segmentBoundarySince = null;
      return;
    }
    final now = DateTime.now();
    _segmentBoundarySince ??= now;
    if (now.difference(_segmentBoundarySince!) >= const Duration(seconds: 5) && status != NavigationStatus.arrived) {
      status = NavigationStatus.checkingLocation;
    }
  }

  Beacon? _pathBeaconAfter(String beaconId) {
    if (currentPath.length < 2) return null;
    final index = currentPath.indexWhere((beacon) => beacon.id == beaconId);
    if (index == -1 || index >= currentPath.length - 1) return null;
    return currentPath[index + 1];
  }

  bool _shouldSwitchBeacon(
      Beacon? current,
      Beacon candidate,
      Map<String, double> rssiByBleId,
      ) {
    if (current == null) return true;
    final currentRssi = _rssiForBeacon(current, rssiByBleId);
    final candidateRssi = _rssiForBeacon(candidate, rssiByBleId);
    if (candidateRssi == null) return false;
    // Physical plausibility gate — applies regardless of off-route mode.
    // A candidate that RSSI-wise looks stable but that the user could not
    // have actually walked to yet is rejected here, before it's ever given
    // the chance to accumulate consecutive readings.
    if (!_isPhysicallyReachable(candidate)) return false;
    if (currentRssi == null) return true;
    return candidateRssi >= currentRssi + _beaconSwitchThresholdDb;
  }

  double? _rssiForBeacon(Beacon? beacon, Map<String, double> rssiByBleId) {
    if(beacon == null) return null;
    for (final entry in rssiByBleId.entries) {
      if (beacon.matchesBleId(entry.key)) return entry.value;
    }
    return null;
  }

  /// The next position to walk toward on the current route.
  /// Uses [currentBeacon] as anchor when it is on the path; after an
  /// off-path reroute where [currentBeacon] is no longer part of the
  /// recomputed path, falls back to the node nearest [liveUserPosition].
  Offset? _nextRouteWaypoint() {
    final path = currentPath;
    if (path.length < 2) {
      // Arrived — keep aiming at the destination so PDR doesn't fall back
      // to the unreliable compass when the arrow hasn't reached it yet.
      return path.length == 1 ? path.first.position : null;
    }

    final cb = currentBeacon;
    if (cb != null) {
      final index = path.indexWhere((b) => b.id == cb.id);
      if (index != -1 && index < path.length - 1) return path[index + 1].position;
    }

    // currentBeacon not on this path (post-reroute) — find the node nearest
    // to liveUserPosition and aim at the one immediately after it.
    final live = liveUserPosition;
    if (live != null) {
      var nearestIdx = 0;
      var nearestDist = double.infinity;
      for (var i = 0; i < path.length - 1; i++) {
        final d = (path[i].position - live).distanceSquared;
        if (d < nearestDist) {
          nearestDist = d;
          nearestIdx = i;
        }
      }
      return path[nearestIdx + 1].position;
    }

    return null;
  }

  /// Returns true when [beacon] sits at a lower path index than the node
  /// nearest to [livePos] — meaning the user has already walked past it.
  bool _isAlreadyPassed(Beacon beacon, List<Beacon> path, Offset livePos) {
    if (path.length < 2) return false;
    final beaconIndex = path.indexWhere((b) => b.id == beacon.id);
    if (beaconIndex == -1) return false;
    var nearestIndex = 0;
    var nearestDist = double.infinity;
    for (var i = 0; i < path.length; i++) {
      final d = (path[i].position - livePos).distanceSquared;
      if (d < nearestDist) {
        nearestDist = d;
        nearestIndex = i;
      }
    }
    return beaconIndex < nearestIndex;
  }

  void _log(String message) {
    debugPrint('[NAV] $message');
    logger?.log(message);
  }

  /// Recomputes [currentPath]/[currentDistanceMeters] for the current
  /// [currentBeacon] → [destinationBeacon] pair. Deliberately leaves the
  /// existing route on screen untouched if there's no beacon fix yet or no
  /// path could be found — the route should only ever go away because the
  /// user cleared it ([clearDestination]) or picked a different
  /// destination ([setDestination]), never because of a transient
  /// recompute glitch mid-walk.
  void _recomputePath() {
    final start = currentBeacon;
    final end = destinationBeacon;
    if (end == null) {
      _log('NAV: _recomputePath skipped — no destination');
      return;
    }
    if (start == null) {
      _log('NAV: _recomputePath skipped — no beacon fix yet (path stays: ${currentPath.length} nodes)');
      return;
    }

    final result = _pathfinder.findPath(storeMap, start.id, end.id);
    if (result.path.isEmpty) {
      status = NavigationStatus.checkingLocation;
      _log('NAV: _recomputePath — no path from ${start.name} to ${end.name}; keeping existing route (${currentPath.length} nodes)');
      return;
    }

    final prev = currentPath.map((b) => b.name).join(" → ");
    currentPath = result.path;
    currentDistanceMeters = result.distanceMeters;
    status = start.id == end.id ? NavigationStatus.arrived : NavigationStatus.navigating;
    final next = currentPath.map((b) => b.name).join(" → ");
    if (prev != next) {
      _log('NAV## path changed: $prev → $next (${currentDistanceMeters?.toStringAsFixed(0)} m)');
    } else {
      _log('NAV: path → $next (${currentDistanceMeters?.toStringAsFixed(0)} m) [unchanged]');
    }
  }

  @override
  void dispose() {
    _rssiSub?.cancel();
    _stepSub?.cancel();
    _motionErrorSub?.cancel();
    _headingSub?.cancel();
    _followTimer?.cancel();
    _zoneEnteredController.close();
    bleScanner.dispose();
    super.dispose();
  }
}