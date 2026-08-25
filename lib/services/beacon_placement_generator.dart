import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/services.dart' show rootBundle;
import 'package:xml/xml.dart';

import '../models/store_map.dart';

class BeaconPlacementSuggestion {
  const BeaconPlacementSuggestion({
    required this.index,
    required this.position,
    required this.distanceFromPreviousMeters,
  });

  final int index;
  final Offset position;
  final double distanceFromPreviousMeters;
}

class CorridorSegment {
  const CorridorSegment({
    required this.startX,
    required this.startY,
    required this.endX,
    required this.endY,
    required this.label,
  });

  final double startX;
  final double startY;
  final double endX;
  final double endY;
  final String label;

  double get lengthUnits => (Offset(endX, endY) - Offset(startX, startY)).distance;

  bool isHorizontal(double tolerance) => (endY - startY).abs() <= tolerance;

  bool isVertical(double tolerance) => (endX - startX).abs() <= tolerance;
}

class BeaconPlacementGenerator {
  const BeaconPlacementGenerator();

  static final Map<String, List<CorridorSegment>> _segmentCache = {};

  static Future<List<CorridorSegment>> loadWalkableSegments(String assetPath) async {
    final cached = _segmentCache[assetPath];
    if (cached != null) return cached;

    final svgText = await rootBundle.loadString(assetPath);
    final document = XmlDocument.parse(svgText);
    final segments = <CorridorSegment>[];

    for (final element in document.findAllElements('path')) {
      final d = element.getAttribute('d');
      if (d == null || d.trim().isEmpty) continue;

      final points = _parsePathPoints(d);
      if (points.length < 2) continue;

      for (var i = 0; i < points.length - 1; i++) {
        final start = points[i];
        final end = points[i + 1];
        final length = (end - start).distance;
        if (length < 1.0) continue;

        segments.add(
          CorridorSegment(
            startX: start.dx,
            startY: start.dy,
            endX: end.dx,
            endY: end.dy,
            label: element.getAttribute('id') ?? 'walkable_path_${segments.length + 1}',
          ),
        );
      }
    }

    _segmentCache[assetPath] = segments;
    return segments;
  }

  static List<Offset> inferJunctions(
    List<CorridorSegment> segments, {
    double toleranceUnits = 2.0,
  }) {
    final junctions = <Offset>[];
    for (var i = 0; i < segments.length; i++) {
      for (var j = i + 1; j < segments.length; j++) {
        final point = _segmentIntersection(
          segments[i],
          segments[j],
          toleranceUnits: toleranceUnits,
        );
        if (point != null) {
          junctions.add(point);
        }
      }
    }

    final deduped = <Offset>[];
    for (final point in junctions) {
      final alreadyPresent = deduped.any((existing) => (existing - point).distance <= toleranceUnits);
      if (!alreadyPresent) {
        deduped.add(point);
      }
    }

    deduped.sort((a, b) {
      final y = a.dy.compareTo(b.dy);
      if (y != 0) return y;
      return a.dx.compareTo(b.dx);
    });
    return deduped;
  }

  static List<_PointOnPath> sampleSegmentAnchors(
    CorridorSegment segment,
    BeaconPlacementConfig config,
    double metersPerUnit,
  ) {
    final spacingMeters = _clampSpacing(
      config.targetSpacingMeters,
      config.minSpacingMeters,
      config.maxSpacingMeters,
    );

    final segmentLengthMeters = segment.lengthUnits * metersPerUnit;
    final intervalCount = config.maxBeaconsPerSegment ?? _anchorCountForLength(segmentLengthMeters, spacingMeters);
    final anchorCount = intervalCount.clamp(1, math.max(1, intervalCount));

    if (anchorCount <= 1) {
      return [
        _pointOnSegment(
          segment,
          0.5,
          xOffset: config.mountOffsetXUnits,
          yOffset: config.mountOffsetYUnits,
        ),
      ];
    }

    final points = <_PointOnPath>[];
    for (var i = 0; i < anchorCount; i++) {
      final ratio = i / (anchorCount - 1);
      points.add(
        _pointOnSegment(
          segment,
          ratio,
          xOffset: config.mountOffsetXUnits,
          yOffset: config.mountOffsetYUnits,
        ),
      );
    }
    return points;
  }

  static int _anchorCountForLength(double segmentLengthMeters, double spacingMeters) {
    if (segmentLengthMeters <= 0) return 1;
    return math.max(2, (segmentLengthMeters / spacingMeters).round() + 1).toInt();
  }

  static double _clampSpacing(double target, double min, double max) {
    if (target < min) return min;
    if (target > max) return max;
    return target;
  }

  static Offset? _segmentIntersection(
    CorridorSegment a,
    CorridorSegment b, {
    required double toleranceUnits,
  }) {
    final denominator =
        (a.startX - a.endX) * (b.startY - b.endY) - (a.startY - a.endY) * (b.startX - b.endX);
    if (denominator.abs() < 1e-6) {
      return null;
    }

    final intersectionX =
        ((a.startX * a.endY - a.startY * a.endX) * (b.startX - b.endX) -
                (a.startX - a.endX) * (b.startX * b.endY - b.startY * b.endX)) /
            denominator;
    final intersectionY =
        ((a.startX * a.endY - a.startY * a.endX) * (b.startY - b.endY) -
                (a.startY - a.endY) * (b.startX * b.endY - b.startY * b.endX)) /
            denominator;

    final point = Offset(intersectionX, intersectionY);
    if (!_isPointOnSegment(point, a, toleranceUnits: toleranceUnits) ||
        !_isPointOnSegment(point, b, toleranceUnits: toleranceUnits)) {
      return null;
    }
    return point;
  }

  static bool _isPointOnSegment(
    Offset point,
    CorridorSegment segment, {
    required double toleranceUnits,
  }) {
    final dx = segment.endX - segment.startX;
    final dy = segment.endY - segment.startY;
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared == 0) {
      return (point - Offset(segment.startX, segment.startY)).distance <= toleranceUnits;
    }

    final t = ((point.dx - segment.startX) * dx + (point.dy - segment.startY) * dy) / lengthSquared;
    final clampedT = t.clamp(0.0, 1.0);
    final closest = Offset(
      segment.startX + dx * clampedT,
      segment.startY + dy * clampedT,
    );
    return (point - closest).distance <= toleranceUnits;
  }

  static List<Offset> _parsePathPoints(String d) {
    final pattern = RegExp(
      r'[MLmlHVhZz]|[-+]?(?:\d*\.\d+|\d+\.\d*|\d+)(?:[eE][-+]?\d+)?',
    );
    final tokens = pattern.allMatches(d).map((match) => match.group(0)!).toList();
    if (tokens.isEmpty) return const [];

    final points = <Offset>[];
    var x = 0.0;
    var y = 0.0;
    String? command;
    var index = 0;

    while (index < tokens.length) {
      final token = tokens[index];
      if (_isPathCommand(token)) {
        command = token;
        index += 1;
        continue;
      }

      final value = double.parse(token);
      switch (command ?? 'L') {
        case 'M':
          x = value;
          y = double.parse(tokens[index + 1]);
          points.add(Offset(x, y));
          index += 2;
          command = 'L';
          break;
        case 'm':
          x += value;
          y += double.parse(tokens[index + 1]);
          points.add(Offset(x, y));
          index += 2;
          command = 'l';
          break;
        case 'L':
          x = value;
          y = double.parse(tokens[index + 1]);
          points.add(Offset(x, y));
          index += 2;
          break;
        case 'l':
          x += value;
          y += double.parse(tokens[index + 1]);
          points.add(Offset(x, y));
          index += 2;
          break;
        case 'H':
          x = value;
          points.add(Offset(x, y));
          index += 1;
          break;
        case 'h':
          x += value;
          points.add(Offset(x, y));
          index += 1;
          break;
        case 'V':
          y = value;
          points.add(Offset(x, y));
          index += 1;
          break;
        case 'v':
          y += value;
          points.add(Offset(x, y));
          index += 1;
          break;
        default:
          index += 1;
          break;
      }
    }

    return points;
  }

  static bool _isPathCommand(String token) {
    return {'M', 'm', 'L', 'l', 'H', 'h', 'V', 'v', 'Z', 'z'}.contains(token);
  }

  Future<List<BeaconPlacementSuggestion>> generate(StoreMap storeMap, {int? desiredCount}) async {
    final segments = await loadWalkableSegments(storeMap.mapAsset);
    if (segments.isEmpty) {
      return const <BeaconPlacementSuggestion>[];
    }

    final config = storeMap.beaconPlacement;
    final junctions = inferJunctions(segments, toleranceUnits: config.axisToleranceUnits);
    final orderedPoints = <_PointOnPath>[];

    for (final segment in segments) {
      orderedPoints.addAll(sampleSegmentAnchors(segment, config, storeMap.metersPerUnit));
    }

    for (final junction in junctions) {
      orderedPoints.add(
        _PointOnPath(
          position: Offset(
            junction.dx + config.mountOffsetXUnits,
            junction.dy + config.mountOffsetYUnits,
          ),
          segmentLabel: 'junction',
          positionAlongSegment: 0,
          segmentIndex: -1,
        ),
      );
    }

    final dedupeRadiusUnits = (config.dedupeRadiusMeters / storeMap.metersPerUnit).clamp(0.0, double.infinity);
    final unique = _dedupeNearestPoints(orderedPoints, dedupeRadiusUnits: dedupeRadiusUnits)
      ..sort((a, b) {
        final y = a.position.dy.compareTo(b.position.dy);
        if (y != 0) return y;
        return a.position.dx.compareTo(b.position.dx);
      });

    final effectiveDesiredCount = desiredCount ?? config.desiredBeaconCount;
    final prioritized = _prioritizeAnchors(unique, junctions, toleranceUnits: config.axisToleranceUnits)
      ..sort((a, b) {
        final aPriority = a.segmentLabel == 'junction' ? 0 : 1;
        final bPriority = b.segmentLabel == 'junction' ? 0 : 1;
        if (aPriority != bPriority) return aPriority.compareTo(bPriority);
        final y = a.position.dy.compareTo(b.position.dy);
        if (y != 0) return y;
        return a.position.dx.compareTo(b.position.dx);
      });

    final finalPoints = effectiveDesiredCount == null
        ? prioritized
        : (prioritized.take(effectiveDesiredCount).toList());

    final spacedPoints = filterByMinSpacing(
      finalPoints,
      minSpacingMeters: config.minSpacingMeters,
      metersPerUnit: storeMap.metersPerUnit,
    );

    final suggestions = <BeaconPlacementSuggestion>[];
    for (var i = 0; i < spacedPoints.length; i++) {
      final point = spacedPoints[i];
      final previous = suggestions.isEmpty ? null : suggestions.last.position;
      final gapMeters = previous == null ? 0.0 : (point.position - previous).distance * storeMap.metersPerUnit;

      suggestions.add(
        BeaconPlacementSuggestion(
          index: i + 1,
          position: point.position,
          distanceFromPreviousMeters: gapMeters,
        ),
      );
    }

    return suggestions;
  }

  static List<_PointOnPath> _prioritizeAnchors(
    List<_PointOnPath> points,
    List<Offset> junctions, {
    required double toleranceUnits,
  }) {
    final ranked = points
        .map((point) {
          final isJunction = junctions.any((junction) => (junction - point.position).distance <= toleranceUnits);
          return (
            point: point,
            priority: isJunction ? 0 : 1,
          );
        })
        .toList();

    ranked.sort((a, b) {
      if (a.priority != b.priority) return a.priority.compareTo(b.priority);
      final y = a.point.position.dy.compareTo(b.point.position.dy);
      if (y != 0) return y;
      return a.point.position.dx.compareTo(b.point.position.dx);
    });

    return ranked.map((entry) => entry.point).toList();
  }

  static List<_PointOnPath> _dedupeNearestPoints(
    List<_PointOnPath> points, {
    required double dedupeRadiusUnits,
  }) {
    final deduped = <_PointOnPath>[];
    for (final point in points) {
      final exists = deduped.any((existing) => (existing.position - point.position).distance <= dedupeRadiusUnits);
      if (!exists) deduped.add(point);
    }
    return deduped;
  }

  static List<_PointOnPath> filterByMinSpacing(
    List<_PointOnPath> points, {
    required double minSpacingMeters,
    required double metersPerUnit,
  }) {
    final minSpacingUnits = minSpacingMeters / metersPerUnit;
    final filtered = <_PointOnPath>[];
    for (final point in points) {
      final tooClose = filtered.any(
        (existing) => (existing.position - point.position).distance < minSpacingUnits,
      );
      if (!tooClose) {
        filtered.add(point);
      }
    }
    return filtered;
  }

  static _PointOnPath _pointOnSegment(
    CorridorSegment segment,
    double ratio, {
    double xOffset = 0,
    double yOffset = 0,
  }) {
    final x = segment.startX + (segment.endX - segment.startX) * ratio + xOffset;
    final y = segment.startY + (segment.endY - segment.startY) * ratio + yOffset;

    return _PointOnPath(
      position: Offset(x, y),
      segmentLabel: segment.label,
      positionAlongSegment: ratio,
      segmentIndex: 0,
    );
  }
}

class _PointOnPath {
  const _PointOnPath({
    required this.position,
    required this.segmentLabel,
    required this.positionAlongSegment,
    required this.segmentIndex,
  });

  final Offset position;
  final String segmentLabel;
  final double positionAlongSegment;
  final int segmentIndex;
}
