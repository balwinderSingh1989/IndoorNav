import 'dart:math' as math;

/// How fast [NavigationController.liveUserPosition] should glide toward
/// its target this tick — pulled out on its own specifically so it's
/// unit-testable without needing live BLE/PDR hardware.
///
/// Always at least [walkingSpeedMetersPerSecond] (so ordinary small
/// increments still read as natural walking), but scales up so a gap of
/// [remainingMeters] always closes within [catchUpSeconds] — which is
/// [confidentCatchUpSeconds] when [confident] (a beacon was just freshly
/// confirmed — a new zone was detected), [normalCatchUpSeconds] otherwise
/// — so the pin never perpetually trails behind a correction ("the app
/// detects another zone and the arrow is still at the previous one"), and
/// moves toward a freshly confirmed beacon almost immediately rather than
/// crawling there. Never exceeds [maxSpeedMetersPerSecond] regardless, so
/// an unusually large correction still animates rather than teleporting
/// outright.
double followSpeedMetersPerSecond({
  required double remainingMeters,
  required bool confident,
  required double walkingSpeedMetersPerSecond,
  required double normalCatchUpSeconds,
  required double confidentCatchUpSeconds,
  required double maxSpeedMetersPerSecond,
}) {
  final catchUpSeconds = confident ? confidentCatchUpSeconds : normalCatchUpSeconds;
  final desired = math.max(walkingSpeedMetersPerSecond, remainingMeters / catchUpSeconds);
  return math.min(desired, maxSpeedMetersPerSecond);
}
