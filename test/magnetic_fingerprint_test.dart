import 'package:flutter_test/flutter_test.dart';
import 'package:indoor_nav/models/magnetic_fingerprint.dart';
import 'package:indoor_nav/services/magnetic_fingerprint_service.dart';

void main() {
  final testDate = DateTime(2026, 1, 1);

  test('calculates orientation-independent magnetic magnitude', () {
    final sample = MagneticSample(timestamp: testDate, x: 3, y: 4, z: 12);

    expect(sample.magnitude, 13);
  });

  test('matches the closest captured magnetic fingerprint', () {
    final service = MagneticFingerprintService();
    service.addFingerprint(
      floorId: 'floor',
      position: const Offset(10, 20),
      samples: [
        MagneticSample(timestamp: testDate, x: 20, y: 10, z: 5),
      ],
    );
    service.addFingerprint(
      floorId: 'floor',
      position: const Offset(80, 90),
      samples: [
        MagneticSample(timestamp: testDate, x: 60, y: 40, z: 30),
      ],
    );

    final match = service.match(MagneticSample(timestamp: testDate, x: 21, y: 9, z: 5));

    expect(match?.position, const Offset(10, 20));
  });

  test('DTW matches a walking sequence and returns its mapped position', () {
    final service = MagneticFingerprintService();
    final reference = List.generate(
      12,
      (index) => MagneticSample(timestamp: testDate, x: 0, y: 0, z: 20 + index * 2),
    );
    service.addTrajectory(
      floorId: 'floor',
      samples: reference,
      positions: List.generate(12, (index) => Offset(index * 10.0, 50)),
    );

    final match = service.matchSequence(reference);

    expect(match, isNotNull);
    expect(match!.position.dx, greaterThan(70));
  });
}