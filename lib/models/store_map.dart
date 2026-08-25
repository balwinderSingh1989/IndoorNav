import 'dart:ui' show Offset;

import 'beacon.dart';
import 'item.dart';

/// A weighted, undirected edge between two beacons in the aisle graph.
///
/// [waypoints] are purely geometric — intermediate points (in order from
/// [from] to [to]) that bend the corridor's *shape* around obstacles a
/// straight line between the two beacons would cut through. They are not
/// graph nodes: routing (Dijkstra, in [PathfindingService]) only ever
/// starts/ends at real beacons, exactly as many as there is physical
/// hardware for — waypoints just make [StoreMap.snapToGraph] (and the
/// drawn route line) follow the corridor's actual bend instead of an
/// imaginary straight line between two beacons.
class Edge {
  final String from;
  final String to;
  final double weight;
  final List<Offset> waypoints;

  const Edge({required this.from, required this.to, required this.weight, this.waypoints = const []});

  factory Edge.fromJson(Map<String, dynamic> json) {
    final rawWaypoints = json['waypoints'] as List?;
    return Edge(
      from: json['from'] as String,
      to: json['to'] as String,
      weight: (json['weight'] as num).toDouble(),
      waypoints: rawWaypoints == null
          ? const []
          : rawWaypoints
              .map((w) => Offset(
                    ((w as Map<String, dynamic>)['x'] as num).toDouble(),
                    (w['y'] as num).toDouble(),
                  ))
              .toList(),
    );
  }
}

class BeaconPlacementConfig {
  const BeaconPlacementConfig({
    this.minSpacingMeters = 3.0,
    this.maxSpacingMeters = 6.0,
    this.targetSpacingMeters = 4.5,
    this.maxBeaconsPerSegment,
    this.axisToleranceUnits = 2.0,
    this.dedupeRadiusMeters = 1.5,
    this.desiredBeaconCount,
    this.mountOffsetXUnits = 0.0,
    this.mountOffsetYUnits = 0.0,
  });

  final double minSpacingMeters;
  final double maxSpacingMeters;
  final double targetSpacingMeters;
  final int? maxBeaconsPerSegment;
  final double axisToleranceUnits;
  final double dedupeRadiusMeters;
  final int? desiredBeaconCount;
  final double mountOffsetXUnits;
  final double mountOffsetYUnits;

  factory BeaconPlacementConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null || json.isEmpty) {
      return const BeaconPlacementConfig();
    }

    return BeaconPlacementConfig(
      minSpacingMeters: (json['minSpacingMeters'] as num? ?? 3.0).toDouble(),
      maxSpacingMeters: (json['maxSpacingMeters'] as num? ?? 6.0).toDouble(),
      targetSpacingMeters: (json['targetSpacingMeters'] as num? ?? 4.5).toDouble(),
      maxBeaconsPerSegment: json['maxBeaconsPerSegment'] as int?,
      axisToleranceUnits: (json['axisToleranceUnits'] as num? ?? 2.0).toDouble(),
      dedupeRadiusMeters: (json['dedupeRadiusMeters'] as num? ?? 1.5).toDouble(),
      desiredBeaconCount: json['desiredBeaconCount'] as int?,
      mountOffsetXUnits: (json['mountOffsetXUnits'] as num? ?? 0.0).toDouble(),
      mountOffsetYUnits: (json['mountOffsetYUnits'] as num? ?? 0.0).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'minSpacingMeters': minSpacingMeters,
        'maxSpacingMeters': maxSpacingMeters,
        'targetSpacingMeters': targetSpacingMeters,
        'maxBeaconsPerSegment': maxBeaconsPerSegment,
        'axisToleranceUnits': axisToleranceUnits,
        'dedupeRadiusMeters': dedupeRadiusMeters,
        'desiredBeaconCount': desiredBeaconCount,
        'mountOffsetXUnits': mountOffsetXUnits,
        'mountOffsetYUnits': mountOffsetYUnits,
      };
}

/// The full store layout: beacon positions, the aisle graph, and the map asset to render.
class StoreMap {
  final String mapAsset;
  final double mapWidth;
  final double mapHeight;

  /// Real-world meters per one map/SVG coordinate unit. Used to convert
  /// step-length-based movement (meters) into map-space offsets. Calibrated
  /// from measured real-world distances between beacons — see README.
  final double metersPerUnit;

  /// Compass bearing (degrees, 0 = North) that corresponds to the map's
  /// "up" (-y) direction, e.g. 90 if the top of the floor plan faces East.
  /// Used to rotate compass headings into the map's coordinate frame.
  final double mapNorthOffsetDegrees;

  final List<Beacon> beacons;
  final List<Edge> edges;
  final List<Item> items;
  final BeaconPlacementConfig beaconPlacement;

  const StoreMap({
    required this.mapAsset,
    required this.mapWidth,
    required this.mapHeight,
    required this.metersPerUnit,
    required this.mapNorthOffsetDegrees,
    required this.beacons,
    required this.edges,
    required this.items,
    this.beaconPlacement = const BeaconPlacementConfig(),
  });

  factory StoreMap.fromJson(Map<String, dynamic> json) {
    return StoreMap(
      mapAsset: json['mapAsset'] as String,
      mapWidth: (json['mapWidth'] as num).toDouble(),
      mapHeight: (json['mapHeight'] as num).toDouble(),
      metersPerUnit: (json['metersPerUnit'] as num? ?? 1.0).toDouble(),
      mapNorthOffsetDegrees: (json['mapNorthOffsetDegrees'] as num? ?? 0.0).toDouble(),
      beacons: (json['beacons'] as List)
          .map((b) => Beacon.fromJson(b as Map<String, dynamic>))
          .toList(),
      edges: (json['edges'] as List)
          .map((e) => Edge.fromJson(e as Map<String, dynamic>))
          .toList(),
      items: (json['items'] as List? ?? [])
          .map((i) => Item.fromJson(i as Map<String, dynamic>))
          .toList(),
      beaconPlacement: BeaconPlacementConfig.fromJson(json['beaconPlacement'] as Map<String, dynamic>?),
    );
  }

  Beacon? beaconById(String id) {
    for (final b in beacons) {
      if (b.id == id) return b;
    }
    return null;
  }

  Beacon? beaconByBleId(String bleId) {
    for (final b in beacons) {
      if (b.matchesBleId(bleId)) return b;
    }
    return null;
  }

  /// The edge connecting [aId] and [bId] (either direction), or null if
  /// they aren't directly connected. Used to look up a corridor's
  /// [Edge.waypoints] for drawing its actual bent shape rather than a
  /// straight line between the two beacons.
  Edge? edgeBetween(String aId, String bId) {
    for (final edge in edges) {
      if ((edge.from == aId && edge.to == bId) || (edge.from == bId && edge.to == aId)) return edge;
    }
    return null;
  }

  /// Adjacency list built from [edges], treated as undirected.
  Map<String, List<Edge>> get adjacency {
    final map = <String, List<Edge>>{};
    for (final e in edges) {
      map.putIfAbsent(e.from, () => []).add(e);
      map.putIfAbsent(e.to, () => []).add(
            Edge(from: e.to, to: e.from, weight: e.weight, waypoints: e.waypoints.reversed.toList()),
          );
    }
    return map;
  }

  /// The closest point to [point] lying on any edge of the corridor graph
  /// — i.e. map-matching: projects [point] onto the nearest segment of
  /// each edge's polyline (its two beacon endpoints, bent through any
  /// [Edge.waypoints] in between), clamped to that segment's endpoints.
  /// Used to keep PDR-tracked movement confined to walkable corridors
  /// instead of drifting into room interiors, which have no edges of
  /// their own.
  ///
  /// [preferredEdge] (typically the edge chosen last call) gets a distance
  /// discount before comparing, so a noisy/imprecise raw point doesn't
  /// flip-flop between two similarly-close edges on every step — it only
  /// switches corridors when another edge is *meaningfully* closer, not
  /// just marginally closer. The edge actually chosen is returned alongside
  /// the point so the caller can pass it back in as next call's preference.
  ({Offset point, Edge? edge}) snapToGraph(Offset point, {Edge? preferredEdge}) {
    Offset? closest;
    Edge? closestEdge;
    var bestScore = double.infinity;
    for (final edge in edges) {
      final a = beaconById(edge.from)?.position;
      final b = beaconById(edge.to)?.position;
      if (a == null || b == null) continue;
      final polyline = [a, ...edge.waypoints, b];
      for (var i = 0; i < polyline.length - 1; i++) {
        final projected = _projectOntoSegment(point, polyline[i], polyline[i + 1]);
        var score = (projected - point).distanceSquared;
        if (preferredEdge != null && _sameEdge(edge, preferredEdge)) {
          score *= 0.5; // Bias toward staying on the corridor already being walked.
        }
        if (score < bestScore) {
          bestScore = score;
          closest = projected;
          closestEdge = edge;
        }
      }
    }
    return (point: closest ?? point, edge: closestEdge);
  }

  bool _sameEdge(Edge a, Edge b) =>
      (a.from == b.from && a.to == b.to) || (a.from == b.to && a.to == b.from);

  Offset _projectOntoSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final abLengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
    if (abLengthSquared == 0) return a;
    final t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / abLengthSquared;
    final tClamped = t.clamp(0.0, 1.0);
    return Offset(a.dx + ab.dx * tClamped, a.dy + ab.dy * tClamped);
  }
}
