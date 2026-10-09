import 'dart:ui';

import 'package:indoor_nav_engine/indoor_nav_engine.dart';
import 'package:test/test.dart';

void main() {
  test('resolves future hardware identifiers without changing beacon identity',
      () {
    const beacon = Beacon(
      id: 'b1',
      bleId: 'legacy-ibeacon-id',
      name: 'Zone 1',
      position: Offset(10, 20),
      observationIds: ['eddystone-uid-namespace-instance'],
    );

    expect(beacon.matchesBleId('EDDYSTONE-UID-NAMESPACE-INSTANCE'), isTrue);
    expect(beacon.matchesBleId('unknown-frame-id'), isFalse);
  });
}
