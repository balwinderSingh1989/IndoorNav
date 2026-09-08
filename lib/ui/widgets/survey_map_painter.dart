import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../models/magnetic_fingerprint.dart';
import '../../models/wifi_fingerprint.dart';

class SurveyMapPainter extends CustomPainter {
  SurveyMapPainter({
    required this.mapSize,
    required this.trajectories,
    required this.wifiFingerprints,
    this.showMagnetic = true,
    this.showWifi = true,
    this.showGaps = true,
    this.showSimilarMagnetic = true,
    this.anchorPositions = const {},
    this.highlightedAnchorBssid,
    this.highlightProgress = 0,
  });

  final Size mapSize;
  final List<MagneticTrajectory> trajectories;
  final List<WifiFingerprint> wifiFingerprints;
  final bool showMagnetic;
  final bool showWifi;
  final bool showGaps;
  final bool showSimilarMagnetic;
  final Map<String, Offset> anchorPositions;
  final String? highlightedAnchorBssid;
  final double highlightProgress;

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / mapSize.width;
    final scaleY = size.height / mapSize.height;
    Offset scale(Offset point) => Offset(point.dx * scaleX, point.dy * scaleY);

    if (showGaps) _drawCoverageGaps(canvas, scale);
    if (showSimilarMagnetic) _drawSimilarMagnetic(canvas, scale);
    if (showMagnetic) _drawMagneticTrajectories(canvas, scale);
    if (showWifi) _drawWifiPoints(canvas, scale);
    if (showWifi) _drawWifiAnchors(canvas, scale);
  }

  void _drawMagneticTrajectories(Canvas canvas, Offset Function(Offset) scale) {
    final paint = Paint()
      ..color = Colors.deepPurple.withValues(alpha: 0.72)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final trajectory in trajectories) {
      if (trajectory.positions.length < 2) continue;
      final path = Path()..moveTo(scale(trajectory.positions.first).dx, scale(trajectory.positions.first).dy);
      for (final position in trajectory.positions.skip(1)) {
        final point = scale(position);
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  void _drawWifiPoints(Canvas canvas, Offset Function(Offset) scale) {
    for (final fingerprint in wifiFingerprints) {
      final point = scale(fingerprint.position);
      canvas.drawCircle(point, 6, Paint()..color = Colors.white);
      canvas.drawCircle(point, 4, Paint()..color = Colors.teal);
    }
  }

  void _drawWifiAnchors(Canvas canvas, Offset Function(Offset) scale) {
    final paint = Paint()
      ..color = Colors.blueAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final entry in anchorPositions.entries) {
      final position = entry.value;
      final point = scale(position);
      canvas.drawCircle(point, 10, paint);
      canvas.drawCircle(point, 4, Paint()..color = Colors.blueAccent);
      if (entry.key == highlightedAnchorBssid) {
        final radius = 14 + highlightProgress * 12;
        canvas.drawCircle(
          point,
          radius,
          Paint()
            ..color = Colors.amber.withValues(alpha: 0.9 - highlightProgress * 0.45)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4,
        );
      }
    }
  }

  void _drawCoverageGaps(Canvas canvas, Offset Function(Offset) scale) {
    const cellSize = 18.0;
    final covered = <String>{};
    for (final fingerprint in wifiFingerprints) {
      covered.add(_cellKey(fingerprint.position, cellSize));
    }
    for (final trajectory in trajectories) {
      for (final position in trajectory.positions) {
        covered.add(_cellKey(position, cellSize));
      }
    }
    final paint = Paint()..color = Colors.red.withValues(alpha: 0.13);
    for (var x = 0.0; x < mapSize.width; x += cellSize) {
      for (var y = 0.0; y < mapSize.height; y += cellSize) {
        if (covered.contains('${x ~/ cellSize}:${y ~/ cellSize}')) continue;
        final topLeft = scale(Offset(x, y));
        final bottomRight = scale(Offset(math.min(x + cellSize, mapSize.width), math.min(y + cellSize, mapSize.height)));
        canvas.drawRect(Rect.fromLTRB(topLeft.dx, topLeft.dy, bottomRight.dx, bottomRight.dy), paint);
      }
    }
  }

  void _drawSimilarMagnetic(Canvas canvas, Offset Function(Offset) scale) {
    final bins = <String, List<Offset>>{};
    const cellSize = 18.0;
    for (final trajectory in trajectories) {
      for (var i = 0; i < trajectory.samples.length && i < trajectory.positions.length; i++) {
        final magnitude = trajectory.samples[i].magnitude;
        if (magnitude < 35 || magnitude > 55) continue;
        bins.putIfAbsent(_cellKey(trajectory.positions[i], cellSize), () => []).add(trajectory.positions[i]);
      }
    }
    final paint = Paint()..color = Colors.orange.withValues(alpha: 0.22);
    for (final positions in bins.values) {
      if (positions.length < 2) continue;
      final center = positions.reduce((a, b) => a + b) / positions.length.toDouble();
      canvas.drawCircle(scale(center), 9, paint);
    }
  }

  String _cellKey(Offset point, double cellSize) => '${point.dx ~/ cellSize}:${point.dy ~/ cellSize}';

  @override
  bool shouldRepaint(covariant SurveyMapPainter oldDelegate) =>
      oldDelegate.trajectories != trajectories ||
      oldDelegate.wifiFingerprints != wifiFingerprints ||
      oldDelegate.showMagnetic != showMagnetic ||
      oldDelegate.showWifi != showWifi ||
      oldDelegate.showGaps != showGaps ||
      oldDelegate.showSimilarMagnetic != showSimilarMagnetic ||
      oldDelegate.anchorPositions != anchorPositions ||
      oldDelegate.highlightedAnchorBssid != highlightedAnchorBssid ||
      oldDelegate.highlightProgress != highlightProgress ||
      oldDelegate.mapSize != mapSize;
}