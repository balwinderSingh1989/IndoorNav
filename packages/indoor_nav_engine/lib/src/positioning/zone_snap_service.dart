import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../models/beacon.dart';
import '../models/store_map.dart';

class _BeaconSample {
  final Offset position;
  final double distanceUnits;
  final double rssi;
  const _BeaconSample({required this.position, required this.distanceUnits, required this.rssi});
}

/// Turns a set of averaged RSSI readings into a location via
/// **trilateration**: each beacon's RSSI is converted to an estimated
/// distance (log-distance path-loss model), then [estimatePosition] solves
/// for the point consistent with *all* of those distances at once —
/// rather than a proximity-weighted average of beacon positions, which
/// doesn't reason about absolute distance and can drift toward a beacon
/// just because it's relatively strong, not because it's actually close.
/// This both gives a continuous position (shifts smoothly as distances
/// change, instead of jumping beacon-to-beacon) and keeps it grounded in
/// real geometry (a farther beacon transiently reading strong pulls the
/// solve toward it far less than it would a bare signal-weighted average).
class ZoneSnapService {
  /// Beacons weaker than this are excluded entirely — too far/unreliable
  /// to trust even as a minor contributor to the estimate.
  static const double _minRssiFloor = -85.0;

  /// Log-distance path-loss model calibration: [_txPowerAt1m] is the
  /// expected RSSI (dBm) at 1 meter, [_pathLossExponent] how fast signal
  /// decays with distance (~2 in free space, higher indoors with walls).
  /// Not per-beacon calibrated — treat resulting distances as approximate.
  static const double _txPowerAt1m = -59.0;
  static const double _pathLossExponent = 2.5;

  double _estimateDistanceMeters(double rssi) =>
      math.pow(10, (_txPowerAt1m - rssi) / (10 * _pathLossExponent)).toDouble();

  /// Best-guess position (map units) from every currently-visible beacon,
  /// or null if none are above [_minRssiFloor]. Solves proper
  /// multilateration (weighted least squares) when >=3 beacons give
  /// distance constraints — enough to fix a 2D point; falls back to a
  /// distance-weighted centroid otherwise (1-2 beacons underdetermine a 2D
  /// position from distances alone), or when the beacons in range are too
  /// close to collinear for multilateration to solve reliably (common
  /// here — beacons are mounted along corridors, not spread in a grid).
  ///
  /// Deliberately does *not* special-case "one beacon is much stronger
  /// than the rest" by snapping straight to that beacon's fixed node
  /// coordinate. That shortcut used to live here, and caused two visible
  /// problems: the tracked position froze solid (ignoring any further
  /// small movement) for as long as one beacon stayed dominant — most of
  /// the time, given how closely beacons are spaced — and because RSSI
  /// noise can flip which of two close beacons is "dominant" from one
  /// reading to the next, the position (and anything derived from its
  /// movement, like the arrow's heading — see
  /// [NavigationController._updateMovementTrend]) could jump between two
  /// entirely different fixed points, which is exactly what shows up on
  /// screen as the arrow wobbling in the wrong direction. It's unnecessary
  /// for accuracy too: both [_multilaterate] and [_weightedCentroid]
  /// already weight by inverse squared distance, so a genuinely
  /// close/dominant beacon already pulls the solve almost all the way to
  /// itself on its own — just continuously, instead of as a hard binary
  /// switch.
  Offset? estimatePosition(Map<String, double> rssiByBleId, StoreMap storeMap) {
    final samples = <_BeaconSample>[];
    for (final entry in rssiByBleId.entries) {
      if (entry.value < _minRssiFloor) continue;
      final beacon = storeMap.beaconByBleId(entry.key);
      if (beacon == null) continue;
      final distanceMeters = _estimateDistanceMeters(entry.value);
      samples.add(_BeaconSample(
        position: beacon.position,
        distanceUnits: distanceMeters / storeMap.metersPerUnit,
        rssi: entry.value,
      ));
    }

    if (samples.isEmpty) return null;
    // Only one signal at all — nothing to blend with, so it IS the best
    // available estimate.
    if (samples.length == 1) return samples.first.position;

    if (samples.length >= 3) {
      final solved = _multilaterate(samples);
      if (solved != null && _isPlausible(solved, storeMap)) return solved;
    }
    return _weightedCentroid(samples);
  }

  /// Weighted least-squares multilateration: linearizes the usual
  /// trilateration circle equations `(x-x_i)^2 + (y-y_i)^2 = d_i^2` by
  /// subtracting a reference sample's equation from every other one,
  /// eliminating the quadratic terms and leaving a linear system in
  /// (x, y) — solved here in closed form (just 2 unknowns) rather than
  /// pulling in a matrix library. Returns null if the beacons in range are
  /// too close to collinear to solve (near-singular system) — expected
  /// with corridor-mounted beacons — leaving the caller to fall back.
  Offset? _multilaterate(List<_BeaconSample> samples) {
    final reference = samples.reduce((a, b) => a.distanceUnits <= b.distanceUnits ? a : b);

    var sXX = 0.0, sXY = 0.0, sYY = 0.0, sXB = 0.0, sYB = 0.0;
    for (final sample in samples) {
      if (identical(sample, reference)) continue;
      final a = 2 * (reference.position.dx - sample.position.dx);
      final b = 2 * (reference.position.dy - sample.position.dy);
      final c = (sample.distanceUnits * sample.distanceUnits - reference.distanceUnits * reference.distanceUnits) -
          (sample.position.dx * sample.position.dx - reference.position.dx * reference.position.dx) -
          (sample.position.dy * sample.position.dy - reference.position.dy * reference.position.dy);

      // Closer (shorter-distance) samples are more trustworthy — the
      // path-loss model's relative error grows with estimated distance.
      final weight = 1 / (sample.distanceUnits * sample.distanceUnits + 1);
      sXX += weight * a * a;
      sXY += weight * a * b;
      sYY += weight * b * b;
      sXB += weight * a * c;
      sYB += weight * b * c;
    }

    final determinant = sXX * sYY - sXY * sXY;
    if (determinant.abs() < 1e-6) return null; // Near-collinear beacons — unsolvable.

    final x = (sXB * sYY - sYB * sXY) / determinant;
    final y = (sXX * sYB - sXY * sXB) / determinant;
    return Offset(x, y);
  }

  /// A solved point is only trusted if it's within a generous margin of
  /// the map's bounds — weak beacon geometry (few points, close to
  /// collinear) can otherwise make the linear solve shoot arbitrarily far
  /// off, which [_multilaterate]'s determinant check alone doesn't always
  /// catch.
  bool _isPlausible(Offset point, StoreMap storeMap) {
    final marginX = storeMap.mapWidth * 0.5;
    final marginY = storeMap.mapHeight * 0.5;
    return point.dx >= -marginX &&
        point.dx <= storeMap.mapWidth + marginX &&
        point.dy >= -marginY &&
        point.dy <= storeMap.mapHeight + marginY;
  }

  /// Distance-weighted centroid — the fallback when there aren't enough
  /// (non-collinear) beacons in range to multilaterate. Closer beacons
  /// pull harder, same weighting rationale as [_multilaterate].
  Offset _weightedCentroid(List<_BeaconSample> samples) {
    var weightSum = 0.0;
    var x = 0.0;
    var y = 0.0;
    for (final sample in samples) {
      final weight = 1 / (sample.distanceUnits * sample.distanceUnits + 1);
      weightSum += weight;
      x += sample.position.dx * weight;
      y += sample.position.dy * weight;
    }
    return Offset(x / weightSum, y / weightSum);
  }

  /// The known beacon nearest [estimatePosition]'s result — used for the
  /// "You are near" label and as the pathfinding start node, both of which
  /// need a discrete beacon rather than a continuous point.
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
