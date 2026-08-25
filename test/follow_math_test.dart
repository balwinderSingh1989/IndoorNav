import 'package:flutter_test/flutter_test.dart';

import 'package:indoor_nav/services/follow_math.dart';

const _walkingSpeed = 1.3;
const _normalCatchUp = 1.0;
const _confidentCatchUp = 0.2;
const _maxSpeed = 6.0;

double _speed({required double remainingMeters, required bool confident}) {
  return followSpeedMetersPerSecond(
    remainingMeters: remainingMeters,
    confident: confident,
    walkingSpeedMetersPerSecond: _walkingSpeed,
    normalCatchUpSeconds: _normalCatchUp,
    confidentCatchUpSeconds: _confidentCatchUp,
    maxSpeedMetersPerSecond: _maxSpeed,
  );
}

void main() {
  group('followSpeedMetersPerSecond', () {
    test('small gaps move at the normal walking-pace floor, not faster', () {
      expect(_speed(remainingMeters: 0.3, confident: false), _walkingSpeed);
      expect(_speed(remainingMeters: 0.75, confident: false), _walkingSpeed);
    });

    test('large gaps scale up so they close within normalCatchUpSeconds, instead of perma-lagging', () {
      // This is "the app detects another zone and the arrow is still at
      // the previous one": at a fixed 1.3 m/s, a several-meter gap would
      // visibly trail behind for seconds. It should close within ~1s.
      final speed = _speed(remainingMeters: 5.0, confident: false);
      expect(speed, 5.0 / _normalCatchUp);
      expect(5.0 / speed, closeTo(_normalCatchUp, 1e-9));
    });

    test('confident fixes catch up much faster than unconfident ones for the same gap', () {
      const gap = 1.0;
      final unconfident = _speed(remainingMeters: gap, confident: false);
      final confident = _speed(remainingMeters: gap, confident: true);
      expect(confident, greaterThan(unconfident));
      expect(confident, gap / _confidentCatchUp);
    });

    test('a confident fix a meter from the last drawn position closes almost immediately', () {
      final speed = _speed(remainingMeters: 1.0, confident: true);
      final secondsToClose = 1.0 / speed;
      expect(secondsToClose, lessThanOrEqualTo(_confidentCatchUp));
    });

    test('never exceeds the max follow speed regardless of gap size or confidence', () {
      expect(_speed(remainingMeters: 1000, confident: true), _maxSpeed);
      expect(_speed(remainingMeters: 1000, confident: false), _maxSpeed);
    });

    test('a large confident gap is capped, not instant, but still far faster than uncapped normal pace', () {
      const gap = 5.0;
      final confidentSpeed = _speed(remainingMeters: gap, confident: true);
      final unconfidentSpeed = _speed(remainingMeters: gap, confident: false);
      expect(confidentSpeed, _maxSpeed);
      expect(confidentSpeed, greaterThan(unconfidentSpeed));
      expect(gap / confidentSpeed, greaterThan(_confidentCatchUp)); // capped, so not instant
      expect(gap / confidentSpeed, lessThan(gap / unconfidentSpeed)); // still much faster
    });

    test('zero remaining distance still returns at least walking pace (caller handles the "arrived" case)', () {
      expect(_speed(remainingMeters: 0, confident: false), _walkingSpeed);
    });
  });
}
