import 'dart:typed_data';

import 'package:indoor_nav_engine/indoor_nav_engine.dart';
import 'package:test/test.dart';

void main() {
  final iBeaconPayload = <int>[
    0x02,
    0x15,
    ...List<int>.generate(16, (index) => index + 1),
    0x00,
    0x07,
    0x00,
    0x09,
    0xC5,
    0x00,
  ];

  test('parses iBeacon data with Apple company identifier', () {
    final beacon = parseIBeacon(
      Uint8List.fromList([0x4C, 0x00, ...iBeaconPayload]),
    );

    expect(beacon?.major, 7);
    expect(beacon?.minor, 9);
  });

  test('parses iBeacon payload when company identifier is omitted', () {
    final beacon = parseIBeacon(Uint8List.fromList(iBeaconPayload));

    expect(beacon?.major, 7);
    expect(beacon?.minor, 9);
  });
}
