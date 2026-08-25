import 'dart:ui' show Offset;

import 'package:flutter_test/flutter_test.dart';
import 'package:indoor_nav/models/beacon.dart';
import 'package:indoor_nav/models/store_map.dart';
import 'package:indoor_nav/services/beacon_placement_generator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('infers corridor junctions by computing real intersections', () {
    final segments = <CorridorSegment>[
      const CorridorSegment(startX: 0, startY: 0, endX: 100, endY: 0, label: 'horizontal'),
      const CorridorSegment(startX: 50, startY: -20, endX: 50, endY: 80, label: 'vertical'),
    ];

    final junctions = BeaconPlacementGenerator.inferJunctions(segments, toleranceUnits: 0.5);

    expect(junctions, hasLength(1));
    expect(junctions.first.dx, closeTo(50, 0.01));
    expect(junctions.first.dy, closeTo(0, 0.01));
  });

  test('spacing follows config values instead of hardcoded 4.5m policy', () {
    final config = BeaconPlacementConfig(
      minSpacingMeters: 10,
      maxSpacingMeters: 30,
      targetSpacingMeters: 25,
      axisToleranceUnits: 0.5,
      dedupeRadiusMeters: 0.25,
      mountOffsetXUnits: 0,
      mountOffsetYUnits: 0,
    );

    final points = BeaconPlacementGenerator.sampleSegmentAnchors(
      const CorridorSegment(startX: 0, startY: 0, endX: 100, endY: 0, label: 'sample'),
      config,
      1,
    );

    expect(points.length, 5);
    expect(points.first.position.dx, closeTo(0, 0.01));
    expect(points[1].position.dx, closeTo(25, 0.01));
    expect(points[2].position.dx, closeTo(50, 0.01));
    expect(points[3].position.dx, closeTo(75, 0.01));
    expect(points[4].position.dx, closeTo(100, 0.01));
  });

  test('applies no default mount offset on generated anchors', () {
    final config = const BeaconPlacementConfig(
      minSpacingMeters: 10,
      maxSpacingMeters: 40,
      targetSpacingMeters: 20,
      axisToleranceUnits: 0.5,
      dedupeRadiusMeters: 0.25,
      mountOffsetXUnits: 0,
      mountOffsetYUnits: 0,
    );

    final points = BeaconPlacementGenerator.sampleSegmentAnchors(
      const CorridorSegment(startX: 0, startY: 0, endX: 100, endY: 0, label: 'offset-check'),
      config,
      1,
    );

    expect(points.first.position.dx, closeTo(0, 0.01));
    expect(points.first.position.dy, closeTo(0, 0.01));
    expect(points.last.position.dx, closeTo(100, 0.01));
    expect(points.last.position.dy, closeTo(0, 0.01));
    expect(points.first.position.dx, isNot(closeTo(30, 0.01)));
    expect(points.first.position.dy, isNot(closeTo(20, 0.01)));
  });

  test('skips nearby suggestions that violate the configured minimum spacing', () async {
    final storeMap = StoreMap(
      mapAsset: 'assets/floorMap.svg',
      mapWidth: 297,
      mapHeight: 210,
      metersPerUnit: 0.104,
      mapNorthOffsetDegrees: 180,
      beacons: const [],
      edges: const [],
      items: const [],
      beaconPlacement: const BeaconPlacementConfig(
        minSpacingMeters: 20,
        maxSpacingMeters: 30,
        targetSpacingMeters: 4.5,
        axisToleranceUnits: 2,
        dedupeRadiusMeters: 0.5,
        mountOffsetXUnits: 0,
        mountOffsetYUnits: 0,
      ),
    );

    final suggestions = await BeaconPlacementGenerator().generate(storeMap);

    expect(suggestions, isNotEmpty);
    for (var i = 1; i < suggestions.length; i++) {
      final gapMeters = (suggestions[i].position - suggestions[i - 1].position).distance * storeMap.metersPerUnit;
      expect(gapMeters, greaterThanOrEqualTo(20));
    }
  });

  test('applies the configured mount offset to generated suggestions', () async {
    final baseMap = StoreMap(
      mapAsset: 'assets/floorMap.svg',
      mapWidth: 297,
      mapHeight: 210,
      metersPerUnit: 0.104,
      mapNorthOffsetDegrees: 180,
      beacons: const [],
      edges: const [],
      items: const [],
      beaconPlacement: const BeaconPlacementConfig(
        minSpacingMeters: 3,
        maxSpacingMeters: 6,
        targetSpacingMeters: 4.5,
        axisToleranceUnits: 2,
        dedupeRadiusMeters: 0.5,
        mountOffsetXUnits: 0,
        mountOffsetYUnits: 0,
      ),
    );

    final offsetMap = StoreMap(
      mapAsset: 'assets/floorMap.svg',
      mapWidth: 297,
      mapHeight: 210,
      metersPerUnit: 0.104,
      mapNorthOffsetDegrees: 180,
      beacons: const [],
      edges: const [],
      items: const [],
      beaconPlacement: const BeaconPlacementConfig(
        minSpacingMeters: 3,
        maxSpacingMeters: 6,
        targetSpacingMeters: 4.5,
        axisToleranceUnits: 2,
        dedupeRadiusMeters: 0.5,
        mountOffsetXUnits: 10,
        mountOffsetYUnits: 12,
      ),
    );

    final baseSuggestions = await BeaconPlacementGenerator().generate(baseMap);
    final offsetSuggestions = await BeaconPlacementGenerator().generate(offsetMap);

    expect(baseSuggestions, isNotEmpty);
    expect(offsetSuggestions, isNotEmpty);
    expect(offsetSuggestions.length, baseSuggestions.length);

    for (var i = 0; i < baseSuggestions.length; i++) {
      final dx = offsetSuggestions[i].position.dx - baseSuggestions[i].position.dx;
      final dy = offsetSuggestions[i].position.dy - baseSuggestions[i].position.dy;
      expect(dx, closeTo(10, 1.0));
      expect(dy, closeTo(12, 1.0));
    }
  });

  test('returns all anchors when desiredBeaconCount is omitted', () async {
    final storeMap = StoreMap(
      mapAsset: 'assets/floorMap.svg',
      mapWidth: 297,
      mapHeight: 210,
      metersPerUnit: 0.104,
      mapNorthOffsetDegrees: 180,
      beacons: const [],
      edges: const [],
      items: const [],
      beaconPlacement: const BeaconPlacementConfig(
        minSpacingMeters: 3,
        maxSpacingMeters: 6,
        targetSpacingMeters: 4.5,
        axisToleranceUnits: 2,
        dedupeRadiusMeters: 0.5,
        mountOffsetXUnits: 0,
        mountOffsetYUnits: 0,
      ),
    );

    final suggestions = await BeaconPlacementGenerator().generate(storeMap);

    expect(suggestions, isNotEmpty);
    expect(suggestions.map((s) => s.position).toSet().length, suggestions.length);
  });
}
