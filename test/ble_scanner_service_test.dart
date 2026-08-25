import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:indoor_nav/services/ble_scanner_service.dart';

void main() {
  test('extracts the proximity UUID from iBeacon manufacturer data', () {
    final manufacturerData = Uint8List.fromList([
      0x4C, 0x00, // Apple company ID
      0x02, 0x15, // iBeacon type
      0x01, 0x02, 0x03, 0x04,
      0x05, 0x06, 0x07, 0x08,
      0x09, 0x0A, 0x0B, 0x0C,
      0x0D, 0x0E, 0x0F, 0x10,
      0x11, 0x12, 0x13, 0x14,
    ]);

    expect(
      parseBeaconIdentifier(
        manufacturerData: manufacturerData,
        serviceUuids: const [],
        serviceData: const {},
      ),
      '01020304-0506-0708-090a-0b0c0d0e0f10',
    );
  });

  test('extracts a 128-bit UUID from advertised service UUIDs', () {
    expect(
      parseBeaconIdentifier(
        manufacturerData: null,
        serviceUuids: const ['01020304-0506-0708-090a-0b0c0d0e0f10'],
        serviceData: const {},
      ),
      '01020304-0506-0708-090a-0b0c0d0e0f10',
    );
  });
}
