import 'package:flutter_test/flutter_test.dart';

import 'package:indoor_nav/models/beacon.dart';
import 'package:indoor_nav/models/store_map.dart';
import 'package:indoor_nav/services/zone_snap_service.dart';

StoreMap _twoBeaconMap() {
  return const StoreMap(
    mapAsset: 'assets/floorMap.svg',
    mapWidth: 100,
    mapHeight: 100,
    metersPerUnit: 1.0,
    mapNorthOffsetDegrees: 0,
    beacons: [
      Beacon(id: 'a', bleId: 'a', name: 'A', position: Offset(0, 0)),
      Beacon(id: 'b', bleId: 'b', name: 'B', position: Offset(10, 0)),
    ],
    edges: [],
    items: [],
  );
}

void main() {
  final service = ZoneSnapService();
  final storeMap = _twoBeaconMap();

  group('estimatePosition — small-movement / anti-wobble regression', () {
    test(
      'a small RSSI change on the dominant beacon actually moves the estimate '
      '(this used to be frozen: any strong-enough+dominant beacon snapped straight '
      'to its fixed node position, ignoring every further small change)',
      () {
        final before = service.estimatePosition({'a': -50.0, 'b': -80.0}, storeMap);
        // A's signal weakens slightly (user moved a little away from it) —
        // still just as dominant over B by the old 6dB-gap rule.
        final after = service.estimatePosition({'a': -54.0, 'b': -80.0}, storeMap);

        expect(before, isNotNull);
        expect(after, isNotNull);
        expect(
          after,
          isNot(equals(before)),
          reason: 'estimatePosition did not react to a real RSSI change on the dominant beacon',
        );
      },
    );

    test(
      'the estimate does not flip between two fixed points on noise alone '
      '(the source of the arrow "wobbling": a hard snap meant a single noisy '
      'reading that flipped which beacon was "dominant" jumped the whole estimate)',
      () {
        // A slightly stronger than B: old code snaps to A's node (0,0).
        final aSlightlyStronger = service.estimatePosition({'a': -60.0, 'b': -61.0}, storeMap)!;
        // B slightly stronger than A (a 2dB flip either way — easily just
        // noise): old code would snap all the way to B's node (10,0), a
        // 10-unit jump. The new weighted estimate should barely move.
        final bSlightlyStronger = service.estimatePosition({'a': -61.0, 'b': -60.0}, storeMap)!;

        final jump = (bSlightlyStronger - aSlightlyStronger).distance;
        expect(jump, lessThan(2.0), reason: 'a 2dB noise-scale flip moved the estimate by $jump units');
      },
    );

    test('with two beacons visible, the estimate is pulled toward but not glued to the stronger one', () {
      final estimate = service.estimatePosition({'a': -50.0, 'b': -80.0}, storeMap)!;
      // Much closer to A (0,0) than to B (10,0), since A is far stronger —
      // but not exactly on top of A either, since B still contributes.
      expect(estimate.dx, greaterThan(0));
      expect(estimate.dx, lessThan(5));
    });

    test('a single visible beacon still returns exactly its own position (nothing to blend with)', () {
      final estimate = service.estimatePosition({'a': -50.0}, storeMap);
      expect(estimate, const Offset(0, 0));
    });

    test('no beacons above the noise floor returns null', () {
      final estimate = service.estimatePosition({'a': -95.0, 'b': -95.0}, storeMap);
      expect(estimate, isNull);
    });

    test('an unknown bleId is ignored rather than crashing', () {
      final estimate = service.estimatePosition({'unknown-beacon': -50.0}, storeMap);
      expect(estimate, isNull);
    });
  });
}
