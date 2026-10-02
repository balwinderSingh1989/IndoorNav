import '../config/indoor_nav_config.dart';
import '../model/indoor_map.dart';

/// A normalized beacon observation supplied by a host scanner implementation.
class BeaconObservation {
  const BeaconObservation({required this.beaconId, required this.rssi});

  final String beaconId;
  final double rssi;
}

/// The result of a free-roam candidate evaluation.
class FreeRoamCandidate {
  const FreeRoamCandidate({
    required this.beacon,
    required this.rssi,
    required this.marginDb,
    required this.requiredMarginDb,
    required this.isAdjacentToCurrent,
  });

  final IndoorBeacon beacon;
  final double rssi;
  final double marginDb;
  final double requiredMarginDb;
  final bool isAdjacentToCurrent;
}

/// Selects a switch candidate using config-driven RSSI and graph constraints.
class FreeRoamCandidatePolicy {
  const FreeRoamCandidatePolicy({required this.map, required this.config});

  final IndoorMap map;
  final IndoorNavConfig config;

  /// Returns the strongest valid candidate, or null when current zone should remain.
  FreeRoamCandidate? select({
    required String? currentBeaconId,
    required Map<String, double> rssiByBeaconId,
  }) {
    final observations = rssiByBeaconId.entries
        .where((entry) => map.beaconById(entry.key) != null)
        .map((entry) => BeaconObservation(beaconId: entry.key, rssi: entry.value))
        .toList()
      ..sort((first, second) => second.rssi.compareTo(first.rssi));
    if (observations.isEmpty) return null;

    if (currentBeaconId == null) {
      final strongest = observations.first;
      final beacon = map.beaconById(strongest.beaconId)!;
      return FreeRoamCandidate(
        beacon: beacon,
        rssi: strongest.rssi,
        marginDb: double.infinity,
        requiredMarginDb: 0,
        isAdjacentToCurrent: false,
      );
    }

    final currentRssi = rssiByBeaconId[currentBeaconId];
    for (final observation in observations) {
      if (observation.beaconId == currentBeaconId) continue;
      if (currentRssi == null) {
        final beacon = map.beaconById(observation.beaconId)!;
        return FreeRoamCandidate(
          beacon: beacon,
          rssi: observation.rssi,
          marginDb: double.infinity,
          requiredMarginDb: 0,
          isAdjacentToCurrent: false,
        );
      }

      final adjacent = map.areAdjacent(currentBeaconId, observation.beaconId);
      final requiredMargin = adjacent
          ? config.adjacentSwitchMarginDb
          : config.standardSwitchMarginDb;
      final margin = observation.rssi - currentRssi;
      if (margin < requiredMargin) continue;

      return FreeRoamCandidate(
        beacon: map.beaconById(observation.beaconId)!,
        rssi: observation.rssi,
        marginDb: margin,
        requiredMarginDb: requiredMargin,
        isAdjacentToCurrent: adjacent,
      );
    }
    return null;
  }
}
