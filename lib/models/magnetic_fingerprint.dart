import 'dart:math' as math;
import 'dart:ui' show Offset;

class MagneticSample {
  const MagneticSample({
    required this.timestamp,
    required this.x,
    required this.y,
    required this.z,
  });

  final DateTime timestamp;
  final double x;
  final double y;
  final double z;

  factory MagneticSample.fromJson(Map<String, dynamic> json) => MagneticSample(
        timestamp: DateTime.parse(json['timestamp'] as String),
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        z: (json['z'] as num).toDouble(),
      );

  double get magnitude => math.sqrt(x * x + y * y + z * z);

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'x': x,
        'y': y,
        'z': z,
        'magnitude': magnitude,
      };
}

class MagneticFingerprint {
  const MagneticFingerprint({
    required this.id,
    required this.floorId,
    required this.position,
    required this.capturedAt,
    required this.samples,
  });

  final String id;
  final String floorId;
  final Offset position;
  final DateTime capturedAt;
  final List<MagneticSample> samples;

  MagneticSample get representative => samples[samples.length ~/ 2];

  Map<String, dynamic> toJson() => {
        'id': id,
        'floorId': floorId,
        'x': position.dx,
        'y': position.dy,
        'capturedAt': capturedAt.toIso8601String(),
        'samples': samples.map((sample) => sample.toJson()).toList(),
      };
}

class MagneticMatch {
  const MagneticMatch({required this.position, required this.distance, required this.fingerprintId});

  final Offset position;
  final double distance;
  final String fingerprintId;
}

class MagneticTrajectory {
  const MagneticTrajectory({
    required this.id,
    required this.floorId,
    required this.capturedAt,
    required this.samples,
    required this.positions,
  });

  final String id;
  final String floorId;
  final DateTime capturedAt;
  final List<MagneticSample> samples;
  final List<Offset> positions;

  factory MagneticTrajectory.fromJson(Map<String, dynamic> json) {
    final rawPositions = json['positions'] as List<dynamic>;
    return MagneticTrajectory(
      id: json['id'] as String,
      floorId: json['floorId'] as String? ?? 'default-floor',
      capturedAt: DateTime.parse(json['capturedAt'] as String),
      samples: (json['samples'] as List<dynamic>).map((sample) => MagneticSample.fromJson(sample as Map<String, dynamic>)).toList(),
      positions: rawPositions.map((position) {
        final value = position as Map<String, dynamic>;
        return Offset((value['x'] as num).toDouble(), (value['y'] as num).toDouble());
      }).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'floorId': floorId,
        'capturedAt': capturedAt.toIso8601String(),
        'samples': samples.map((sample) => sample.toJson()).toList(),
        'positions': positions.map((position) => {'x': position.dx, 'y': position.dy}).toList(),
      };
}

class MagneticTrajectoryMatch {
  const MagneticTrajectoryMatch({required this.position, required this.distance, required this.trajectoryId, required this.confidence});

  final Offset position;
  final double distance;
  final String trajectoryId;
  final double confidence;
}