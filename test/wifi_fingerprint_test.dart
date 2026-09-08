import 'package:flutter_test/flutter_test.dart';
import 'package:indoor_nav/models/wifi_fingerprint.dart';
import 'package:indoor_nav/services/wifi_fingerprint_service.dart';

void main() {
  test('weighted KNN estimates from the closest WiFi fingerprints', () {
    final service = WifiFingerprintService();
    final date = DateTime(2026, 1, 1);
    service.addFingerprint(
      floorId: 'floor',
      position: const Offset(10, 10),
      samples: [WifiObservation(timestamp: date, rssiByBssid: {'ap-a': -40, 'ap-b': -70})],
    );
    service.addFingerprint(
      floorId: 'floor',
      position: const Offset(100, 100),
      samples: [WifiObservation(timestamp: date, rssiByBssid: {'ap-a': -80, 'ap-b': -45})],
    );

    final match = service.match({'ap-a': -42, 'ap-b': -68}, k: 2, weighted: true);

    expect(match, isNotNull);
    expect(match!.position.dx, lessThan(30));
    expect(match.neighborCount, 2);

    final basicMatch = service.match({'ap-a': -42, 'ap-b': -68}, k: 2, weighted: false);
    expect(basicMatch, isNotNull);
    expect(basicMatch!.neighborCount, 2);
  });
}