import 'package:indoor_nav_engine/indoor_nav_engine.dart';
import 'package:test/test.dart';

void main() {
  const map = IndoorMap(
    beacons: [
      IndoorBeacon(id: 'soc', bleId: 'soc', name: 'SOC'),
      IndoorBeacon(id: 'interim', bleId: 'interim', name: 'Interim'),
      IndoorBeacon(id: 'safari', bleId: 'safari', name: 'Safari'),
    ],
    edges: [IndoorMapEdge(from: 'soc', to: 'interim', distanceMeters: 3.6)],
  );
  const policy = FreeRoamCandidatePolicy(map: map, config: IndoorNavConfig());

  test('requires the stricter configured margin for adjacent beacons', () {
    final candidate = policy.select(
      currentBeaconId: 'soc',
      rssiByBeaconId: {'soc': -75, 'interim': -68.4},
    );

    expect(candidate, isNull);
  });

  test('accepts an adjacent switch when its configured margin is met', () {
    final candidate = policy.select(
      currentBeaconId: 'soc',
      rssiByBeaconId: {'soc': -75, 'interim': -66},
    );

    expect(candidate?.beacon.id, 'interim');
    expect(candidate?.isAdjacentToCurrent, isTrue);
    expect(candidate?.requiredMarginDb, 8.0);
  });

  test('accepts a non-adjacent switch at the standard configured margin', () {
    final candidate = policy.select(
      currentBeaconId: 'soc',
      rssiByBeaconId: {'soc': -75, 'safari': -69},
    );

    expect(candidate?.beacon.id, 'safari');
    expect(candidate?.isAdjacentToCurrent, isFalse);
    expect(candidate?.requiredMarginDb, 6.0);
  });
}
