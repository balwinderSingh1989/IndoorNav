import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../models/beacon.dart';
import '../models/store_map.dart';

/// How [ZoneSnapService.estimatePositionDetailed] arrived at its answer —
/// lets callers decide how much to trust a given point (e.g. weight a
/// [solved] fix more than a [centroidFallback]).
enum PositionMethod {
  /// Only one usable beacon: its own coordinates.
  singleBeacon,

  /// 2 usable beacons: a range can't fix a 2D point, so a distance-weighted
  /// centroid is the honest best estimate.
  weightedCentroid,

  /// 3+ beacons, solved by damped nonlinear least squares and accepted.
  solved,

  /// 3+ beacons, but the solve was rejected (inconsistent ranges or an
  /// implausible point) so the weighted centroid is used instead.
  centroidFallback,
}

class PositionEstimate {
  const PositionEstimate({
    required this.position,
    required this.method,
    required this.contributors,
    this.residualRmsMeters,
  });

  /// Position in map units.
  final Offset position;
  final PositionMethod method;

  /// Number of beacons that fed the estimate.
  final int contributors;

  /// Weighted RMS disagreement between the solved point and the beacon
  /// ranges, in meters (null when no solve was attempted). Large values
  /// mean the RSSI-derived distances contradict each other — typical of
  /// multipath or a blocked beacon.
  final double? residualRmsMeters;
}

/// One beacon's range constraint, expressed in METERS (not map units), so
/// weights and thresholds are independent of the map's scale.
class _Range {
  _Range({
    required this.x,
    required this.y,
    required this.rssi,
    required this.distance,
  }) : weight = 1.0 / (distance * distance);

  final double x;
  final double y;
  final double rssi;
  final double distance;

  /// 1/d². Log-normal shadowing makes range error proportional to distance
  /// (≈35-40% of d at 4 dB shadowing, n=2.5), so the statistically correct
  /// weight is the inverse of the variance, ∝ 1/d².
  final double weight;
}

/// Turns a set of averaged RSSI readings into a position via
/// **trilateration**: each beacon's RSSI becomes an estimated distance
/// (log-distance path-loss model) and [estimatePosition] finds the point
/// that best agrees with all of those distances at once.
///
/// What changed from the previous version, and why (validated in a
/// simulation on this store's real beacon layout — see below):
///
/// 1. **Solve the true range equations, not the linearized ones.**
///    The old closed-form solve subtracted a reference beacon's circle
///    equation from every other one. That makes every equation inherit the
///    reference beacon's range error and — because corridor beacons are
///    nearly collinear — leaves the across-corridor direction almost
///    unconstrained, so noise got amplified there. We now minimize
///    Σ wᵢ(‖x−pᵢ‖ − dᵢ)² directly with Levenberg–Marquardt-damped
///    Gauss–Newton, started from the weighted centroid. Biggest single win:
///    mean error on the SOC–Interim–Gemma corridor ≈2.4 m → ≈1.0 m.
///
/// 2. **Damping instead of a "is the determinant exactly ~0" check.**
///    The old guard (`|det| < 1e-6`) only trips for perfectly collinear
///    beacons; nearly-collinear ones passed it and produced wild
///    across-corridor positions. The damping term leaves poorly
///    constrained directions where they started (on the corridor line, via
///    the centroid) rather than letting noise push them. Tuning it from
///    0.01 → 0.1 took the corridor mean error from ≈0.9 m to ≈0.5 m and
///    cut the worst case by ~3x.
///
/// 3. **Weights 1/d² in meters** (was 1/(d²+1) in map units). Uniform
///    weights were ~3.5x worse than 1/d² on the corridor; the old form was
///    close but unit-dependent (its "+1" meant different things at
///    metersPerUnit 0.104 vs 0.018).
///
/// 4. **Safety nets, deliberately loose.** Distances are clamped to
///    [minDistanceMeters, maxDistanceMeters] (1/d² weights would otherwise
///    blow up as d→0), at most [maxBeacons] strongest beacons are used, a
///    solve is rejected if its range residual exceeds
///    [maxResidualRmsMeters] or it lands outside the map by more than
///    [boundsMargin] (was 50% of the map). Simulation showed these don't
///    improve typical accuracy — they only guard against pathological
///    inputs — and that a tight residual gate (2 m) HURTS by falling back
///    too often, so don't tighten it without data.
///
/// 5. **Calibration is now injectable.** [txPowerAt1m] and
///    [pathLossExponent] are constructor parameters. Mis-modelling the
///    exponent (true 2.0 vs assumed 2.5) cost the old solver ~4.5 m mean
///    error versus ~0.7 m here, but calibrating them for your store (walk
///    to 1 m and 3 m from a few beacons with the test phone) is still the
///    best remaining lever.
///
/// Honest limits: the simulation uses a synthetic RSSI model on the real
/// layout, not measured data, so absolute numbers will be worse in the
/// store. On open floor (not corridor) accuracy is a few meters — that's
/// the physical limit of RSSI at this beacon density, not a solver
/// problem. Use [PositionEstimate.residualRmsMeters] during a walk test to
/// see how consistent real readings are.
class ZoneSnapService {
  ZoneSnapService({
    this.minRssiFloor = -85.0,
    this.txPowerAt1m = -59.0,
    this.pathLossExponent = 2.5,
    this.maxBeacons = 5,
    this.minDistanceMeters = 0.5,
    this.maxDistanceMeters = 12.0,
    this.solverDamping = 0.1,
    this.maxResidualRmsMeters = 5.0,
    this.boundsMargin = 0.10,
  });

  /// Beacons weaker than this are excluded entirely — too far/unreliable
  /// to trust even as a minor contributor.
  final double minRssiFloor;

  /// Log-distance path-loss model: expected RSSI (dBm) at 1 meter, and how
  /// fast signal decays with distance (~2 free space, higher indoors).
  final double txPowerAt1m;
  final double pathLossExponent;

  /// Use at most this many of the strongest beacons. Far beacons carry the
  /// largest range error (∝ d) and sit near the sensitivity floor where
  /// packet loss distorts RSSI; capping bounds that noise and the work done
  /// per RSSI tick. (No measurable gain in simulation — a precaution.)
  final int maxBeacons;

  final double minDistanceMeters;
  final double maxDistanceMeters;

  /// Levenberg–Marquardt damping as a fraction of the normal matrix's
  /// trace. Higher = poorly-constrained directions stay closer to the
  /// weighted centroid.
  final double solverDamping;

  /// A solve whose weighted range residual exceeds this is rejected in
  /// favour of the weighted centroid.
  final double maxResidualRmsMeters;

  /// Fraction of the map's width/height a solved point may lie outside the
  /// map before being rejected.
  final double boundsMargin;

  static const int _maxIterations = 12;

  /// Stop once an iteration moves the estimate less than 1 mm (squared).
  static const double _convergenceMetersSquared = 1e-6;

  double _estimateDistanceMeters(double rssi) {
    final d = math.pow(10, (txPowerAt1m - rssi) / (10 * pathLossExponent)).toDouble();
    return d.clamp(minDistanceMeters, maxDistanceMeters);
  }

  /// Best-guess position (map units), or null if no beacon is usable.
  /// Thin wrapper over [estimatePositionDetailed] for existing callers.
  Offset? estimatePosition(Map<String, double> rssiByBleId, StoreMap storeMap) =>
      estimatePositionDetailed(rssiByBleId, storeMap)?.position;

  /// Like [estimatePosition] but also reports how the answer was produced
  /// and how self-consistent the beacon ranges were.
  ///
  /// Deliberately does *not* snap to the strongest beacon's fixed node when
  /// one dominates: that froze the position while one beacon stayed
  /// dominant and made it jump between two fixed points whenever RSSI noise
  /// flipped which of two close beacons was "strongest". The inverse-square
  /// weights already pull the estimate almost fully onto a genuinely close
  /// beacon — continuously, instead of as a hard switch.
  PositionEstimate? estimatePositionDetailed(
      Map<String, double> rssiByBleId,
      StoreMap storeMap,
      ) {
    final mpu = storeMap.metersPerUnit;
    // Ranges are converted to map spaceestimatePositionDetailed through metersPerUnit; without a
    // valid scale there is nothing meaningful to return.
    if (!(mpu > 0) || !mpu.isFinite) return null;

    final ranges = <_Range>[];
    for (final entry in rssiByBleId.entries) {
      if (entry.value < minRssiFloor) continue;
      final beacon = storeMap.beaconByBleId(entry.key);
      if (beacon == null) continue;
      ranges.add(_Range(
        x: beacon.position.dx * mpu,
        y: beacon.position.dy * mpu,
        rssi: entry.value,
        distance: _estimateDistanceMeters(entry.value),
      ));
    }
    if (ranges.isEmpty) return null;

    ranges.sort((a, b) => b.rssi.compareTo(a.rssi));
    if (ranges.length > maxBeacons) {
      ranges.removeRange(maxBeacons, ranges.length);
    }

    Offset toMap(Offset meters) => Offset(meters.dx / mpu, meters.dy / mpu);

    if (ranges.length == 1) {
      return PositionEstimate(
        position: toMap(Offset(ranges.first.x, ranges.first.y)),
        method: PositionMethod.singleBeacon,
        contributors: 1,
      );
    }

    final centroid = _weightedCentroid(ranges);

    // Two ranges intersect in two points; without a third there is no way
    // to choose, so don't pretend to solve.
    if (ranges.length < 3) {
      return PositionEstimate(
        position: toMap(centroid),
        method: PositionMethod.weightedCentroid,
        contributors: ranges.length,
      );
    }

    final solved = _solve(ranges, centroid);
    if (solved != null) {
      final residualRms = _weightedResidualRms(ranges, solved);
      final solvedMap = toMap(solved);
      if (residualRms <= maxResidualRmsMeters && _withinMap(solvedMap, storeMap)) {
        return PositionEstimate(
          position: solvedMap,
          method: PositionMethod.solved,
          contributors: ranges.length,
          residualRmsMeters: residualRms,
        );
      }
      return PositionEstimate(
        position: toMap(centroid),
        method: PositionMethod.centroidFallback,
        contributors: ranges.length,
        residualRmsMeters: residualRms,
      );
    }

    return PositionEstimate(
      position: toMap(centroid),
      method: PositionMethod.centroidFallback,
      contributors: ranges.length,
    );
  }

  /// Weighted centroid (meters). Starting point for the solver and the
  /// fallback when a solve can't be trusted.
  Offset _weightedCentroid(List<_Range> ranges) {
    var weightSum = 0.0;
    var x = 0.0;
    var y = 0.0;
    for (final r in ranges) {
      weightSum += r.weight;
      x += r.x * r.weight;
      y += r.y * r.weight;
    }
    return Offset(x / weightSum, y / weightSum);
  }

  /// Minimizes Σ wᵢ(‖x−pᵢ‖ − dᵢ)² with damped Gauss–Newton
  /// (Levenberg–Marquardt-style), starting from [start]. Returns null if
  /// the iteration produces a non-finite point.
  ///
  /// With nearly-collinear beacons the normal matrix is almost singular in
  /// the across-line direction; the damping term keeps that direction near
  /// its starting value instead of letting range noise fling the estimate
  /// sideways.
  Offset? _solve(List<_Range> ranges, Offset start) {
    var x = start.dx;
    var y = start.dy;

    for (var iteration = 0; iteration < _maxIterations; iteration++) {
      var hxx = 0.0, hxy = 0.0, hyy = 0.0, gx = 0.0, gy = 0.0;
      for (final r in ranges) {
        final dx = x - r.x;
        final dy = y - r.y;
        final dist = math.max(math.sqrt(dx * dx + dy * dy), 1e-6);
        final residual = dist - r.distance;
        final jx = dx / dist;
        final jy = dy / dist;
        hxx += r.weight * jx * jx;
        hxy += r.weight * jx * jy;
        hyy += r.weight * jy * jy;
        gx += r.weight * jx * residual;
        gy += r.weight * jy * residual;
      }

      final damping = solverDamping * (hxx + hyy) + 1e-9;
      hxx += damping;
      hyy += damping;

      final det = hxx * hyy - hxy * hxy;
      if (det.abs() < 1e-12) break;

      // Solve H·step = −g for the 2x2 system in closed form.
      final stepX = -(hyy * gx - hxy * gy) / det;
      final stepY = -(hxx * gy - hxy * gx) / det;
      x += stepX;
      y += stepY;

      if (stepX * stepX + stepY * stepY < _convergenceMetersSquared) break;
    }

    if (!x.isFinite || !y.isFinite) return null;
    return Offset(x, y);
  }

  /// Weighted RMS of (distance-to-beacon − estimated range), in meters.
  double _weightedResidualRms(List<_Range> ranges, Offset point) {
    var weightSum = 0.0;
    var sumSquares = 0.0;
    for (final r in ranges) {
      final dx = point.dx - r.x;
      final dy = point.dy - r.y;
      final residual = math.sqrt(dx * dx + dy * dy) - r.distance;
      weightSum += r.weight;
      sumSquares += r.weight * residual * residual;
    }
    return math.sqrt(sumSquares / weightSum);
  }

  /// A solved point is only trusted if it lies within [boundsMargin] of the
  /// map's extent (was a 50% margin, which let wild solves through).
  bool _withinMap(Offset pointMapUnits, StoreMap storeMap) {
    final marginX = storeMap.mapWidth * boundsMargin;
    final marginY = storeMap.mapHeight * boundsMargin;
    return pointMapUnits.dx >= -marginX &&
        pointMapUnits.dx <= storeMap.mapWidth + marginX &&
        pointMapUnits.dy >= -marginY &&
        pointMapUnits.dy <= storeMap.mapHeight + marginY;
  }

  /// The known beacon nearest [estimatePosition]'s result.
  ///
  /// Use this for display labels ("You are near ...") ONLY. It must never
  /// feed route start / [NavigationController.currentBeacon] — beacon
  /// confirmation goes through the debounce, reachability and hop-validity
  /// gates, and bypassing them reintroduces the teleporting this app
  /// already fixed.
  Beacon? nearestBeacon(Map<String, double> rssiByBleId, StoreMap storeMap) {
    final estimate = estimatePosition(rssiByBleId, storeMap);
    if (estimate == null) return null;

    Beacon? nearest;
    var bestDistanceSquared = double.infinity;
    for (final beacon in storeMap.beacons) {
      final d = (beacon.position - estimate).distanceSquared;
      if (d < bestDistanceSquared) {
        bestDistanceSquared = d;
        nearest = beacon;
      }
    }
    return nearest;
  }

  /// Returns the beacon with the highest RSSI among the currently-visible
  /// store beacons, or null if none match.
  Beacon? strongestBeacon(Map<String, double> rssiByBleId, StoreMap storeMap) {
    Beacon? strongest;
    double? bestRssi;
    for (final entry in rssiByBleId.entries) {
      final beacon = storeMap.beaconByBleId(entry.key);
      if (beacon == null) continue;
      if (bestRssi == null || entry.value > bestRssi) {
        bestRssi = entry.value;
        strongest = beacon;
      }
    }
    return strongest;
  }
}