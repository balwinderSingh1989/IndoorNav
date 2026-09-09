import 'package:flutter_test/flutter_test.dart';

import 'package:indoor_nav/services/bearing_math.dart';

void main() {
  group('wrapDegrees', () {
    test('leaves in-range values unchanged', () {
      expect(wrapDegrees(90), 90);
      expect(wrapDegrees(0), 0);
    });

    test('wraps negative and >360 values into [0, 360)', () {
      expect(wrapDegrees(-10), 350);
      expect(wrapDegrees(370), 10);
      expect(wrapDegrees(-370), 350);
    });
  });

  group('angularDifferenceDegrees', () {
    test('simple in-range gap', () {
      expect(angularDifferenceDegrees(30, 10), 20);
    });

    test('handles the 0/360 wraparound as the short way around', () {
      // 350 and 10 are 20 apart going through 0, not 340 apart the long way.
      expect(angularDifferenceDegrees(350, 10), 20);
    });

    test('opposite bearings are 180 apart', () {
      expect(angularDifferenceDegrees(0, 180), 180);
      expect(angularDifferenceDegrees(90, 270), 180);
    });

    test('is symmetric', () {
      expect(angularDifferenceDegrees(40, 200), angularDifferenceDegrees(200, 40));
    });
  });

  group('signedAngularDifferenceDegrees — drives the arrow-rotation smoothing', () {
    test('a simple in-range turn keeps its sign and magnitude', () {
      expect(signedAngularDifferenceDegrees(10, 30), 20); // clockwise
      expect(signedAngularDifferenceDegrees(30, 10), -20); // counter-clockwise
    });

    test('takes the short way around the 0/360 wraparound', () {
      // 350 -> 10 is +20 (through 0), not -340 the long way around.
      expect(signedAngularDifferenceDegrees(350, 10), 20);
      // 10 -> 350 is -20, not +340.
      expect(signedAngularDifferenceDegrees(10, 350), -20);
    });

    test('a half turn is reported as +180 (a definite direction, not ambiguous)', () {
      expect(signedAngularDifferenceDegrees(0, 180), 180);
    });

    test('zero difference for identical bearings', () {
      expect(signedAngularDifferenceDegrees(45, 45), 0);
    });

    test('always in (-180, 180]', () {
      for (var from = 0.0; from < 360; from += 37) {
        for (var to = 0.0; to < 360; to += 53) {
          final diff = signedAngularDifferenceDegrees(from, to);
          expect(diff, greaterThan(-180));
          expect(diff, lessThanOrEqualTo(180));
        }
      }
    });

    test('applying the diff to "from" lands exactly on "to" (mod 360)', () {
      for (var from = 0.0; from < 360; from += 41) {
        for (var to = 0.0; to < 360; to += 67) {
          final diff = signedAngularDifferenceDegrees(from, to);
          expect(wrapDegrees(from + diff), closeTo(wrapDegrees(to), 1e-9), reason: 'from=$from to=$to');
        }
      }
    });
  });

  group('bearingFromDelta / offsetFromBearing round-trip', () {
    // mapNorthOffsetDegrees=0 means the map's "up" (-y) is due North.
    test('straight up the map is bearing 0 (North)', () {
      expect(bearingFromDelta(const Offset(0, -10), 0), closeTo(0, 1e-9));
    });

    test('straight right on the map is bearing 90 (East)', () {
      expect(bearingFromDelta(const Offset(10, 0), 0), closeTo(90, 1e-9));
    });

    test('straight down the map is bearing 180 (South)', () {
      expect(bearingFromDelta(const Offset(0, 10), 0), closeTo(180, 1e-9));
    });

    test('offsetFromBearing inverts bearingFromDelta', () {
      for (final bearing in [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0]) {
        final offset = offsetFromBearing(bearing, 0, 10);
        final recovered = bearingFromDelta(offset, 0);
        expect(recovered, closeTo(bearing, 1e-6), reason: 'bearing=$bearing');
      }
    });

    test('respects a non-zero mapNorthOffsetDegrees', () {
      // If the map's "up" is actually East (90) in the real world, walking
      // "up" the map is a compass bearing of 90, not 0.
      expect(bearingFromDelta(const Offset(0, -10), 90), closeTo(90, 1e-9));
    });
  });

  group('isOppositeDirection — the actual bug this exists to prevent', () {
    test('walking toward the next waypoint is never flagged as opposite', () {
      // User is heading bearing 0 (North); the waypoint is also North of them.
      expect(isOppositeDirection(0, 0), isFalse);
      // Some natural noise around that shouldn't false-positive either.
      expect(isOppositeDirection(20, 0), isFalse);
      expect(isOppositeDirection(340, 0), isFalse);
    });

    test('walking directly away from the next waypoint is flagged', () {
      // Waypoint is North (bearing 0); the sensed movement trend is South
      // (bearing 180) — this is exactly "the arrow moving in the opposite
      // direction of the user's actual movement" if left uncorrected.
      expect(isOppositeDirection(180, 0), isTrue);
    });

    test('a moderate diagonal deviation is not treated as reversal', () {
      // 90 degrees off (e.g. cutting across at an angle) is a deviation,
      // not a reversal — shouldn't flip the step direction backward.
      expect(isOppositeDirection(90, 0), isFalse);
    });

    test('threshold is configurable', () {
      expect(isOppositeDirection(150, 0, thresholdDegrees: 110), isTrue);
      expect(isOppositeDirection(150, 0, thresholdDegrees: 160), isFalse);
    });
  });

  group('segment-bounded motion helpers', () {
    test('offsetAlongSegment never travels past the segment end', () {
      const start = Offset(0, 0);
      const end = Offset(10, 0);

      expect(offsetAlongSegment(start, end, 100), const Offset(10, 0));
      expect(offsetAlongSegment(start, end, 3), const Offset(3, 0));
      expect(offsetAlongSegment(start, end, 0), const Offset(0, 0));
    });
  });
}
