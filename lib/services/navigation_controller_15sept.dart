import 'dart:async';
import 'dart:math' as math;
import 'dart:math';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import '../models/beacon.dart';
import '../models/store_map.dart';
import 'ble_scanner_service.dart';
import 'motion_service.dart';
import 'activity_logger.dart';
import 'pathfinding_service.dart';
import 'zone_snap_service.dart';
import 'zone_snap_service.dart';

enum NavigationStatus {
  idle,
  navigating,
  checkingLocation,
  rerouting,
  arrived,
}

/// Direction-of-travel signal relative to the current route's next beacon.
///
/// This is inferred from BLE RSSI trend rather than compass heading.
/// Positive RSSI delta means the signal is getting stronger, therefore
/// the user is likely moving toward the beacon.
///
/// This is only a supporting signal. It is never used as a standalone
/// positioning mechanism.
enum _RssiTrend {
  towardNext,
  awayFromNext,
  unknown,
}

class _BeaconCandidateState {
  final Beacon beacon;

  double? latestRssi;
  double? peakRssi;

  _RssiTrend trend = _RssiTrend.unknown;

  DateTime? firstSeen;
  DateTime? lastSeen;

  int consecutiveWeakeningReadings = 0;
  int consecutiveStrengtheningReadings = 0;

  bool hasPassedPeak = false;

  _BeaconCandidateState(this.beacon);
}



/// Central navigation state.
///
/// BLE provides discrete beacon observations.
/// Motion/PDR provides continuous movement between beacons.
/// The route graph protects the navigation state from BLE jumps.
///
/// The important rule is:
///
///     BLE confirms route progression.
///     BLE does NOT independently determine position.
///
/// During normal navigation only the immediate next route beacon can
/// replace the current beacon. Physical reachability, RSSI strength,
/// persistence and trend are then used as additional confidence gates.
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

    // Reserved for future movement-direction support.
    //
    // We intentionally don't use the magnetic compass for navigation
    // because indoor magnetic interference can make it unreliable.
  }

  // ---------------------------------------------------------------------------
  // P0 / P1 TUNING
  // ---------------------------------------------------------------------------
  _BeaconCandidateState? _primaryCandidateState;
  _BeaconCandidateState? _secondaryCandidateState;

  _BeaconCandidateState? _currentBeaconState;

  static const double _secondaryOvertakeMarginDb = 1.5;
  static const double _candidatePeakToleranceDb = 1.5;

  static const int _candidateWeakeningReadingsRequired = 2;

  final Map<String, List<double>> _rssiHistory = {};
  /// Number of consecutive RSSI updates for which a candidate must remain
  /// the selected candidate before it can be confirmed.
  ///
  /// Increased from 3 -> 5 to reduce noisy beacon switching.
  static const int _requiredConsecutiveReadings = 5;

  /// Candidate must remain valid for at least this long.
  static const Duration _candidatePersistence = Duration(milliseconds: 1200);

  /// Prevents immediate back-to-back beacon switching.
  static const Duration _beaconSwitchCooldown = Duration(milliseconds: 1500);

  /// Minimum RSSI advantage required before changing beacon.
  ///
  /// Candidate RSSI is compared against the smoothed current RSSI.
  static const double _beaconSwitchThresholdDb = 8;

  /// Additional distance allowance when deciding whether a beacon could
  /// physically have been reached.
  static const double _reachabilityToleranceMeters = 3.5;



  /// When false:
  ///   Only the immediate next route beacon can trigger a switch.
  ///
  /// When true:
  ///   If the immediate next beacon is not available via RSSI,
  ///   the controller may consider the next available beacon
  ///   further along the route.
  ///
  /// RSSI is still the only source of truth.
  /// PDR/geometry never authorizes a beacon transition.
  bool _enableRouteLookAhead = true;

  /// Visual smoothing tick.
  static const Duration _followTickInterval = Duration(milliseconds: 50);

  /// Existing visual interpolation factor.
  static const double _visualBlendPerTick = 0.35;

  /// If the confirmed beacon is extremely far from the rendered position,
  /// treat it as recovery rather than trying to animate across a huge gap.
  static const double _maxBeaconCorrectionResetMeters = 8.0;

  // ---------------------------------------------------------------------------
  // P1 RSSI SMOOTHING
  // ---------------------------------------------------------------------------

  /// EMA alpha.
  ///
  /// Lower = smoother but slower.
  /// Higher = more responsive but noisier.
  static const double _rssiEmaAlpha = 0.25;

  /// Rolling RSSI window used to infer whether the user is approaching
  /// or moving away from the next route beacon.
  static const int _rssiTrendWindowSize = 4;

  /// Minimum average RSSI delta required before trusting a trend.
  static const double _rssiTrendThresholdDb = 4.0;

  // ---------------------------------------------------------------------------
  // INITIAL FIX
  // ---------------------------------------------------------------------------

  static const int _initialFixWindowSize = 5;
  static const int _initialFixMinSamples = 3;

  static const double _initialFixMinMarginDb = 8.0;

  static const Duration _initialFixMaxWait = Duration(seconds: 6);

  // ---------------------------------------------------------------------------
  // SERVICES
  // ---------------------------------------------------------------------------

  final StoreMap storeMap;
  final BleScannerService bleScanner;
  final MotionService motionService;

  /// Kept for API compatibility with the existing controller.
  final ZoneSnapService _zoneSnap;

  final PathfindingService _pathfinder;

  bool allowOffRouteBeacons;

  final ActivityLogger? logger;

  // ---------------------------------------------------------------------------
  // SUBSCRIPTIONS / TIMER
  // ---------------------------------------------------------------------------

  StreamSubscription<Map<String, double>>? _rssiSub;

  StreamSubscription<double>? _stepSub;

  StreamSubscription<String>? _motionErrorSub;

  StreamSubscription<double>? _headingSub;

  Timer? _followTimer;

  // ---------------------------------------------------------------------------
  // EVENTS
  // ---------------------------------------------------------------------------

  final _zoneEnteredController = StreamController<Beacon>.broadcast();

  Stream<Beacon> get zoneEnteredStream => _zoneEnteredController.stream;

  // ---------------------------------------------------------------------------
  // BEACON STATE
  // ---------------------------------------------------------------------------

  String? _pendingBeaconId;

  int _pendingBeaconCount = 0;

  DateTime? _pendingBeaconSince;

  DateTime? _lastBeaconSwitchAt;

  int _rssiUpdateCount = 0;

  Beacon? currentBeacon;

  Beacon? destinationBeacon;

  List<Beacon> currentPath = [];

  // ---------------------------------------------------------------------------
  // PDR STATE
  // ---------------------------------------------------------------------------

  double _segmentProgressMeters = 0.0;

  int _segmentStepCount = 0;

  /// Raw distance walked since the last confirmed beacon.
  ///
  /// IMPORTANT:
  /// This value is intentionally NOT clamped to the current segment.
  /// It is used to determine whether another beacon could physically
  /// have been reached.
  double _metersSinceBeacon = 0.0;

  // ---------------------------------------------------------------------------
  // RSSI TREND STATE
  // ---------------------------------------------------------------------------

  final List<double> _nextBeaconRssiWindow = [];

  String? _trackedNextBeaconId;

  _RssiTrend _nextBeaconTrend = _RssiTrend.unknown;

  /// Exposed for existing UI/debugging code.
  ///
  /// Despite the old name, this should be interpreted as:
  /// "RSSI indicates movement toward this beacon."
  Beacon? headingTowardsBeaconInPath;

  // ---------------------------------------------------------------------------
  // P1 RSSI EMA
  // ---------------------------------------------------------------------------

  final Map<String, double> _rssiEma = {};

  // ---------------------------------------------------------------------------
  // INITIAL FIX STATE
  // ---------------------------------------------------------------------------

  final Map<String, List<double>> _initialFixRssiWindows = {};

  DateTime? _initialFixStartedAt;

  // ---------------------------------------------------------------------------
  // NAVIGATION POSITION
  // ---------------------------------------------------------------------------

  /// Total route distance.
  double? currentDistanceMeters;

  /// Position the visual marker should move toward.
  Offset? _targetPosition;

  /// Current rendered user position.
  Offset? liveUserPosition;

  NavigationStatus status = NavigationStatus.idle;

  DateTime? _segmentBoundarySince;

  // ---------------------------------------------------------------------------
  // PUBLIC GETTERS
  // ---------------------------------------------------------------------------

  double get calibratedStepLengthMeters =>
      motionService.calibratedStepLengthMeters;

  int get strideCalibrationSampleCount =>
      motionService.strideCalibrationSampleCount;

  /// Route-derived heading.
  ///
  /// This is geometry based rather than magnetic-compass based.
  double? get headingDegrees {
    final live = liveUserPosition;

    final next = _nextRouteWaypoint();

    if (live == null || next == null) {
      return null;
    }

    final dx = next.dx - live.dx;
    final dy = next.dy - live.dy;

    if (dx * dx + dy * dy < 1.0) {
      return null;
    }

    final mapAngleDeg = math.atan2(dx, -dy) * 180 / math.pi;

    return ((mapAngleDeg + storeMap.mapNorthOffsetDegrees) % 360 + 360) % 360;
  }

  // ---------------------------------------------------------------------------
  // LIFECYCLE
  // ---------------------------------------------------------------------------

  void start() {
    bleScanner.startScan();

    motionService.start();

    _followTimer ??= Timer.periodic(
      _followTickInterval,
      (_) => _advanceTowardTarget(),
    );

    _log(
      'NAV: started — '
      '${storeMap.beacons.length} beacons, '
      'metersPerUnit=${storeMap.metersPerUnit}',
    );
  }

  // ---------------------------------------------------------------------------
  // DESTINATION
  // ---------------------------------------------------------------------------

  void _updateRssiHistory(
      String bleId,
      double rssi,
      ) {
    final previousEma = _rssiEma[bleId];

    final ema = previousEma == null
        ? rssi
        : (_rssiEmaAlpha * rssi) +
        ((1.0 - _rssiEmaAlpha) * previousEma);

    _rssiEma[bleId] = ema;

    final history = _rssiHistory.putIfAbsent(
      bleId,
          () => <double>[],
    );

    history.add(ema);

    const maxHistorySize = 10;

    if (history.length > maxHistorySize) {
      history.removeAt(0);
    }

    _log(
      'NAV## RSSI UPDATE '
          'bleId=$bleId '
          'raw=${rssi.toStringAsFixed(1)} '
          'ema=${ema.toStringAsFixed(1)} '
          'samples=${history.length}',
    );
  }

  void setDestination(Beacon beacon) {
    destinationBeacon = beacon;

    status = NavigationStatus.rerouting;

    // New destination means any pending candidate from the old route
    // must be discarded.
    _clearPendingBeaconCandidate();

    _log(
      'NAV## destination set → ${beacon.name}',
    );

    _recomputePath();

    notifyListeners();
  }

  void setOffRouteDetection(bool enabled) {
    if (allowOffRouteBeacons == enabled) {
      return;
    }

    allowOffRouteBeacons = enabled;

    _log(
      'NAV## off-route beacon candidates '
      '${enabled ? "enabled" : "disabled"}',
    );

    notifyListeners();
  }

  void clearDestination() {
    _log(
      'NAV## route cleared '
      '(was: ${destinationBeacon?.name ?? "none"})',
    );

    destinationBeacon = null;

    currentPath = [];

    currentDistanceMeters = null;

    status = NavigationStatus.idle;

    _segmentBoundarySince = null;

    _clearPendingBeaconCandidate();

    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // RSSI UPDATE
  // ---------------------------------------------------------------------------

  void _onRssiUpdate(
    Map<String, double> rssiByBleId,
  ) {
    _rssiUpdateCount++;

    final now = DateTime.now();

    // P1:
    // Smooth the raw RSSI before using it for decisions.
    _updateRssiEma(rssiByBleId);

    _updateCurrentBeaconState(rssiByBleId);
    _updateBeaconCandidateStates(rssiByBleId);


    // Update trend of the immediate next route beacon.
    _updateNextBeaconTrend(rssiByBleId);

    // Select a candidate.
    final candidate = _selectBeaconCandidate(rssiByBleId);

    _log(
      'NAV### BEACONS candidate is '
      '${candidate?.name}',
    );


    // -----------------------------------------------------------------------
// INITIAL POSITIONING
// -----------------------------------------------------------------------
//
// The first beacon is an anchor, NOT a beacon switch.
// Do not run _shouldSwitchBeacon(), persistence, cooldown,
// anti-teleport validation, or PDR transition logic here.
//
// RSSI initial-fix logic decides the first beacon.
// -----------------------------------------------------------------------

    if (destinationBeacon == null) {
      if (candidate == null) {
        return;
      }

      final changed = currentBeacon?.id != candidate.id;

      if (!changed) {
        return;
      }

      final previousBeacon = currentBeacon;

      currentBeacon = candidate;

      _currentBeaconState =
          _BeaconCandidateState(candidate);

      _metersSinceBeacon = 0.0;
      _segmentProgressMeters = 0.0;
      _segmentStepCount = 0;

      _nextBeaconTrend = _RssiTrend.unknown;

      _snapToCurrentBeacon();

      _clearPendingBeaconCandidate();

      _log(
        'NAV## FREE BEACON SET '
            '${previousBeacon?.name ?? "none"} → ${candidate.name}',
      );

      notifyListeners();

      return;
    }



    if (currentBeacon != null && destinationBeacon == null) {
      return;
    }


    // -----------------------------------------------------------------------
    // HEARTBEAT LOG
    // -----------------------------------------------------------------------


    if (_rssiUpdateCount == 1 || _rssiUpdateCount % 30 == 0) {
      final currentRaw = _rssiForBeacon(
        currentBeacon,
        rssiByBleId,
      );


      final currentSmooth =
          currentBeacon == null ? null : (_smoothedRssi(currentBeacon!.id));

      final candidateRaw = candidate == null
          ? null
          : _rssiForBeacon(
              candidate,
              rssiByBleId,
            );

      final candidateSmooth = candidate == null
          ? null
          : _smoothedRssi(
              candidate.id,
            );

      _log(
        'NAV: RSSI #$_rssiUpdateCount — '
        '${rssiByBleId.length} beacons visible'
        ' | beacon=${currentBeacon?.name ?? "none"}'
        ' | currentRaw=${currentRaw?.toStringAsFixed(1) ?? "none"}'
        ' | currentEMA=${currentSmooth?.toStringAsFixed(1) ?? "none"}'
        ' | candidate=${candidate?.name ?? "none"}'
        ' | candidateRaw=${candidateRaw?.toStringAsFixed(1) ?? "none"}'
        ' | candidateEMA=${candidateSmooth?.toStringAsFixed(1) ?? "none"}'
        ' | trend=$_nextBeaconTrend'
        ' | dest=${destinationBeacon?.name ?? "none"}'
        ' | path=${currentPath.length} nodes'
        ' | metersSinceBeacon=${_metersSinceBeacon.toStringAsFixed(1)}'
        ' | livePos=${liveUserPosition != null ? "set" : "null"}',
      );
    }

    // -----------------------------------------------------------------------
    // ARRIVED LOCK
    // -----------------------------------------------------------------------

    final arrived =
        currentBeacon != null && currentBeacon?.id == destinationBeacon?.id;

    if (arrived) {
      // Once destination is reached, don't let a neighbouring beacon
      // pull the navigation state away from the destination.
      if (candidate != null && candidate.id != currentBeacon?.id) {
        return;
      }

      return;
    }

    // -----------------------------------------------------------------------
    // COLD START
    // -----------------------------------------------------------------------

    if (candidate == null &&
        currentBeacon == null &&
        destinationBeacon != null) {
      if (status != NavigationStatus.checkingLocation) {
        status = NavigationStatus.checkingLocation;

        notifyListeners();
      }
    }

    // -----------------------------------------------------------------------
    // CANDIDATE PROCESSING
    // -----------------------------------------------------------------------

    if (candidate == null) {
      return;
    }

    // Current beacon is still strongest/selected.
    //
    // This is not a reason to reset PDR.
    if (candidate.id == currentBeacon?.id) {
      _clearPendingBeaconCandidate();

      return;
    }

    // -----------------------------------------------------------------------
    // SWITCH VALIDATION
    // -----------------------------------------------------------------------

    _log(
      'NAV## SWITCH ATTEMPT '
      '${currentBeacon?.name ?? "none"} → ${candidate.name} '
      'meters=${_metersSinceBeacon.toStringAsFixed(2)} '
      'trend=$_nextBeaconTrend '
      'candidateRSSI='
      '${(_smoothedRssi(candidate.id) ?? _rssiForBeacon(candidate, rssiByBleId))?.toStringAsFixed(1) ?? "none"}',
    );

    final shouldSwitch = _shouldSwitchBeacon(
      candidate,
      rssiByBleId,
    );

    if (!shouldSwitch) {
      // Candidate is not currently good enough.
      //
      // IMPORTANT:
      // Clear persistence because the candidate failed validation.
      // This prevents an old candidate count from accumulating across
      // periods where the beacon is not actually valid.
      _clearPendingBeaconCandidate();

      return;
    }

    // -----------------------------------------------------------------------
    // CANDIDATE PERSISTENCE
    // -----------------------------------------------------------------------

    if (candidate.id == _pendingBeaconId) {
      _pendingBeaconCount++;
    } else {
      _pendingBeaconId = candidate.id;

      _pendingBeaconCount = 1;

      _pendingBeaconSince = now;

      final currentRaw = _rssiForBeacon(
        currentBeacon,
        rssiByBleId,
      );

      final candidateRaw = _rssiForBeacon(
        candidate,
        rssiByBleId,
      );

      _log(
        'NAV## candidate ${candidate.name} '
        'vs ${currentBeacon?.name ?? "none"} '
        'current=${currentRaw?.toStringAsFixed(1) ?? "none"}dBm '
        'candidate=${candidateRaw?.toStringAsFixed(1) ?? "none"}dBm '
        'EMA=${_smoothedRssi(candidate.id)?.toStringAsFixed(1) ?? "none"} '
        'trend=$_nextBeaconTrend '
        '— persistence started',
      );
    }

    final candidateAge = _pendingBeaconSince == null
        ? Duration.zero
        : now.difference(
            _pendingBeaconSince!,
          );

    final inCooldown = _lastBeaconSwitchAt != null &&
        now.difference(
              _lastBeaconSwitchAt!,
            ) <
            _beaconSwitchCooldown;

    // -----------------------------------------------------------------------
    // CONFIRM BEACON
    // -----------------------------------------------------------------------

    if (_pendingBeaconCount >= _requiredConsecutiveReadings &&
        candidateAge >= _candidatePersistence &&
        !inCooldown) {
      final prevPath = List<Beacon>.from(currentPath);

      final previousBeacon = currentBeacon;

      _clearPendingBeaconCandidate();

      // Final anti-teleport guard.
      //
      // This is intentionally checked again immediately before committing.
      // The candidate may have been valid at the beginning of the persistence
      // period but no longer be valid now.
      if (!_isNavigationHopValid(
        previousBeacon,
        candidate,
      )) {
        _log(
          'NAV## TELEPORT BLOCKED at confirmation: '
          '${previousBeacon?.name ?? "none"} '
          '→ ${candidate.name}',
        );

        return;
      }

      // A beacon behind the user must never become the new anchor.
      final alreadyPassed = liveUserPosition != null &&
          _isAlreadyPassed(
            candidate,
            prevPath,
            liveUserPosition!,
          );

      if (alreadyPassed) {
        _log(
          'NAV## beacon ${candidate.name} '
          'confirmed — ignored because already passed',
        );

        return;
      }

      // Record stride calibration before resetting the segment state.
      _recordCompletedSegmentCalibration(
        previousBeacon,
        candidate,
      );

      // ---------------------------------------------------------------------
      // COMMIT NEW BEACON
      // ---------------------------------------------------------------------

      currentBeacon = candidate;

      _lastBeaconSwitchAt = now;


      // ---------------------------------------------------------------------
// RESET SEGMENT STATE
//
// The new beacon becomes the anchor for the next route segment.
// PDR progress from the previous segment must never carry over.
// ---------------------------------------------------------------------

      _segmentProgressMeters = 0.0;
      _metersSinceBeacon = 0.0;
      _segmentStepCount = 0;

// Start the new segment without assuming direction.
// RSSI must establish that the user is moving toward the next beacon.
      _nextBeaconTrend = _RssiTrend.unknown;

      _recomputePath();

      _snapToCurrentBeacon();

      status = candidate.id == destinationBeacon?.id
          ? NavigationStatus.arrived
          : NavigationStatus.navigating;

      // Reset EMA so the next segment starts fresh.
      //
      // Otherwise a stale RSSI value from a previous segment could influence
      // the next candidate decision.
      _rssiEma.clear();

      justNotify:
      {
        // No-op scope retained intentionally for readability around
        // the event sequence.
      }

      _zoneEnteredController.add(
        candidate,
      );

      _log(
        'NAV## beacon confirmed → '
        '${candidate.name}',
      );

      notifyListeners();

      return;
    }

    // -----------------------------------------------------------------------
    // PERSISTENCE DEBUG
    // -----------------------------------------------------------------------

    if (_pendingBeaconCount >= _requiredConsecutiveReadings &&
        (_rssiUpdateCount == 1 || _rssiUpdateCount % 30 == 0)) {
      _log(
        'NAV## candidate ${candidate.name} '
        'held ${candidateAge.inMilliseconds}ms '
        'count=$_pendingBeaconCount/'
        '$_requiredConsecutiveReadings '
        'cooldown=$inCooldown '
        'trend=$_nextBeaconTrend',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // P1 RSSI EMA
  // ---------------------------------------------------------------------------
  void _updateRssiEma(
      Map<String, double> rssiByBleId,
      ) {
    for (final entry in rssiByBleId.entries) {
      final previous = _rssiEma[entry.key];

      final double ema;

      if (previous == null) {
        ema = entry.value;
      } else {
        ema =
            previous + _rssiEmaAlpha * (entry.value - previous);
      }

      _rssiEma[entry.key] = ema;

      final history = _rssiHistory.putIfAbsent(
        entry.key,
            () => <double>[],
      );

      history.add(ema);

      const maxHistorySize = 10;

      if (history.length > maxHistorySize) {
        history.removeAt(0);
      }
    }
  }
  double? _smoothedRssi(
    String beaconId,
  ) {
    // _rssiEma is keyed by BLE identifier, while callers pass the
    // application's Beacon.id. Resolve the Beacon first, then look up the
    // EMA using its BLE id. The old implementation returned null here for
    // every beacon, which made all EMA-based navigation gates ineffective.
    final beacon = storeMap.beaconById(beaconId);
    if (beacon == null) {
      return null;
    }

    for (final entry in _rssiEma.entries) {
      if (beacon.matchesBleId(entry.key)) {
        return entry.value;
      }
    }

    return null;
  }

  // ---------------------------------------------------------------------------
  // CANDIDATE SELECTION
  // ---------------------------------------------------------------------------
  Beacon? _selectBeaconCandidate(
      Map<String, double> rssiByBleId,
      ) {
// -----------------------------------------------------------------------
    // FREE / INITIAL POSITIONING
    // -----------------------------------------------------------------------
    //
    // Until a destination is selected, beacon selection is completely
    // independent of the route.
    //
    // _selectInitialFixCandidate() is the single source of truth here.
    // -----------------------------------------------------------------------

    if (destinationBeacon == null) {
      return _selectInitialFixCandidate(
        rssiByBleId,
        null,
      );
    }

    // -----------------------------------------------------------------------
    // NORMAL NAVIGATION
    // -----------------------------------------------------------------------

    if (currentBeacon == null) {
      return _selectInitialFixCandidate(
        rssiByBleId,
        null,
      );
    }



    // -----------------------------------------------------------------------
    // NO DESTINATION
    // -----------------------------------------------------------------------
    //
    // We already know where the user is.
    // They have not selected a destination yet.
    //
    // DO NOT select another beacon.
    // DO NOT perform route look-ahead.
    // DO NOT perform beacon switching.
    // -----------------------------------------------------------------------

    // if (destinationBeacon == null) {
    //   return null;
    // }

    // ------------------------------------------------------------
    // NORMAL NAVIGATION
    // ------------------------------------------------------------
    final current = currentBeacon!;

    final currentIndex = currentPath.indexWhere(
          (b) => b.id == current.id,
    );

    if (currentIndex < 0) {
      _log(
        'NAV## CANDIDATE CURRENT NOT FOUND IN PATH '
            'current=${current.name} '
            'currentId=${current.id}',
      );
      return null;
    }

    final primary = _pathBeaconAfter(current.id);

    if (primary == null) {
      _log(
        'NAV## NO NEXT BEACON '
            'current=${current.name} '
            'destination=${destinationBeacon?.name ?? "null"}',
      );
      return null;
    }

    Beacon? secondary;

    final primaryIndex = currentPath.indexWhere(
          (b) => b.id == primary.id,
    );

    if (primaryIndex >= 0 &&
        primaryIndex + 1 < currentPath.length) {
      secondary = currentPath[primaryIndex + 1];
    }

    if (_primaryCandidateState?.beacon.id != primary.id) {
      _primaryCandidateState =
          _BeaconCandidateState(primary);
    }

    if (secondary == null) {
      _secondaryCandidateState = null;
    } else if (_secondaryCandidateState?.beacon.id != secondary.id) {
      _secondaryCandidateState =
          _BeaconCandidateState(secondary);
    }

    final primaryRssi =
    _rssiForBeacon(primary, rssiByBleId);

    final secondaryRssi = secondary == null
        ? null
        : _rssiForBeacon(
      secondary,
      rssiByBleId,
    );

    // ------------------------------------------------------------
    // CONTROLLED SECONDARY
    // ------------------------------------------------------------
    if (_enableRouteLookAhead &&
        secondary != null &&
        secondaryRssi != null &&
        _primaryHasBeenPassed()) {
      _log(
        'NAV## CANDIDATE SECONDARY '
            '${current.name} → ${secondary.name} '
            'primary=${primary.name} '
            'primaryRSSI=${primaryRssi?.toStringAsFixed(1) ?? "none"} '
            'secondaryRSSI=${secondaryRssi.toStringAsFixed(1)} '
            'reason=primary passed',
      );

      return secondary;
    }

    // ------------------------------------------------------------
    // NORMAL PRIMARY
    // ------------------------------------------------------------
    if (primaryRssi != null) {
      _log(
        'NAV## CANDIDATE PRIMARY '
            '${current.name} → ${primary.name} '
            'rssi=${primaryRssi.toStringAsFixed(1)} '
            'secondary=${secondary?.name ?? "none"} '
            'secondaryRSSI='
            '${secondaryRssi?.toStringAsFixed(1) ?? "none"}',
      );

      return primary;
    }

    return null;
  }
  // Beacon? _selectBeaconCandidate(
  //     Map<String, double> rssiByBleId,
  //     ) {
  //   final exploring = destinationBeacon == null;
  //
  //
  //   // -------------------------------------------------------------------------
  //   // COLD START
  //   // -------------------------------------------------------------------------
  //
  //   if (exploring || currentBeacon == null) {
  //     // _log(
  //     //   'NAV## CANDIDATE INITIAL FIX '
  //     //       'reason=${exploring ? "destination is null" : "currentBeacon is null"}',
  //     // );
  //
  //     return _selectInitialFixCandidate(
  //       rssiByBleId,
  //       null,
  //     );
  //   }
  //
  //   final current = currentBeacon!;
  //
  //   // _log(
  //   //   'NAV## CANDIDATE CURRENT '
  //   //       'name=${current.name} '
  //   //       'id=${current.id}',
  //   // );
  //
  //   // -------------------------------------------------------------------------
  //   // PATH DEBUG
  //   // -------------------------------------------------------------------------
  //
  //   // _log(
  //   //   'NAV## CANDIDATE PATH '
  //   //       '${currentPath.map(
  //   //         (b) => '${b.name}[${b.id}]',
  //   //   ).join(" → ")}',
  //   // );
  //
  //   final currentIndex = currentPath.indexWhere(
  //         (b) => b.id == current.id,
  //   );
  //
  //   // _log(
  //   //   'NAV## CANDIDATE CURRENT INDEX '
  //   //       'current=${current.name} '
  //   //       'index=$currentIndex '
  //   //       'pathLength=${currentPath.length}',
  //   // );
  //
  //   // -------------------------------------------------------------------------
  //   // FIND NEXT BEACON
  //   // -------------------------------------------------------------------------
  //
  //   final next = _pathBeaconAfter(
  //     current.id,
  //   );
  //
  //   // _log(
  //   //   'NAV## CANDIDATE NEXT RESULT '
  //   //       'current=${current.name} '
  //   //       'currentId=${current.id} '
  //   //       'next=${next?.name ?? "NULL"} '
  //   //       'nextId=${next?.id ?? "NULL"}',
  //   // );
  //
  //   if (next == null) {
  //     _log(
  //       'NAV## NO NEXT BEACON '
  //           'current=${current.name} '
  //           'destination=${destinationBeacon?.name ?? "null"} '
  //           'currentIndex=$currentIndex '
  //           'pathLength=${currentPath.length}',
  //     );
  //
  //     return null;
  //   }
  //
  //   // -------------------------------------------------------------------------
  //   // NEXT BEACON CONFIG
  //   // -------------------------------------------------------------------------
  //
  //   // _log(
  //   //   'NAV## NEXT BEACON CONFIG '
  //   //       'name=${next.name} '
  //   //       'id=${next.id}',
  //   // );
  //
  //   // -------------------------------------------------------------------------
  //   // CHECK ALL VISIBLE BLE BEACONS
  //   // -------------------------------------------------------------------------
  //
  //   // _log(
  //   //   'NAV## SCAN CONTAINS ${rssiByBleId.length} BLE BEACONS',
  //   // );
  //
  //   for (final entry in rssiByBleId.entries) {
  //     final bleId = entry.key;
  //     final rawRssi = entry.value;
  //
  //     final beacon = storeMap.beaconByBleId(
  //       bleId,
  //     );
  //
  //     // _log(
  //     //   'NAV## SCAN BEACON '
  //     //       'bleId=$bleId '
  //     //       'rssi=${rawRssi.toStringAsFixed(1)} '
  //     //       'mapped=${beacon?.name ?? "NULL"} '
  //     //       'mappedId=${beacon?.id ?? "NULL"} '
  //     //       'isNext=${beacon?.id == next.id}',
  //     // );
  //
  //     if (beacon == null) {
  //       continue;
  //     }
  //
  //     if (beacon.id != next.id) {
  //       continue;
  //     }
  //
  //     final emaRssi = _rssiEma[bleId];
  //     final effectiveRssi = emaRssi ?? rawRssi;
  //     //
  //     // _log(
  //     //   'NAV## NEXT BEACON VISIBLE '
  //     //       '${current.name} → ${beacon.name} '
  //     //       'bleId=$bleId '
  //     //       'raw=${rawRssi.toStringAsFixed(1)} '
  //     //       'ema=${emaRssi?.toStringAsFixed(1) ?? "none"} '
  //     //       'effective=${effectiveRssi.toStringAsFixed(1)}',
  //     // );
  //
  //     return beacon;
  //   }
  //
  //   // -------------------------------------------------------------------------
  //   // NEXT NOT VISIBLE
  //   // -------------------------------------------------------------------------
  //
  //
  //   return null;
  // }
  // ---------------------------------------------------------------------------
  // INITIAL FIX
  // ---------------------------------------------------------------------------


  bool _isValidNavigationHop(Beacon candidate) {
    final current = currentBeacon;

    if (current == null) {
      return false;
    }

    final next = _pathBeaconAfter(current.id);

    if (next == null) {
      return false;
    }

    // Normal hop.
    if (candidate.id == next.id) {
      return true;
    }

    // Only allow one controlled secondary hop.
    final secondary = _pathBeaconAfter(next.id);

    return _enableRouteLookAhead &&
        secondary?.id == candidate.id &&
        _primaryHasBeenPassed();
  }

  Beacon? _selectInitialFixCandidate(
    Map<String, double> rssiByBleId,
    Set<String>? eligibleBeaconIds,
  ) {
    _initialFixStartedAt ??= DateTime.now();

    for (final entry in rssiByBleId.entries) {
      final beacon = storeMap.beaconByBleId(
        entry.key,
      );

      if (beacon == null) {
        continue;
      }

      if (eligibleBeaconIds != null && !eligibleBeaconIds.contains(beacon.id)) {
        continue;
      }

      final window = _initialFixRssiWindows.putIfAbsent(
        beacon.id,
        () => [],
      );

      // Use smoothed RSSI where available.
      final value = _smoothedRssi(beacon.id) ?? entry.value;

      window.add(value);

      if (window.length > _initialFixWindowSize) {
        window.removeAt(0);
      }
    }

    final averages = <String, double>{};

    _initialFixRssiWindows.forEach(
      (
        beaconId,
        samples,
      ) {
        if (eligibleBeaconIds != null &&
            !eligibleBeaconIds.contains(beaconId)) {
          return;
        }

        if (samples.length < _initialFixMinSamples) {
          return;
        }

        averages[beaconId] = _average(samples);
      },
    );

    if (averages.isEmpty) {
      return null;
    }

    final ranked = averages.entries.toList()
      ..sort(
        (a, b) => b.value.compareTo(
          a.value,
        ),
      );

    final bestId = ranked.first.key;

    final bestAvg = ranked.first.value;

    final elapsed = DateTime.now().difference(
      _initialFixStartedAt!,
    );

    if (ranked.length > 1) {
      final margin = bestAvg - ranked[1].value;

      if (margin < _initialFixMinMarginDb) {
        if (elapsed < _initialFixMaxWait) {
          _log(
            'NAV## initial fix ambiguous — '
            'top candidates: '
            '${ranked.take(3).map(
                  (e) => '${storeMap.beaconById(e.key)?.name ?? e.key}:'
                      '${e.value.toStringAsFixed(1)}dB',
                ).join(", ")} '
            '— waiting for clearer signal '
            '(${elapsed.inMilliseconds}ms elapsed)',
          );

          return null;
        }

        _log(
          'NAV## initial fix timeout after '
          '${elapsed.inSeconds}s — '
          'committing to best average '
          '(${storeMap.beaconById(bestId)?.name}, '
          'margin only '
          '${margin.toStringAsFixed(1)}dB)',
        );
      }
    }

    return storeMap.beaconById(
      bestId,
    );
  }

  // ---------------------------------------------------------------------------
  // P0: NAVIGATION HOP VALIDATION
  // ---------------------------------------------------------------------------

  /// Returns true only when [candidate] is a valid immediate next beacon.
  ///
  /// This is the primary anti-teleport gate.
  ///
  /// Example:
  ///
  ///     A → B → C → D
  ///
  ///     current = A
  ///
  ///     candidate = B  => valid
  ///     candidate = C  => BLOCKED
  ///     candidate = D  => BLOCKED
  ///
  /// This remains true even if C/D have dramatically stronger RSSI.
  bool _isNavigationHopValid(
    Beacon? current,
    Beacon candidate,
  ) {
    if (current == null) {
      return true;
    }

    if (candidate.id == current.id) {
      return false;
    }

    // No active route means this is not a normal navigation hop.
    if (destinationBeacon == null || currentPath.length < 2) {
      return true;
    }

    final next = _pathBeaconAfter(
      current.id,
    );

    if (next == null) {
      return false;
    }

    final valid = next.id == candidate.id;

    if (!valid) {
      _log(
        'NAV## TELEPORT BLOCKED: '
        '${current.name} → ${candidate.name}; '
        'expected next=${next.name}',
      );
    }

    return valid;
  }


  bool _shouldSwitchBeacon(
      Beacon candidate,
      Map<String, double> rssiByBleId,
      ) {
    final current = currentBeacon;

    if (current == null || destinationBeacon == null) {
      return false;
    }

    // ------------------------------------------------------------
    // 1. Validate that candidate belongs to the route.
    // ------------------------------------------------------------
    if (!_isValidNavigationHop(candidate)) {
      _log(
        'NAV### REJECT ${candidate.name}: invalid navigation hop '
            'current=${current.name}',
      );
      return false;
    }

    final next = _pathBeaconAfter(current.id);

    if (next == null) {
      return false;
    }

    // ------------------------------------------------------------
    // 2. Candidate must normally be the immediate next beacon.
    //    Secondary is allowed only through controlled look-ahead.
    // ------------------------------------------------------------
    final isImmediateNext = candidate.id == next.id;

    if (!isImmediateNext) {
      final controlledSecondary =
          _enableRouteLookAhead &&
              _secondaryCandidateState?.beacon.id == candidate.id &&
              _primaryHasBeenPassed();

      if (!controlledSecondary) {
        _log(
          'NAV### REJECT ${candidate.name}: not immediate next '
              'current=${current.name} '
              'next=${next.name}',
        );
        return false;
      }

      _log(
        'NAV### APPROVED controlled secondary skip '
            '${current.name} → ${candidate.name}',
      );

      return _passesPhysicalSafetyGate(candidate);
    }

    // ------------------------------------------------------------
    // 3. Get RSSI.
    // ------------------------------------------------------------
    final currentRssi =
        _smoothedRssi(current.id) ??
            _rssiForBeacon(current, rssiByBleId);

    final candidateRssi =
        _smoothedRssi(candidate.id) ??
            _rssiForBeacon(candidate, rssiByBleId);

    if (currentRssi == null || candidateRssi == null) {
      _log(
        'NAV### WAIT ${current.name} → ${candidate.name}: '
            'missing RSSI '
            'current=${currentRssi?.toStringAsFixed(1) ?? "none"} '
            'candidate=${candidateRssi?.toStringAsFixed(1) ?? "none"}',
      );

      return false;
    }

    // ------------------------------------------------------------
    // 4. RSSI comparison.
    // ------------------------------------------------------------
    final delta = candidateRssi - currentRssi;

    final currentTrend = _getRssiTrend(current.id);
    final candidateTrend = _getRssiTrend(candidate.id);

    _log(
      'NAV### SWITCH VALIDATION '
          '${current.name} → ${candidate.name} '
          'currentRSSI=${currentRssi.toStringAsFixed(1)} '
          'candidateRSSI=${candidateRssi.toStringAsFixed(1)} '
          'delta=${delta.toStringAsFixed(1)}dB '
          'currentTrend=$currentTrend '
          'candidateTrend=$candidateTrend '
          'lookAhead=$_enableRouteLookAhead',
    );

    // ------------------------------------------------------------
    // 5. Strong RSSI crossover.
    //
    // Candidate is clearly stronger than current.
    // ------------------------------------------------------------
    if (delta >= 2.0) {
      _log(
        'NAV### SWITCH APPROVED '
            '${current.name} → ${candidate.name} '
            'reason=strong RSSI crossover',
      );

      return _passesPhysicalSafetyGate(candidate);
    }

    // ------------------------------------------------------------
    // 6. Track the CURRENT beacon, not the primary candidate.
    //
    // This is important:
    //
    // current = Seating 2-A
    // next    = SOC
    //
    // _currentBeaconState must represent Seating 2-A.
    // ------------------------------------------------------------
    final currentState = _currentBeaconState;

    final currentDroppedFromPeak =
        currentState != null &&
            currentState.beacon.id == current.id &&
            currentState.peakRssi != null &&
            currentRssi <=
                currentState.peakRssi! - _candidatePeakToleranceDb;

    final currentWeakening =
        currentState != null &&
            currentState.beacon.id == current.id &&
            (
                currentState.trend == _RssiTrend.awayFromNext ||
                    currentState.consecutiveWeakeningReadings >=
                        _candidateWeakeningReadingsRequired
            );

    // ------------------------------------------------------------
    // 7. Candidate state.
    // ------------------------------------------------------------
    final candidateState = _primaryCandidateState;

    final candidateStrengthening =
        candidateState != null &&
            candidateState.beacon.id == candidate.id &&
            (
                candidateState.trend == _RssiTrend.towardNext ||
                    candidateState.consecutiveStrengtheningReadings >= 2
            );

    // ------------------------------------------------------------
    // 8. CURRENT beacon has been passed.
    //
    // No absolute RSSI values here.
    //
    // Example:
    //
    // Seating 2-A peak = -48
    // Seating 2-A now  = -60
    //
    // SOC can still be -72.
    //
    // We can transition because the current beacon has peaked
    // and is now weakening, while the next beacon is detected.
    // ------------------------------------------------------------
    final currentPassed =
        currentDroppedFromPeak &&
            currentWeakening;

    final nextBeaconDetected = candidateRssi != null;

    if (currentPassed && nextBeaconDetected) {
      _log(
        'NAV### SWITCH APPROVED '
            '${current.name} → ${candidate.name} '
            'reason=current beacon passed '
            'currentPeak='
            '${currentState?.peakRssi?.toStringAsFixed(1) ?? "none"} '
            'currentRSSI=${currentRssi.toStringAsFixed(1)} '
            'candidateRSSI=${candidateRssi.toStringAsFixed(1)} '
            'currentDroppedFromPeak=$currentDroppedFromPeak '
            'currentWeakening=$currentWeakening '
            'candidateStrengthening=$candidateStrengthening',
      );

      return _passesPhysicalSafetyGate(candidate);
    }

    // ------------------------------------------------------------
    // 9. Current beacon weakening + candidate reasonably close.
    //
    // This is relative to the current signal, NOT an absolute RSSI.
    // ------------------------------------------------------------
    if (currentWeakening && delta >= -2.0) {
      _log(
        'NAV### SWITCH APPROVED '
            '${current.name} → ${candidate.name} '
            'reason=current weakening '
            'delta=${delta.toStringAsFixed(1)}dB',
      );

      return _passesPhysicalSafetyGate(candidate);
    }

    // ------------------------------------------------------------
    // 10. Candidate is strengthening.
    // ------------------------------------------------------------
    if (candidateStrengthening && delta >= -2.0) {
      _log(
        'NAV### SWITCH APPROVED '
            '${current.name} → ${candidate.name} '
            'reason=candidate strengthening '
            'delta=${delta.toStringAsFixed(1)}dB',
      );

      return _passesPhysicalSafetyGate(candidate);
    }

    // ------------------------------------------------------------
    // 11. Wait.
    // ------------------------------------------------------------
    _log(
      'NAV### SWITCH WAIT '
          '${current.name} → ${candidate.name} '
          'delta=${delta.toStringAsFixed(1)}dB '
          'currentTrend=$currentTrend '
          'candidateTrend=$candidateTrend '
          'currentDroppedFromPeak=$currentDroppedFromPeak '
          'currentWeakening=$currentWeakening '
          'candidateStrengthening=$candidateStrengthening',
    );

    return false;
  }
  //
  // bool _shouldSwitchBeacon(
  //     Beacon candidate,
  //     Map<String, double> rssiByBleId,
  //     ) {
  //   final current = currentBeacon;
  //
  //   // ------------------------------------------------------------
  //   // 1. Destination / current beacon validation
  //   // ------------------------------------------------------------
  //
  //   if (destinationBeacon == null) {
  //     return true;
  //   }
  //
  //   if (current == null) {
  //     return false;
  //   }
  //
  //   // ------------------------------------------------------------
  //   // 2. Determine expected route beacon
  //   // ------------------------------------------------------------
  //
  //   final next = _pathBeaconAfter(current.id);
  //
  //   if (next == null) {
  //     _log(
  //       'NAV### REJECT ${candidate.name}: '
  //           'no next beacon after ${current.name}',
  //     );
  //
  //     return false;
  //   }
  //
  //   Beacon? expectedCandidate = next;
  //
  //   if (_enableRouteLookAhead) {
  //     expectedCandidate = _findNextAvailableRouteBeacon(
  //       current,
  //       rssiByBleId,
  //     );
  //
  //     if (expectedCandidate == null) {
  //       _log(
  //         'NAV### REJECT ${candidate.name}: '
  //             'no available beacon found ahead on route '
  //             'after ${current.name}',
  //       );
  //
  //       return false;
  //     }
  //
  //     if (expectedCandidate.id != next.id) {
  //       _log(
  //         'NAV### LOOK-AHEAD '
  //             '${current.name} → ${expectedCandidate.name} '
  //             '(immediate next ${next.name} unavailable)',
  //       );
  //     }
  //   }
  //
  //   // ------------------------------------------------------------
  //   // 3. Candidate MUST be the expected route beacon
  //   // ------------------------------------------------------------
  //
  //   if (expectedCandidate.id != candidate.id) {
  //     _log(
  //       'NAV### REJECT ${candidate.name}: '
  //           'not expected route beacon '
  //           '(current=${current.name}, '
  //           'immediateNext=${next.name}, '
  //           'expected=${expectedCandidate.name})',
  //     );
  //
  //     return false;
  //   }
  //
  //   // ------------------------------------------------------------
  //   // 4. Resolve candidate RSSI
  //   // ------------------------------------------------------------
  //
  //   final candidateRssi =
  //       _smoothedRssi(candidate.id) ??
  //           _rssiForBeacon(
  //             candidate,
  //             rssiByBleId,
  //           );
  //
  //   if (candidateRssi == null) {
  //     _log(
  //       'NAV### REJECT ${candidate.name}: '
  //           'candidate RSSI unavailable',
  //     );
  //
  //     return false;
  //   }
  //
  //   // ------------------------------------------------------------
  //   // 5. Resolve current RSSI
  //   // ------------------------------------------------------------
  //
  //   final currentRssi =
  //       _smoothedRssi(current.id) ??
  //           _rssiForBeacon(
  //             current,
  //             rssiByBleId,
  //           );
  //
  //   if (currentRssi == null) {
  //     _log(
  //       'NAV### REJECT ${candidate.name}: '
  //           'current beacon ${current.name} RSSI unavailable',
  //     );
  //
  //     return false;
  //   }
  //
  //   // ------------------------------------------------------------
  //   // 6. RSSI trends
  //   // ------------------------------------------------------------
  //
  //   final candidateTrend = _getRssiTrend(candidate.id);
  //   final currentTrend = _getRssiTrend(current.id);
  //
  //   final rssiDelta = candidateRssi - currentRssi;
  //
  //   _log(
  //     'NAV### SWITCH VALIDATION '
  //         '${current.name} → ${candidate.name} '
  //         'currentRSSI=${currentRssi.toStringAsFixed(1)} '
  //         'candidateRSSI=${candidateRssi.toStringAsFixed(1)} '
  //         'delta=${rssiDelta.toStringAsFixed(1)}dB '
  //         'currentTrend=$currentTrend '
  //         'candidateTrend=$candidateTrend '
  //         'lookAhead=$_enableRouteLookAhead',
  //   );
  //
  //   // ------------------------------------------------------------
  //   // 7. Trend state
  //   // ------------------------------------------------------------
  //
  //   final currentIsWeakening =
  //       currentTrend == _RssiTrend.awayFromNext;
  //
  //   final candidateIsStrengthening =
  //       candidateTrend == _RssiTrend.towardNext;
  //
  //   final candidateIsWeakening =
  //       candidateTrend == _RssiTrend.awayFromNext;
  //
  //   // ------------------------------------------------------------
  //   // 8. STRONG RSSI CROSSOVER
  //   //
  //   // Candidate is materially stronger than current.
  //   //
  //   // This is valid even when candidate is already weakening.
  //   //
  //   // Example:
  //   //
  //   // Seating 2-A = -73
  //   // SOC         = -69
  //   //
  //   // SOC may have already peaked because the user passed it.
  //   // ------------------------------------------------------------
  //
  //   if (rssiDelta >= 2.0) {
  //     _log(
  //       'NAV### SWITCH APPROVED '
  //           '${current.name} → ${candidate.name} '
  //           'reason=strong RSSI crossover '
  //           'delta=${rssiDelta.toStringAsFixed(1)}dB '
  //           'candidateTrend=$candidateTrend',
  //     );
  //
  //     return _passesPhysicalSafetyGate(candidate);
  //   }
  //
  //   // ------------------------------------------------------------
  //   // 9. CURRENT WEAKENING + CANDIDATE AT CROSSOVER
  //   //
  //   // Candidate does NOT need to be strengthening.
  //   //
  //   // This is important for fast movement.
  //   //
  //   // Example:
  //   //
  //   // Seating 2-A = -71
  //   // SOC         = -70
  //   //
  //   // SOC may be:
  //   //
  //   // -68 → -69 → -70
  //   //
  //   // i.e. technically weakening, but the user has already passed
  //   // the SOC beacon.
  //   // ------------------------------------------------------------
  //
  //   if (currentIsWeakening &&
  //       rssiDelta >= -1.0) {
  //     _log(
  //       'NAV## SWITCH APPROVED '
  //           '${current.name} → ${candidate.name} '
  //           'reason=current weakening + candidate at crossover '
  //           'delta=${rssiDelta.toStringAsFixed(1)}dB '
  //           'candidateTrend=$candidateTrend',
  //     );
  //
  //     return _passesPhysicalSafetyGate(candidate);
  //   }
  //
  //   // ------------------------------------------------------------
  //   // 10. CANDIDATE STRENGTHENING + CROSSOVER
  //   //
  //   // Candidate is approaching the current beacon and is within
  //   // approximately 1dB of it.
  //   // ------------------------------------------------------------
  //
  //   if (candidateIsStrengthening &&
  //       rssiDelta >= -1.0) {
  //     _log(
  //       'NAV## SWITCH APPROVED '
  //           '${current.name} → ${candidate.name} '
  //           'reason=candidate strengthening + crossover '
  //           'delta=${rssiDelta.toStringAsFixed(1)}dB',
  //     );
  //
  //     return _passesPhysicalSafetyGate(candidate);
  //   }
  //
  //   // ------------------------------------------------------------
  //   // 11. BOTH TRENDS UNKNOWN + RSSI CROSSOVER
  //   //
  //   // Important for fast users where there are not enough samples
  //   // to classify the trend correctly.
  //   // ------------------------------------------------------------
  //
  //   if (currentTrend == _RssiTrend.unknown &&
  //       candidateTrend == _RssiTrend.unknown &&
  //       rssiDelta >= 0.0) {
  //     _log(
  //       'NAV## SWITCH APPROVED '
  //           '${current.name} → ${candidate.name} '
  //           'reason=RSSI crossover with unknown trends '
  //           'delta=${rssiDelta.toStringAsFixed(1)}dB',
  //     );
  //
  //     return _passesPhysicalSafetyGate(candidate);
  //   }
  //
  //   // ------------------------------------------------------------
  //   // 12. CURRENT WEAKENING + CANDIDATE UNKNOWN
  //   //
  //   // We are leaving the current beacon and candidate has reached
  //   // at least the same RSSI level.
  //   // ------------------------------------------------------------
  //
  //   if (currentIsWeakening &&
  //       candidateTrend == _RssiTrend.unknown &&
  //       rssiDelta >= 0.0) {
  //     _log(
  //       'NAV## SWITCH APPROVED '
  //           '${current.name} → ${candidate.name} '
  //           'reason=current weakening + candidate reached current RSSI '
  //           'delta=${rssiDelta.toStringAsFixed(1)}dB',
  //     );
  //
  //     return _passesPhysicalSafetyGate(candidate);
  //   }
  //
  //   // ------------------------------------------------------------
  //   // 13. CANDIDATE IS WEAKENING BUT HAS NOT CROSSED CURRENT
  //   //
  //   // This is the ONLY case where candidate weakening is rejected.
  //   //
  //   // Example:
  //   //
  //   // Seating 2-A = -68
  //   // SOC         = -74
  //   //
  //   // SOC is weakening and is still significantly weaker.
  //   // There is not enough evidence that the user reached SOC.
  //   // ------------------------------------------------------------
  //
  //   if (candidateIsWeakening &&
  //       rssiDelta < -1.0) {
  //     _log(
  //       'NAV## WAIT ${candidate.name}: '
  //           'candidate weakening before RSSI crossover '
  //           'delta=${rssiDelta.toStringAsFixed(1)}dB',
  //     );
  //
  //     return false;
  //   }
  //
  //   // ------------------------------------------------------------
  //   // 14. CANDIDATE STRENGTHENING BUT NOT YET AT CROSSOVER
  //   // ------------------------------------------------------------
  //
  //   if (candidateIsStrengthening) {
  //     _log(
  //       'NAV## WAIT ${candidate.name}: '
  //           'candidate RSSI improving but not yet at transition level '
  //           'delta=${rssiDelta.toStringAsFixed(1)}dB '
  //           'required>=-1.0dB',
  //     );
  //
  //     return false;
  //   }
  //
  //   // ------------------------------------------------------------
  //   // 15. NO SUFFICIENT RSSI EVIDENCE
  //   //
  //   // PDR must NEVER force the transition.
  //   // ------------------------------------------------------------
  //
  //   _log(
  //     'NAV## REJECT ${candidate.name}: '
  //         'insufficient RSSI transition evidence '
  //         'currentTrend=$currentTrend '
  //         'candidateTrend=$candidateTrend '
  //         'delta=${rssiDelta.toStringAsFixed(1)}dB',
  //   );
  //
  //   return false;
  // }


  Beacon? _findNextAvailableRouteBeacon(
      Beacon current,
      Map<String, double> rssiByBleId,
      ) {
    final route = currentPath;

    final currentIndex =
    route.indexWhere((beacon) => beacon.id == current.id);

    if (currentIndex < 0) {
      return null;
    }

    // Look only forward on the existing route.
    //
    // Do NOT search the whole beacon list.
    // This preserves route ordering and prevents teleporting.
    for (var i = currentIndex + 1; i < route.length; i++) {
      final beacon = route[i];

      // Destination is valid as a final candidate too.
      final rssi =
          _smoothedRssi(beacon.id) ??
              _rssiForBeacon(
                beacon,
                rssiByBleId,
              );

      if (rssi != null) {
        _log(
          'NAV## LOOK-AHEAD AVAILABLE '
              '${current.name} → ${beacon.name} '
              'routeIndex=$i '
              'rssi=${rssi.toStringAsFixed(1)}',
        );

        return beacon;
      }

      _log(
        'NAV## LOOK-AHEAD SKIP '
            '${beacon.name}: RSSI unavailable',
      );
    }

    return null;
  }
  // ---------------------------------------------------------------------------
  // P0 / P1 SWITCH DECISION
  // bool _shouldSwitchBeacon(
  //     Beacon candidate,
  //     Map<String, double> rssiByBleId,
  //     ) {
  //   final current = currentBeacon;
  //
  //   // ------------------------------------------------------------
  //   // 1. Destination / current beacon validation
  //   // ------------------------------------------------------------
  //
  //   if (destinationBeacon == null) {
  //     return true;
  //   }
  //
  //   if (current == null) {
  //     return false;
  //   }
  //
  //   // ------------------------------------------------------------
  //   // 2. Candidate MUST be the immediate next beacon.
  //   //    This prevents teleporting / skipping route nodes.
  //   // ------------------------------------------------------------
  //
  //   final next = _pathBeaconAfter(current.id);
  //
  //   if (next == null || next.id != candidate.id) {
  //     _log(
  //       'NAV## REJECT ${candidate.name}: '
  //           'not immediate next beacon '
  //           '(current=${current.name}, '
  //           'expected=${next?.name ?? "none"})',
  //     );
  //
  //     return false;
  //   }
  //
  //   // ------------------------------------------------------------
  //   // 3. Resolve RSSI
  //   // ------------------------------------------------------------
  //
  //   final candidateRssi =
  //       _smoothedRssi(candidate.id) ??
  //           _rssiForBeacon(
  //             candidate,
  //             rssiByBleId,
  //           );
  //
  //   if (candidateRssi == null) {
  //     _log(
  //       'NAV## REJECT ${candidate.name}: '
  //           'candidate RSSI unavailable',
  //     );
  //
  //     return false;
  //   }
  //
  //   final currentRssi =
  //       _smoothedRssi(current.id) ??
  //           _rssiForBeacon(
  //             current,
  //             rssiByBleId,
  //           );
  //
  //   if (currentRssi == null) {
  //     _log(
  //       'NAV## REJECT ${candidate.name}: '
  //           'current beacon ${current.name} RSSI unavailable',
  //     );
  //
  //     return false;
  //   }
  //
  //   // ------------------------------------------------------------
  //   // 4. RSSI trends
  //   // ------------------------------------------------------------
  //
  //   final candidateTrend =
  //   _getRssiTrend(candidate.id);
  //
  //   final currentTrend =
  //   _getRssiTrend(current.id);
  //
  //   final rssiDelta =
  //       candidateRssi - currentRssi;
  //
  //   _log(
  //     'NAV## SWITCH VALIDATION '
  //         '${current.name} → ${candidate.name} '
  //         'currentRSSI=${currentRssi.toStringAsFixed(1)} '
  //         'candidateRSSI=${candidateRssi.toStringAsFixed(1)} '
  //         'delta=${rssiDelta.toStringAsFixed(1)}dB '
  //         'currentTrend=$currentTrend '
  //         'candidateTrend=$candidateTrend',
  //   );
  //
  //   // ------------------------------------------------------------
  //   // 5. Candidate is moving AWAY
  //   //
  //   // Strong rejection. We don't want to transition simply because
  //   // current beacon is getting weaker.
  //   // ------------------------------------------------------------
  //
  //   if (candidateTrend == _RssiTrend.awayFromNext) {
  //     _log(
  //       'NAV## REJECT ${candidate.name}: '
  //           'candidate RSSI is weakening',
  //     );
  //
  //     return false;
  //   }
  //
  //   // ------------------------------------------------------------
  //   // 6. Calculate RSSI evidence
  //   // ------------------------------------------------------------
  //
  //   final currentIsWeakening =
  //       currentTrend == _RssiTrend.awayFromNext;
  //
  //   final candidateIsStrengthening =
  //       candidateTrend == _RssiTrend.towardNext;
  //
  //   final bothTrendsSupportSwitch =
  //       currentIsWeakening &&
  //           candidateIsStrengthening;
  //
  //   final candidateClearlyStronger =
  //       rssiDelta >= _beaconSwitchThresholdDb;
  //
  //   final candidateSlightlyStronger =
  //       rssiDelta >= 4.0;
  //
  //   // ------------------------------------------------------------
  //   // 7. Decision tree
  //   // ------------------------------------------------------------
  //
  //   // BEST CASE:
  //   //
  //   // Current beacon is getting weaker
  //   // AND
  //   // next beacon is getting stronger.
  //   //
  //   // This is exactly what we expect while physically moving
  //   // from current → next.
  //   //
  //   if (bothTrendsSupportSwitch &&
  //       candidateSlightlyStronger) {
  //     _log(
  //       'NAV## SWITCH APPROVED '
  //           '${current.name} → ${candidate.name} '
  //           'reason=current weakening + '
  //           'candidate strengthening '
  //           'delta=${rssiDelta.toStringAsFixed(1)}dB',
  //     );
  //
  //     return _passesPhysicalSafetyGate(candidate);
  //   }
  //
  //   // STRONG RSSI EVIDENCE:
  //   //
  //   // Even if trends are not yet reliable, a clearly stronger
  //   // candidate is sufficient.
  //   //
  //   if (candidateClearlyStronger) {
  //     _log(
  //       'NAV## SWITCH APPROVED '
  //           '${current.name} → ${candidate.name} '
  //           'reason=candidate RSSI clearly stronger '
  //           'delta=${rssiDelta.toStringAsFixed(1)}dB',
  //     );
  //
  //     return _passesPhysicalSafetyGate(candidate);
  //   }
  //
  //   // Current beacon is weakening but candidate trend is unknown.
  //   //
  //   // We know we're leaving the current beacon, but we don't yet
  //   // have enough evidence that the candidate is where the user
  //   // is moving toward.
  //   //
  //   if (currentIsWeakening &&
  //       candidateTrend == _RssiTrend.unknown) {
  //     const requiredMarginDb = 6.0;
  //
  //     if (rssiDelta >= requiredMarginDb) {
  //       _log(
  //         'NAV## SWITCH APPROVED '
  //             '${current.name} → ${candidate.name} '
  //             'reason=current weakening + '
  //             'strong RSSI margin '
  //             'delta=${rssiDelta.toStringAsFixed(1)}dB',
  //       );
  //
  //       return _passesPhysicalSafetyGate(candidate);
  //     }
  //
  //     _log(
  //       'NAV## REJECT ${candidate.name}: '
  //           'current weakening but candidate trend unknown '
  //           'delta=${rssiDelta.toStringAsFixed(1)}dB '
  //           'required=${requiredMarginDb.toStringAsFixed(1)}dB',
  //     );
  //
  //     return false;
  //   }
  //
  //   // Candidate is strengthening but current trend is unknown.
  //   //
  //   // Allow only when candidate has established a meaningful
  //   // advantage.
  //   //
  //   if (candidateIsStrengthening) {
  //     const requiredMarginDb = 3.0;
  //
  //     if (rssiDelta >= requiredMarginDb) {
  //       _log(
  //         'NAV## SWITCH APPROVED '
  //             '${current.name} → ${candidate.name} '
  //             'reason=candidate strengthening + '
  //             'RSSI margin '
  //             'delta=${rssiDelta.toStringAsFixed(1)}dB',
  //       );
  //
  //       return _passesPhysicalSafetyGate(candidate);
  //     }
  //
  //     _log(
  //       'NAV## REJECT ${candidate.name}: '
  //           'candidate strengthening but RSSI margin insufficient '
  //           'delta=${rssiDelta.toStringAsFixed(1)}dB '
  //           'required=${requiredMarginDb.toStringAsFixed(1)}dB',
  //     );
  //
  //     return false;
  //   }
  //
  //   // ------------------------------------------------------------
  //   // 8. Neither side provides useful direction evidence.
  //   //
  //   // Do NOT use PDR to force the transition.
  //   // ------------------------------------------------------------
  //
  //   _log(
  //     'NAV## REJECT ${candidate.name}: '
  //         'insufficient RSSI transition evidence '
  //         'currentTrend=$currentTrend '
  //         'candidateTrend=$candidateTrend '
  //         'delta=${rssiDelta.toStringAsFixed(1)}dB',
  //   );
  //
  //   return false;
  // }
  _RssiTrend _getRssiTrend(String beaconId) {
    final beacon = storeMap.beaconById(beaconId);

    if (beacon == null) {
      return _RssiTrend.unknown;
    }

    String? bleId;

    for (final entry in _rssiEma.entries) {
      if (beacon.matchesBleId(entry.key)) {
        bleId = entry.key;
        break;
      }
    }

    if (bleId == null) {
      return _RssiTrend.unknown;
    }

    final history = _rssiHistory[bleId];

    if (history == null || history.length < 4) {
      return _RssiTrend.unknown;
    }

    // Compare the latest EMA value with the value
    // two samples earlier.
    //
    // Shorter lookback makes the transition more responsive
    // to actual movement while EMA still smooths BLE noise.
    const lookback = 2;

    if (history.length <= lookback) {
      return _RssiTrend.unknown;
    }

    final latest = history.last;
    final previous = history[history.length - 1 - lookback];

    final delta = latest - previous;

    // Lower threshold because BLE RSSI can fluctuate heavily.
    // 0.8 dB allows smaller but consistent movement to be detected.
    const trendThresholdDb = 0.8;

    _log(
      'NAV## RSSI TREND '
          '${beacon.name} '
          'previous=${previous.toStringAsFixed(1)} '
          'latest=${latest.toStringAsFixed(1)} '
          'delta=${delta.toStringAsFixed(1)}dB '
          'threshold=${trendThresholdDb.toStringAsFixed(1)}dB '
          'samples=${history.length}',
    );

    // RSSI becomes less negative = user is moving toward beacon.
    if (delta >= trendThresholdDb) {
      return _RssiTrend.towardNext;
    }

    // RSSI becomes more negative = user is moving away from beacon.
    if (delta <= -trendThresholdDb) {
      return _RssiTrend.awayFromNext;
    }

    return _RssiTrend.unknown;
  }

  bool _passesPhysicalSafetyGate(
      Beacon candidate,
      ) {
    final physicallyReachable =
    _isPhysicallyReachable(candidate);

    if (!physicallyReachable) {
      _log(
        'NAV### REJECT ${candidate.name}: '
            'physical safety gate failed',
      );

      return false;
    }

    return true;
  }

  // ---------------------------------------------------------------------------
  // PHYSICAL REACHABILITY
  // ---------------------------------------------------------------------------

  /// Checks whether the candidate beacon could physically have been reached
  /// based on the distance walked since the current beacon was confirmed.
  ///
  /// The graph distance is preferred over straight-line distance because
  /// indoor navigation must respect corridors/walls.
  bool _isPhysicallyReachable(
    Beacon candidate,
  ) {
    final anchor = currentBeacon;

    if (anchor == null) {
      return true;
    }

    if (anchor.id == candidate.id) {
      return true;
    }

    double walkingDistanceMeters;

    final routeResult = _pathfinder.findPath(
      storeMap,
      anchor.id,
      candidate.id,
    );

    if (routeResult.path.isNotEmpty) {
      walkingDistanceMeters = routeResult.distanceMeters;
    } else {
      // Fallback when the graph does not contain a route.
      walkingDistanceMeters = (candidate.position - anchor.position).distance *
          storeMap.metersPerUnit;
    }

    final plausibleMeters = _metersSinceBeacon + _reachabilityToleranceMeters;

    final reachable = walkingDistanceMeters <= plausibleMeters;

    _log(
      'NAV### reachability check: '
      '${candidate.name} is '
      '${walkingDistanceMeters.toStringAsFixed(1)}m '
      'away via graph from ${anchor.name}, '
      '${_metersSinceBeacon.toStringAsFixed(1)}m '
      'walked so far '
      '(tolerance '
      '${_reachabilityToleranceMeters}m) '
      '→ ${reachable ? "REACHABLE" : "REJECTED"}',
    );

    return reachable;
  }

  bool _primaryHasBeenPassed() {
    final primary = _primaryCandidateState;
    final secondary = _secondaryCandidateState;

    if (!_enableRouteLookAhead ||
        primary == null ||
        secondary == null) {
      return false;
    }

    final primaryRssi = primary.latestRssi;
    final secondaryRssi = secondary.latestRssi;

    if (primaryRssi == null) {
      return false;
    }

    // -------------------------------------------------------------------------
    // 1. PRIMARY HAS DROPPED SIGNIFICANTLY FROM ITS PEAK
    //
    // This is the strongest indication that the user has passed the beacon.
    // -------------------------------------------------------------------------

    final primaryDroppedFromPeak =
        primary.peakRssi != null &&
            primaryRssi <=
                primary.peakRssi! - _candidatePeakToleranceDb;

    // -------------------------------------------------------------------------
    // 2. PRIMARY IS CURRENTLY WEAKENING
    // -------------------------------------------------------------------------

    final primaryWeakening =
        primary.trend == _RssiTrend.awayFromNext ||
            primary.consecutiveWeakeningReadings >=
                _candidateWeakeningReadingsRequired;

    // -------------------------------------------------------------------------
    // 3. SECONDARY IS STARTING TO TAKE OVER
    //
    // It does NOT need to be stronger than primary yet.
    //
    // This is important because BLE RSSI can have a large difference between
    // adjacent beacons due to walls, orientation and antenna behaviour.
    // -------------------------------------------------------------------------

    final secondaryStrengthening =
        secondary.trend == _RssiTrend.towardNext ||
            secondary.consecutiveStrengtheningReadings >= 2;

    // -------------------------------------------------------------------------
    // 4. SECONDARY MUST HAVE RSSI EVIDENCE
    // -------------------------------------------------------------------------

    final secondaryHasRssi =
        secondaryRssi != null;

    if (!secondaryHasRssi) {
      return false;
    }

    // -------------------------------------------------------------------------
    // PRIMARY PASSED
    //
    // We accept either:
    //
    // A) primary has peaked + dropped + is weakening
    //
    // OR
    //
    // B) primary has peaked + dropped + secondary is actively strengthening
    //    and primary is already substantially weak.
    // -------------------------------------------------------------------------

    final primaryClearlyWeak =
        primaryRssi <= -70.0;

    final passed =
        primaryDroppedFromPeak &&
            (
                primaryWeakening ||
                    (
                        secondaryStrengthening &&
                            primaryClearlyWeak
                    )
            );

    if (passed) {
      _log(
        'NAV## PRIMARY PASSED '
            'primary=${primary.beacon.name} '
            'primaryRSSI=${primaryRssi.toStringAsFixed(1)} '
            'primaryPeak=${primary.peakRssi?.toStringAsFixed(1) ?? "none"} '
            'primaryTrend=${primary.trend} '
            'primaryWeakening=$primaryWeakening '
            'secondary=${secondary.beacon.name} '
            'secondaryRSSI=${secondaryRssi?.toStringAsFixed(1) ?? "none"} '
            'secondaryTrend=${secondary.trend} '
            'secondaryStrengthening=$secondaryStrengthening',
      );
    }

    return passed;
  }

  void _updateCurrentBeaconState(
      Map<String, double> rssiByBleId,
      ) {
    final current = currentBeacon;

    if (current == null) {
      _currentBeaconState = null;
      return;
    }

    if (_currentBeaconState?.beacon.id != current.id) {
      _currentBeaconState = _BeaconCandidateState(current);
    }

    _updateSingleBeaconCandidateState(
      _currentBeaconState!,
      rssiByBleId,
    );
  }


  void _updateBeaconCandidateStates(
      Map<String, double> rssiByBleId,
      ) {
    final current = currentBeacon;

    if (current == null || currentPath.isEmpty) {
      _primaryCandidateState = null;
      _secondaryCandidateState = null;
      return;
    }

    final currentIndex =
    currentPath.indexWhere((b) => b.id == current.id);

    if (currentIndex < 0) {
      _primaryCandidateState = null;
      _secondaryCandidateState = null;
      return;
    }

    final primary =
    currentIndex + 1 < currentPath.length
        ? currentPath[currentIndex + 1]
        : null;

    final secondary =
    currentIndex + 2 < currentPath.length
        ? currentPath[currentIndex + 2]
        : null;

    if (_primaryCandidateState?.beacon.id != primary?.id) {
      _primaryCandidateState =
      primary == null
          ? null
          : _BeaconCandidateState(primary);
    }

    if (_secondaryCandidateState?.beacon.id != secondary?.id) {
      _secondaryCandidateState =
      secondary == null
          ? null
          : _BeaconCandidateState(secondary);
    }

    if (_primaryCandidateState != null) {
      _updateSingleBeaconCandidateState(
        _primaryCandidateState!,
        rssiByBleId,
      );
    }

    if (_secondaryCandidateState != null) {
      _updateSingleBeaconCandidateState(
        _secondaryCandidateState!,
        rssiByBleId,
      );
    }
  }

  void _updateSingleBeaconCandidateState(
      _BeaconCandidateState state,
      Map<String, double> rssiByBleId,
      ) {
    final rawRssi = _rssiForBeacon(
      state.beacon,
      rssiByBleId,
    );

    if (rawRssi == null) {
      return;
    }

    final rssi =
        _smoothedRssi(state.beacon.id) ?? rawRssi;

    final previous = state.latestRssi;

    state.latestRssi = rssi;
    state.lastSeen = DateTime.now();
    state.firstSeen ??= state.lastSeen;

    if (state.peakRssi == null || rssi > state.peakRssi!) {
      state.peakRssi = rssi;
    }

    if (previous != null) {
      final delta = rssi - previous;

      if (delta >= 0.3) {
        state.consecutiveStrengtheningReadings++;
        state.consecutiveWeakeningReadings = 0;
      } else if (delta <= -0.3) {
        state.consecutiveWeakeningReadings++;
        state.consecutiveStrengtheningReadings = 0;
      } else {
        state.consecutiveStrengtheningReadings = 0;
        state.consecutiveWeakeningReadings = 0;
      }
    }

    if (state.peakRssi != null &&
        state.latestRssi != null &&
        state.latestRssi! <=
            state.peakRssi! - _candidatePeakToleranceDb &&
        state.consecutiveWeakeningReadings >=
            _candidateWeakeningReadingsRequired) {
      state.hasPassedPeak = true;
    }

    state.trend = _getRssiTrend(state.beacon.id);

    _log(
      'NAV## CANDIDATE STATE '
          '${state.beacon.name} '
          'rssi=${rssi.toStringAsFixed(1)} '
          'peak=${state.peakRssi?.toStringAsFixed(1) ?? "none"} '
          'trend=${state.trend} '
          'strengthening=${state.consecutiveStrengtheningReadings} '
          'weakening=${state.consecutiveWeakeningReadings} '
          'passedPeak=${state.hasPassedPeak}',
    );
  }

  // ---------------------------------------------------------------------------
  // RSSI TREND
  // ---------------------------------------------------------------------------

  /// Tracks RSSI trend for the immediate next route beacon.
  ///
  /// Positive delta:
  ///     RSSI stronger -> likely moving toward beacon
  ///
  /// Negative delta:
  ///     RSSI weaker -> likely moving away from beacon
  ///
  /// This is deliberately conservative and is only a supporting signal.
  void _updateNextBeaconTrend(
    Map<String, double> rssiByBleId,
  ) {
    final cb = currentBeacon;

    final next = cb == null
        ? null
        : _pathBeaconAfter(
            cb.id,
          );

    if (next == null) {
      _nextBeaconRssiWindow.clear();

      _trackedNextBeaconId = null;

      _nextBeaconTrend = _RssiTrend.unknown;

      headingTowardsBeaconInPath = null;

      return;
    }

    // New route segment.
    if (_trackedNextBeaconId != next.id) {
      _trackedNextBeaconId = next.id;

      _nextBeaconRssiWindow.clear();

      _nextBeaconTrend = _RssiTrend.unknown;

      headingTowardsBeaconInPath = null;
    }

    final rawRssi = _rssiForBeacon(
      next,
      rssiByBleId,
    );

    if (rawRssi == null) {
      // Don't overwrite the previous trend because of one missing BLE scan.
      return;
    }

    final rssi = _smoothedRssi(next.id) ?? rawRssi;

    _nextBeaconRssiWindow.add(
      rssi,
    );

    if (_nextBeaconRssiWindow.length > _rssiTrendWindowSize) {
      _nextBeaconRssiWindow.removeAt(
        0,
      );
    }

    if (_nextBeaconRssiWindow.length < 4) {
      return;
    }

    final mid = _nextBeaconRssiWindow.length ~/ 2;

    final firstAvg = _average(
      _nextBeaconRssiWindow.sublist(
        0,
        mid,
      ),
    );

    final secondAvg = _average(
      _nextBeaconRssiWindow.sublist(mid),
    );

    final delta = secondAvg - firstAvg;

    final previousTrend = _nextBeaconTrend;

    // -----------------------------------------------------------------------
    // P0 FIX:
    //
    // Stronger RSSI = POSITIVE delta = toward next.
    // Weaker RSSI = NEGATIVE delta = away from next.
    // -----------------------------------------------------------------------

    if (delta >= _rssiTrendThresholdDb) {
      _nextBeaconTrend = _RssiTrend.towardNext;

      headingTowardsBeaconInPath = next;
    } else if (delta <= -_rssiTrendThresholdDb) {
      _nextBeaconTrend = _RssiTrend.awayFromNext;

      headingTowardsBeaconInPath = null;
    } else {
      _nextBeaconTrend = _RssiTrend.unknown;

      headingTowardsBeaconInPath = null;
    }

    if (previousTrend != _nextBeaconTrend) {
      _log(
        'NAV## RSSI trend toward '
        '${next.name}: '
        '$_nextBeaconTrend '
        '(Δ${delta.toStringAsFixed(1)}dB)',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // AVERAGE
  // ---------------------------------------------------------------------------

  double _average(
    List<double> values,
  ) {
    if (values.isEmpty) {
      return 0.0;
    }

    return values.reduce(
          (a, b) => a + b,
        ) /
        values.length;
  }

  // ---------------------------------------------------------------------------
  // BEACON CONFIRMATION / VISUAL CORRECTION
  // ---------------------------------------------------------------------------

  void _snapToCurrentBeacon() {
    final beacon = currentBeacon;

    if (beacon == null) {
      return;
    }

    final snap = beacon.position;

    final current = liveUserPosition ?? _targetPosition ?? beacon.position;

    final drift = (current - snap).distance;

    // Never hard-jump during a normal beacon confirmation.
    //
    // The visual marker will smoothly approach the new beacon.
    _targetPosition = snap;

    _segmentProgressMeters = 0.0;

    _segmentStepCount = 0;

    _segmentBoundarySince = null;

    _metersSinceBeacon = 0.0;

    // New segment => old RSSI trend is invalid.
    _nextBeaconRssiWindow.clear();

    _trackedNextBeaconId = null;

    _nextBeaconTrend = _RssiTrend.unknown;

    headingTowardsBeaconInPath = null;

    // First-fix state has completed.
    _initialFixRssiWindows.clear();

    _initialFixStartedAt = null;

    _primaryCandidateState = null;
    _secondaryCandidateState = null;
    _currentBeaconState = null;
    // EMA is also reset here.
    //
    // This prevents stale values from the previous segment influencing
    // the first candidate decision on the new segment.
    _rssiEma.clear();

    if (drift > _maxBeaconCorrectionResetMeters) {
      // Genuine recovery case.
      //
      // If we are >8m away from the newly confirmed beacon, keeping the
      // old position would stretch the route across a large gap.
      liveUserPosition = snap;

      _log(
        'NAV## large beacon correction '
        '${drift.toStringAsFixed(1)}m '
        '→ hard recovery reset',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // PDR STEP
  // ---------------------------------------------------------------------------

  void _onStep(
      double distanceMeters,
      ) {
    if (distanceMeters <= 0.0) {
      return;
    }

    // -------------------------------------------------------------------------
    // RAW PDR DISTANCE
    //
    // Keep this only for diagnostics.
    // It must NOT be used to advance the beacon or force route progress.
    // -------------------------------------------------------------------------

    _metersSinceBeacon += distanceMeters;

    _log(
      'NAV## steps taken '
          'distanceMeters=${distanceMeters.toStringAsFixed(2)} '
          '_metersSinceBeacon=${_metersSinceBeacon.toStringAsFixed(2)}',
    );

    final startBeacon = currentBeacon;

    if (startBeacon == null) {
      return;
    }

    final next = _pathBeaconAfter(
      startBeacon.id,
    );

    if (next == null) {
      return;
    }

    final segment = _segmentLengthMeters(
      startBeacon,
      next.position,
    );

    if (segment <= 0.0) {
      return;
    }

    _segmentStepCount++;

    // -------------------------------------------------------------------------
    // VISUAL PDR PROGRESS
    //
    // IMPORTANT:
    //
    // PDR tells us that the user is moving, but it does NOT tell us that
    // the user is moving toward the next beacon.
    //
    // RSSI is therefore the authority for forward route progress.
    //
    // towardNext -> allow visual movement
    // unknown     -> DO NOT move toward next beacon
    // awayFromNext-> DO NOT move toward next beacon
    // -------------------------------------------------------------------------

    final effectiveDelta = switch (_nextBeaconTrend) {
      _RssiTrend.towardNext => distanceMeters,
      _RssiTrend.unknown => 0.0,
      _RssiTrend.awayFromNext => 0.0,
    };

    _segmentProgressMeters = (
        _segmentProgressMeters + effectiveDelta
    ).clamp(
      0.0,
      segment,
    );

    final forwardRatio = segment <= 0.0
        ? 0.0
        : (_segmentProgressMeters / segment).clamp(
      0.0,
      1.0,
    );

    _log(
      'NAV## PDR progress '
          '${startBeacon.name} → ${next.name} '
          'forward=${(forwardRatio * 100).toStringAsFixed(0)}% '
          'trend=$_nextBeaconTrend '
          'effectiveDelta=${effectiveDelta.toStringAsFixed(2)}',
    );

    // -------------------------------------------------------------------------
    // IMPORTANT:
    //
    // PDR MUST NEVER change currentBeacon.
    //
    // Even if PDR reaches 90%, 100%, or exceeds the segment distance,
    // beacon transition must still wait for RSSI confirmation.
    // -------------------------------------------------------------------------

    if (forwardRatio >= 0.90) {
      _log(
        'NAV## PDR THRESHOLD '
            '${startBeacon.name} → ${next.name} '
            'forward=${(forwardRatio * 100).toStringAsFixed(0)}% '
            'trend=$_nextBeaconTrend '
            '— RSSI confirmation required; beacon will NOT advance from PDR',
      );
    }

    // -------------------------------------------------------------------------
    // VISUAL POSITION
    // -------------------------------------------------------------------------

    final projected = _pointAlongCurrentEdge(
      startBeacon,
      next.position,
      forwardRatio,
    );

    _targetPosition = projected;

    liveUserPosition ??= projected;

    if (status != NavigationStatus.arrived) {
      status = NavigationStatus.navigating;
    }

    notifyListeners();
  }

  void _forceAdvanceToNextBeaconByPdr(
    Beacon nextBeacon, {
    required String reason,
  }) {
    final previousBeacon = currentBeacon;

    if (previousBeacon == null || previousBeacon.id == nextBeacon.id) {
      return;
    }

    // Final route-order guard. PDR may advance only one edge at a time.
    if (!_isNavigationHopValid(previousBeacon, nextBeacon)) {
      _log(
        'NAV## PDR ADVANCE BLOCKED '
        '${previousBeacon.name} → ${nextBeacon.name}',
      );
      return;
    }

    final now = DateTime.now();
    final inCooldown = _lastBeaconSwitchAt != null &&
        now.difference(_lastBeaconSwitchAt!) < _beaconSwitchCooldown;

    if (inCooldown) {
      return;
    }

    final prevPath = List<Beacon>.from(currentPath);

    _recordCompletedSegmentCalibration(
      previousBeacon,
      nextBeacon,
    );

    _clearPendingBeaconCandidate();

    currentBeacon = nextBeacon;
    _lastBeaconSwitchAt = now;

    _recomputePath();
    _snapToCurrentBeacon();

    status = nextBeacon.id == destinationBeacon?.id
        ? NavigationStatus.arrived
        : NavigationStatus.navigating;

    _zoneEnteredController.add(nextBeacon);

    _log(
      'NAV## PDR ADVANCE → ${nextBeacon.name} '
      'from=${previousBeacon.name} '
      'reason=$reason '
      'rawMeters=${_metersSinceBeacon.toStringAsFixed(2)} '
      'previousPathNodes=${prevPath.length}',
    );

    notifyListeners();
  }


  bool _isUserOnCurrentRouteSegment() {
    final current = currentBeacon;
    if (current == null || liveUserPosition == null) {
      return false;
    }

    final next = _pathBeaconAfter(current.id);
    if (next == null) {
      return false;
    }

    final ax = current.position.dx;
    final ay = current.position.dy;

    final bx = next.position.dx;
    final by = next.position.dy;

    final px = liveUserPosition!.dx;
    final py = liveUserPosition!.dy;

    final abx = bx - ax;
    final aby = by - ay;

    final segmentLengthSquared =
        (abx * abx) + (aby * aby);

    if (segmentLengthSquared <= 0.0001) {
      return false;
    }

    // Vector from current beacon to user.
    final apx = px - ax;
    final apy = py - ay;

    // Project user position onto the route segment.
    final t = ((apx * abx) + (apy * aby)) /
        segmentLengthSquared;

    final clampedT = t.clamp(0.0, 1.0);

    // Closest point on route segment.
    final nearestX = ax + (clampedT * abx);
    final nearestY = ay + (clampedT * aby);

    final dx = px - nearestX;
    final dy = py - nearestY;

    final deviationMapUnits = sqrt(
      (dx * dx) + (dy * dy),
    );

    // Your map uses metersPerUnit = 0.104.
    final deviationMeters =
        deviationMapUnits * storeMap.metersPerUnit;

    const maxRouteDeviationMeters = 3.0;

    final onRoute =
        deviationMeters <= maxRouteDeviationMeters;

    final segmentLengthMapUnits =
    sqrt(segmentLengthSquared);

    final distanceAlongRouteMapUnits =
        clampedT * segmentLengthMapUnits;

    final distanceAlongRouteMeters =
        distanceAlongRouteMapUnits * storeMap.metersPerUnit;

    _log(
      'NAV## ROUTE CHECK '
          '${current.name} → ${next.name} '
          'projection=${(clampedT * 100).toStringAsFixed(0)}% '
          'along=${distanceAlongRouteMeters.toStringAsFixed(2)}m '
          'deviation=${deviationMeters.toStringAsFixed(2)}m '
          'onRoute=$onRoute',
    );

    return onRoute;
  }
  // ---------------------------------------------------------------------------
  // STRIDE CALIBRATION
  // ---------------------------------------------------------------------------

  void _recordCompletedSegmentCalibration(
    Beacon? previous,
    Beacon candidate,
  ) {
    if (previous == null || _segmentStepCount <= 0 || currentPath.length < 2) {
      return;
    }

    final nextIndex = currentPath.indexWhere(
          (beacon) => beacon.id == previous.id,
        ) +
        1;

    if (nextIndex <= 0 ||
        nextIndex >= currentPath.length ||
        currentPath[nextIndex].id != candidate.id) {
      return;
    }

    final edge = storeMap.edgeBetween(
      previous.id,
      candidate.id,
    );

    if (edge == null) {
      return;
    }

    if (_segmentProgressMeters < edge.distanceMeters * 0.5) {
      return;
    }

    _log(
      'NAV## recordStrideCalibration '
      'distance=${edge.distanceMeters} '
      'steps=$_segmentStepCount',
    );

    motionService.recordStrideCalibration(
      distanceMeters: edge.distanceMeters,
      steps: _segmentStepCount,
    );
  }

  // ---------------------------------------------------------------------------
  // VISUAL FOLLOW
  // ---------------------------------------------------------------------------

  void _advanceTowardTarget() {
    final target = _targetPosition;

    if (target == null) {
      return;
    }

    final current = liveUserPosition ?? target;

    final toTarget = target - current;

    final remaining = toTarget.distance;

    if (remaining < 0.001) {
      liveUserPosition = target;

      _updateStallStatus();

      return;
    }

    final moveBy = remaining * _visualBlendPerTick;

    liveUserPosition = current + toTarget / remaining * moveBy;

    _updateStallStatus();

    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // SEGMENT LENGTH
  // ---------------------------------------------------------------------------

  double _segmentLengthMeters(
    Beacon start,
    Offset endPosition,
  ) {
    final endBeacon = _pathBeaconAfter(
      start.id,
    );

    if (endBeacon != null) {
      final edge = storeMap.edgeBetween(
        start.id,
        endBeacon.id,
      );

      if (edge != null) {
        return edge.distanceMeters;
      }

      return (endBeacon.position - start.position).distance *
          storeMap.metersPerUnit;
    }

    final direct =
        (endPosition - start.position).distance * storeMap.metersPerUnit;

    return direct > 0 ? direct : 0.0;
  }

  // ---------------------------------------------------------------------------
  // CURRENT EDGE POLYLINE
  // ---------------------------------------------------------------------------

  List<Offset> _currentEdgePolyline(
    Beacon start,
    Offset endPosition,
  ) {
    final endBeacon = _pathBeaconAfter(
      start.id,
    );

    final edge = endBeacon == null
        ? null
        : storeMap.edgeBetween(
            start.id,
            endBeacon.id,
          );

    final waypoints = edge == null
        ? const <Offset>[]
        : edge.from == start.id
            ? edge.waypoints
            : edge.waypoints.reversed.toList();

    return [
      start.position,
      ...waypoints,
      endPosition,
    ];
  }

  // ---------------------------------------------------------------------------
  // POINT ALONG EDGE
  // ---------------------------------------------------------------------------

  Offset _pointAlongCurrentEdge(
    Beacon start,
    Offset endPosition,
    double fraction,
  ) {
    final points = _currentEdgePolyline(
      start,
      endPosition,
    );

    if (points.length < 2) {
      return endPosition;
    }

    final lengths = <double>[0.0];

    for (var i = 1; i < points.length; i++) {
      lengths.add(
        lengths.last + (points[i] - points[i - 1]).distance,
      );
    }

    final total = lengths.last;

    if (total <= 0) {
      return points.first;
    }

    final target = total * fraction;

    for (var i = 1; i < lengths.length; i++) {
      if (target <= lengths[i]) {
        final span = lengths[i] - lengths[i - 1];

        final local = span <= 0 ? 0.0 : (target - lengths[i - 1]) / span;

        return Offset.lerp(
          points[i - 1],
          points[i],
          local,
        )!;
      }
    }

    return points.last;
  }

  // ---------------------------------------------------------------------------
  // STALL STATUS
  // ---------------------------------------------------------------------------

  void _updateStallStatus() {
    final start = currentBeacon;

    final next = start == null ? null : _nextRouteWaypoint();

    if (start == null ||
        next == null ||
        _segmentProgressMeters <
            _segmentLengthMeters(
                  start,
                  next,
                ) -
                0.05) {
      _segmentBoundarySince = null;

      return;
    }

    final now = DateTime.now();

    _segmentBoundarySince ??= now;

    if (now.difference(
              _segmentBoundarySince!,
            ) >=
            const Duration(seconds: 5) &&
        status != NavigationStatus.arrived) {
      status = NavigationStatus.checkingLocation;
    }
  }

  // ---------------------------------------------------------------------------
  // NEXT ROUTE BEACON
  // ---------------------------------------------------------------------------

  Beacon? _pathBeaconAfter(
    String beaconId,
  ) {
    if (currentPath.length < 2) {
      return null;
    }

    final index = currentPath.indexWhere(
      (beacon) => beacon.id == beaconId,
    );

    if (index == -1 || index >= currentPath.length - 1) {
      return null;
    }

    return currentPath[index + 1];
  }

  // ---------------------------------------------------------------------------
  // RSSI LOOKUP
  // ---------------------------------------------------------------------------

  double? _rssiForBeacon(
    Beacon? beacon,
    Map<String, double> rssiByBleId,
  ) {
    if (beacon == null) {
      return null;
    }

    for (final entry in rssiByBleId.entries) {
      if (beacon.matchesBleId(
        entry.key,
      )) {
        return entry.value;
      }
    }

    return null;
  }

  // ---------------------------------------------------------------------------
  // ALREADY PASSED
  // ---------------------------------------------------------------------------

  bool _isAlreadyPassed(
    Beacon beacon,
    List<Beacon> path,
    Offset livePos,
  ) {
    if (path.length < 2) {
      return false;
    }

    final beaconIndex = path.indexWhere(
      (b) => b.id == beacon.id,
    );

    if (beaconIndex == -1) {
      return false;
    }

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

  // ---------------------------------------------------------------------------
  // CLEAR PENDING CANDIDATE
  // ---------------------------------------------------------------------------

  void _clearPendingBeaconCandidate() {
    _pendingBeaconId = null;

    _pendingBeaconCount = 0;

    _pendingBeaconSince = null;
  }

  // ---------------------------------------------------------------------------
  // NEXT WAYPOINT
  // ---------------------------------------------------------------------------

  Offset? _nextRouteWaypoint() {
    final path = currentPath;

    if (path.length < 2) {
      // Arrived.
      //
      // Continue aiming at the destination rather than falling back
      // to compass-based movement.
      return path.length == 1 ? path.first.position : null;
    }

    final cb = currentBeacon;

    if (cb != null) {
      final index = path.indexWhere(
        (b) => b.id == cb.id,
      );

      if (index != -1 && index < path.length - 1) {
        return path[index + 1].position;
      }
    }

    // Reroute fallback.
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

  // ---------------------------------------------------------------------------
  // PATHFINDING
  // ---------------------------------------------------------------------------

  void _recomputePath() {
    final start = currentBeacon;

    final end = destinationBeacon;

    if (end == null) {
      _log(
        'NAV: _recomputePath skipped — '
        'no destination',
      );

      return;
    }

    if (start == null) {
      _log(
        'NAV: _recomputePath skipped — '
        'no beacon fix yet '
        '(path stays: '
        '${currentPath.length} nodes)',
      );

      return;
    }

    final result = _pathfinder.findPath(
      storeMap,
      start.id,
      end.id,
    );

    if (result.path.isEmpty) {
      status = NavigationStatus.checkingLocation;

      _log(
        'NAV: _recomputePath — '
        'no path from ${start.name} '
        'to ${end.name}; '
        'keeping existing route '
        '(${currentPath.length} nodes)',
      );

      return;
    }

    final prev = currentPath
        .map(
          (b) => b.name,
        )
        .join(' → ');

    currentPath = result.path;

    currentDistanceMeters = result.distanceMeters;

    status = start.id == end.id
        ? NavigationStatus.arrived
        : NavigationStatus.navigating;

    final next = currentPath
        .map(
          (b) => b.name,
        )
        .join(' → ');

    if (prev != next) {
      _log(
        'NAV## path changed: '
        '$prev → $next '
        '(${currentDistanceMeters?.toStringAsFixed(0)} m)',
      );
    } else {
      _log(
        'NAV: path → '
        '$next '
        '(${currentDistanceMeters?.toStringAsFixed(0)} m) '
        '[unchanged]',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // LOGGING
  // ---------------------------------------------------------------------------

  void _log(
    String message,
  ) {
    debugPrint(
      '[NAV] $message',
    );

    logger?.log(
      message,
    );
  }

  // ---------------------------------------------------------------------------
  // DISPOSE
  // ---------------------------------------------------------------------------

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
