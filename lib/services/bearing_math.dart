/// Pure bearing/heading math shared by [NavigationController]'s movement
/// tracking and arrow rotation — pulled out on its own specifically so it's
/// unit-testable without needing live BLE/PDR hardware, which the rest of
/// that system otherwise depends on end to end.
///
/// All bearings use the same convention as compass headings: degrees,
/// 0 = North, increasing clockwise. `mapNorthOffsetDegrees` is the compass
/// bearing that corresponds to the map's "up" (-y) direction (see
/// StoreMap), so map-space vectors and compass bearings can be converted
/// between each other.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Normalizes [degrees] into `[0, 360)`.
double wrapDegrees(double degrees) => (degrees % 360 + 360) % 360;

/// The absolute angular gap between two bearings, correctly handling the
/// 0°/360° wraparound (e.g. 350° vs. 10° is 20° apart, not 340°). Always in
/// `[0, 180]`.
double angularDifferenceDegrees(double a, double b) {
  final diff = (a - b).abs() % 360;
  return diff > 180 ? 360 - diff : diff;
}

/// The compass-style bearing a map-space vector [delta] points along.
double bearingFromDelta(Offset delta, double mapNorthOffsetDegrees) {
  final theta = math.atan2(delta.dx, -delta.dy);
  return wrapDegrees(theta * 180 / math.pi + mapNorthOffsetDegrees);
}

/// The inverse of [bearingFromDelta]: a map-space vector of length
/// [distance] pointing along compass bearing [bearingDegrees].
Offset offsetFromBearing(double bearingDegrees, double mapNorthOffsetDegrees, double distance) {
  final theta = (bearingDegrees - mapNorthOffsetDegrees) * math.pi / 180;
  return Offset(distance * math.sin(theta), -distance * math.cos(theta));
}

/// How many degrees to rotate, via the shortest path, to go from bearing
/// [from] to bearing [to] — positive means clockwise, negative
/// counter-clockwise, always in `(-180, 180]`. Unlike
/// [angularDifferenceDegrees] (which only gives the unsigned gap), this is
/// what a rotation *animation* needs: which way to turn, not just how far
/// apart the two bearings are.
double signedAngularDifferenceDegrees(double from, double to) {
  final diff = (to - from) % 360;
  return diff > 180 ? diff - 360 : diff;
}

/// True if [trendBearing] points more than [thresholdDegrees] away from
/// [targetBearing] — i.e. clearly the opposite general direction, not just
/// noisy/imprecise agreement.
bool isOppositeDirection(
  double trendBearing,
  double targetBearing, {
  double thresholdDegrees = 110,
}) {
  return angularDifferenceDegrees(trendBearing, targetBearing) > thresholdDegrees;
}
