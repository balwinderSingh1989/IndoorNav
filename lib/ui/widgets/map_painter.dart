import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/beacon.dart';
import '../../models/store_map.dart' show Edge;

/// Draws the live user pin and the turn-by-turn route line on top of the
/// store's SVG floor plan. Coordinates are in the map's native SVG space;
/// the painter scales them to the widget's actual render size.
class MapPainter extends CustomPainter {
  MapPainter({
    required this.mapSize,
    required this.path,
    required this.edges,
    this.userLocation,
    this.livePosition,
    this.headingDegrees,
    this.mapNorthOffsetDegrees = 0,
  });

  final Size mapSize;
  final List<Beacon> path;

  /// The store's full edge list, used to look up each consecutive pair in
  /// [path]'s [Edge.waypoints] — so the drawn route bends the same way
  /// [StoreMap.snapToGraph] does, instead of cutting a straight line
  /// through corridors that actually curve.
  final List<Edge> edges;

  final Beacon? userLocation;

  /// PDR-tracked live position (map units) — takes priority over
  /// [userLocation]'s fixed beacon position for where the pin/arrow is
  /// drawn, when available.
  final Offset? livePosition;

  /// Live compass heading (degrees, 0 = North) — takes priority over the
  /// next-waypoint direction for which way the arrow points, when available.
  final double? headingDegrees;

  /// Compass bearing that corresponds to the map's "up" (-y) direction,
  /// used to convert [headingDegrees] into the map's coordinate frame.
  final double mapNorthOffsetDegrees;

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / mapSize.width;
    final scaleY = size.height / mapSize.height;
    Offset scale(Offset p) => Offset(p.dx * scaleX, p.dy * scaleY);

    if (path.isNotEmpty) {
      // A 1-beacon path means "arrived" (current beacon == destination) —
      // there's no line to draw, but the pin should still show, not vanish
      // along with everything else.
      if (path.length > 1) {
        final routePaint = Paint()
          ..color = const Color(0xFF1E88E5)
          ..strokeWidth = 7
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        final shadowPaint = Paint()
          ..color = Colors.black.withValues(alpha: 0.18)
          ..strokeWidth = 11
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;

        final routePath = Path()
          ..moveTo(scale(path.first.position).dx, scale(path.first.position).dy);
        for (var i = 0; i < path.length - 1; i++) {
          for (final waypoint in _orderedWaypoints(path[i].id, path[i + 1].id)) {
            final wp = scale(waypoint);
            routePath.lineTo(wp.dx, wp.dy);
          }
          final p = scale(path[i + 1].position);
          routePath.lineTo(p.dx, p.dy);
        }

        canvas.drawPath(routePath, shadowPaint);
        canvas.drawPath(routePath, routePaint);

        // Every waypoint except the destination gets a plain dot; the
        // destination gets a distinct pin (drawn below) instead.
        for (final beacon in path.sublist(0, path.length - 1)) {
          final p = scale(beacon.position);
          canvas.drawCircle(p, 6.5, Paint()..color = Colors.white);
          canvas.drawCircle(p, 4.5, Paint()..color = const Color(0xFF0D47A1));
        }
      }
      _drawDestinationPin(canvas, scale(path.last.position));
    }

    final user = userLocation;
    final rawPosition = livePosition ?? user?.position;
    if (rawPosition != null) {
      final p = scale(rawPosition);
      canvas.drawCircle(p, 11, Paint()..color = Colors.white);

      final heading = headingDegrees;
      if (heading != null) {
        final angle = (heading - mapNorthOffsetDegrees) * math.pi / 180;
        _drawDirectionArrow(canvas, from: p, angle: angle);
      } else {
        final next = user == null ? null : _nextWaypoint(user);
        if (next != null) {
          final target = scale(next.position);
          _drawDirectionArrow(canvas, from: p, angle: math.atan2(target.dy - p.dy, target.dx - p.dx));
        } else {
          canvas.drawCircle(p, 7.5, Paint()..color = Colors.redAccent);
        }
      }
    }
  }

  /// The waypoints of the edge between beacons [aId] and [bId], ordered
  /// from [aId] toward [bId] regardless of which direction the edge was
  /// defined in — or empty if they aren't directly connected, or that
  /// edge has no bend.
  List<Offset> _orderedWaypoints(String aId, String bId) {
    for (final edge in edges) {
      if (edge.from == aId && edge.to == bId) return edge.waypoints;
      if (edge.from == bId && edge.to == aId) return edge.waypoints.reversed.toList();
    }
    return const [];
  }

  /// The beacon immediately after [user] on the current route, or null if
  /// [user] isn't on the route (or has already reached its end) — i.e.
  /// there's no "forward" direction left to point an arrow toward.
  Beacon? _nextWaypoint(Beacon user) {
    final index = path.indexWhere((b) => b.id == user.id);
    if (index == -1 || index >= path.length - 1) return null;
    return path[index + 1];
  }

  /// Draws a map-pin marker at [point], anchored so the pin's tip (its
  /// visual point, at the bottom of the glyph) lands exactly on it, using
  /// Flutter's standard "render an Icon's glyph via TextPainter" technique
  /// for drawing Material icons inside a CustomPainter.
  void _drawDestinationPin(Canvas canvas, Offset point) {
    const icon = Icons.location_on;
    const size = 34.0;
    final textPainter = TextPainter(textDirection: TextDirection.ltr)
      ..text = TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: size,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: const Color(0xFF2E7D32),
        ),
      )
      ..layout();
    textPainter.paint(canvas, Offset(point.dx - textPainter.width / 2, point.dy - textPainter.height));
  }

  /// Draws a compact red location dot for the current position.
  /// Simple, clear, and easy to read in a retail navigation POC.
  void _drawDirectionArrow(Canvas canvas, {required Offset from, required double angle}) {
    canvas.save();
    canvas.translate(from.dx, from.dy);
    canvas.rotate(angle);

    canvas.drawCircle(const Offset(0, 0), 12, Paint()..color = Colors.white.withValues(alpha: 0.9));
    canvas.drawCircle(const Offset(0, 0), 7, Paint()..color = Colors.red);
    canvas.drawCircle(const Offset(0, 0), 3, Paint()..color = Colors.white);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant MapPainter oldDelegate) {
    return oldDelegate.path != path ||
        oldDelegate.edges != edges ||
        oldDelegate.userLocation?.id != userLocation?.id ||
        oldDelegate.livePosition != livePosition ||
        oldDelegate.headingDegrees != headingDegrees ||
        oldDelegate.mapNorthOffsetDegrees != mapNorthOffsetDegrees ||
        oldDelegate.mapSize != mapSize;
  }
}
