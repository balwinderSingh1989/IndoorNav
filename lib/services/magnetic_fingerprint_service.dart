import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as dart_ui;

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../models/magnetic_fingerprint.dart';

/// Owns magnetometer observations and fingerprint storage. It has no map,
/// beacon, or routing dependency; callers provide the label for each capture.
class MagneticFingerprintService {
  MagneticFingerprintService({this.sampleInterval = const Duration(milliseconds: 100)});

  final Duration sampleInterval;
  final _sampleController = StreamController<MagneticSample>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final List<MagneticFingerprint> fingerprints = [];
  final List<MagneticTrajectory> trajectories = [];
  final Map<String, List<({double magnitude, double change, double curvature})>> _featureCache = {};
  bool _loaded = false;
  StreamSubscription<MagnetometerEvent>? _sensorSub;
  DateTime? _lastSampleAt;

  Stream<MagneticSample> get samples => _sampleController.stream;
  Stream<String> get errors => _errorController.stream;
  List<MagneticTrajectory> get surveyTrajectories => List.unmodifiable(trajectories);

  dart_ui.Offset constrainToCoverage(dart_ui.Offset proposed, {dart_ui.Offset? anchorPosition, double radiusMapUnits = 60}) {
    final candidates = <dart_ui.Offset>[];
    for (final trajectory in trajectories) {
      for (final position in trajectory.positions) {
        if (anchorPosition == null || (position - anchorPosition).distance <= radiusMapUnits) candidates.add(position);
      }
    }
    if (candidates.isEmpty) return proposed;
    return candidates.reduce((a, b) => (a - proposed).distanceSquared <= (b - proposed).distanceSquared ? a : b);
  }

  Future<void> start() async {
    await _sensorSub?.cancel();
    _sensorSub = magnetometerEventStream().listen(
      (event) {
        final now = DateTime.now();
        if (_lastSampleAt != null && now.difference(_lastSampleAt!) < sampleInterval) return;
        _lastSampleAt = now;
        _sampleController.add(MagneticSample(timestamp: now, x: event.x, y: event.y, z: event.z));
      },
      onError: (Object error) => _errorController.add('Magnetometer error: $error'),
    );
  }

  Future<void> stop() async {
    await _sensorSub?.cancel();
    _sensorSub = null;
  }

  void addFingerprint({required String floorId, required dart_ui.Offset position, required List<MagneticSample> samples}) {
    if (samples.isEmpty) return;
    fingerprints.add(MagneticFingerprint(
      id: 'mag-${DateTime.now().microsecondsSinceEpoch}',
      floorId: floorId,
      position: position,
      capturedAt: DateTime.now(),
      samples: List.unmodifiable(samples),
    ));
  }

  void addTrajectory({required String floorId, required List<MagneticSample> samples, required List<dart_ui.Offset> positions}) {
    if (samples.length < 8) {
      _errorController.add('Magnetic trajectory rejected: capture at least 8 samples.');
      return;
    }
    if (samples.length != positions.length) {
      _errorController.add('Magnetic trajectory rejected: samples and positions do not align.');
      return;
    }
    final trajectory = MagneticTrajectory(
      id: 'path-${DateTime.now().microsecondsSinceEpoch}',
      floorId: floorId,
      capturedAt: DateTime.now(),
      samples: List.unmodifiable(samples),
      positions: List.unmodifiable(positions),
    );
    trajectories.add(trajectory);
    _featureCache[trajectory.id] = _magneticFeatures(trajectory.samples);
  }

  MagneticMatch? match(MagneticSample live) {
    if (fingerprints.isEmpty) return null;
    MagneticFingerprint? best;
    var bestDistance = double.infinity;
    for (final fingerprint in fingerprints) {
      final reference = fingerprint.representative;
      final distance = math.sqrt(
        math.pow(live.x - reference.x, 2) +
            math.pow(live.y - reference.y, 2) +
            math.pow(live.z - reference.z, 2),
      );
      if (distance < bestDistance) {
        bestDistance = distance;
        best = fingerprint;
      }
    }
    return best == null ? null : MagneticMatch(position: best.position, distance: bestDistance, fingerprintId: best.id);
  }

  MagneticTrajectoryMatch? matchSequence(
    List<MagneticSample> liveSamples, {
    dart_ui.Offset? previousPosition,
    dart_ui.Offset? anchorPosition,
    double anchorRadiusMapUnits = 60,
  }) {
    if (liveSamples.length < 8 || trajectories.isEmpty) return null;
    MagneticTrajectory? best;
    var bestDistance = double.infinity;
    var secondBestDistance = double.infinity;
    var bestIndex = 0;
    for (final trajectory in trajectories) {
      final result = _dtw(liveSamples, _featuresFor(trajectory));
      final candidatePosition = trajectory.positions[result.referenceIndex.clamp(0, trajectory.positions.length - 1)];
      final anchorDistance = anchorPosition == null ? 0.0 : (candidatePosition - anchorPosition).distance;
      if (anchorPosition != null && anchorDistance > anchorRadiusMapUnits) continue;
      final jump = previousPosition == null ? 0.0 : (candidatePosition - previousPosition).distance;
      if (previousPosition != null && jump > _maxReachableMagneticJumpMapUnits) {
        continue;
      }
      // A rolling window advances gradually. A large endpoint jump is a poor
      // hypothesis even when its magnetic sequence happens to look similar.
      final continuityPenalty = previousPosition == null ? 0.0 : math.pow(jump / _continuityJumpMapUnits, 2).toDouble();
      final scoredDistance = result.distance + continuityPenalty;
      if (scoredDistance < bestDistance) {
        secondBestDistance = bestDistance;
        bestDistance = scoredDistance;
        best = trajectory;
        bestIndex = result.referenceIndex;
      } else if (scoredDistance < secondBestDistance) {
        secondBestDistance = scoredDistance;
      }
    }
    if (best == null) return null;
    final separation = secondBestDistance.isFinite
        ? ((secondBestDistance - bestDistance) / math.max(secondBestDistance, 0.001)).clamp(0.0, 1.0)
        : 1.0;
    return MagneticTrajectoryMatch(
      position: best.positions[bestIndex.clamp(0, best.positions.length - 1)],
      distance: bestDistance,
      trajectoryId: best.id,
      confidence: (0.55 * (1 / (1 + bestDistance)) + 0.45 * separation).clamp(0.0, 1.0),
    );
  }

  Future<void> loadPersisted() async {
    if (_loaded) return;
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/magnetic-fingerprints.json');
      if (!await file.exists()) {
        _loaded = true;
        return;
      }
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final entries = (json['trajectories'] as List<dynamic>? ?? const []);
      trajectories
        ..clear()
        ..addAll(entries.map((entry) => MagneticTrajectory.fromJson(entry as Map<String, dynamic>)));
      for (final trajectory in trajectories) {
        _featureCache[trajectory.id] = _magneticFeatures(trajectory.samples);
      }
      final points = (json['fingerprints'] as List<dynamic>? ?? const []);
      fingerprints
        ..clear()
        ..addAll(points.map((entry) {
        final value = entry as Map<String, dynamic>;
        final rawSamples = (value['samples'] as List<dynamic>? ?? const [])
            .map((sample) => MagneticSample.fromJson(sample as Map<String, dynamic>))
            .toList();
        return MagneticFingerprint(
          id: value['id'] as String,
          floorId: value['floorId'] as String? ?? 'default-floor',
          position: dart_ui.Offset((value['x'] as num).toDouble(), (value['y'] as num).toDouble()),
          capturedAt: DateTime.parse(value['capturedAt'] as String),
          samples: rawSamples,
        );
        }));
      _loaded = true;
    } catch (error) {
      _errorController.add('Magnetic fingerprints could not be loaded: $error');
    }
  }

  Future<int> importJson(String contents) async {
    final json = jsonDecode(contents) as Map<String, dynamic>;
    final trajectoriesJson = json['trajectories'] as List<dynamic>? ?? const [];
    final pointsJson = json['fingerprints'] as List<dynamic>? ?? const [];
    trajectories.addAll(trajectoriesJson.map((entry) => MagneticTrajectory.fromJson(entry as Map<String, dynamic>)));
    for (final trajectory in trajectories) {
      _featureCache[trajectory.id] = _magneticFeatures(trajectory.samples);
    }
    fingerprints.addAll(pointsJson.map((entry) {
      final value = entry as Map<String, dynamic>;
      return MagneticFingerprint(
        id: value['id'] as String,
        floorId: value['floorId'] as String? ?? 'default-floor',
        position: dart_ui.Offset((value['x'] as num).toDouble(), (value['y'] as num).toDouble()),
        capturedAt: DateTime.parse(value['capturedAt'] as String),
        samples: (value['samples'] as List<dynamic>? ?? const [])
            .map((sample) => MagneticSample.fromJson(sample as Map<String, dynamic>))
            .toList(),
      );
    }));
    return trajectoriesJson.length + pointsJson.length;
  }

  static const double _continuityJumpMapUnits = 35.0;
  static const double _maxReachableMagneticJumpMapUnits = 90.0;

  ({double distance, int referenceIndex}) _dtw(
    List<MagneticSample> live,
    List<({double magnitude, double change, double curvature})> reference,
  ) {
    final liveValues = _magneticFeatures(live);
    // Open-begin subsequence DTW: every reference index may be the start of
    // the live window, so no index-based Sakoe-Chiba band is applied here.
    var previous = List<double>.filled(reference.length + 1, 0);
    var current = List<double>.filled(reference.length + 1, double.infinity);
    final endReferenceCosts = <int, double>{};
    for (var i = 1; i <= live.length; i++) {
      current = List<double>.filled(reference.length + 1, double.infinity);
      current[0] = 0;
      for (var j = 1; j <= reference.length; j++) {
        final liveFeature = liveValues[i - 1];
        final referenceFeature = reference[j - 1];
        final cost = 0.55 * (liveFeature.magnitude - referenceFeature.magnitude).abs() +
          0.30 * (liveFeature.change - referenceFeature.change).abs() +
            0.15 * (liveFeature.curvature - referenceFeature.curvature).abs();
        current[j] = cost + math.min(previous[j], math.min(current[j - 1], previous[j - 1]));
      }
      if (i == live.length) {
        for (var j = 1; j <= reference.length; j++) {
          endReferenceCosts[j] = current[j];
        }
      }
      previous = current;
    }
    final best = endReferenceCosts.entries.reduce((a, b) => a.value <= b.value ? a : b);
    return (distance: best.value / (live.length + best.key), referenceIndex: best.key - 1);
  }

  List<({double magnitude, double change, double curvature})> _magneticFeatures(List<MagneticSample> samples) {
    final magnitudes = samples.map((sample) => sample.magnitude).toList();
    final changes = List<double>.generate(magnitudes.length, (index) => index == 0 ? 0 : magnitudes[index] - magnitudes[index - 1]);
    final curvatures = List<double>.generate(changes.length, (index) => index == 0 ? 0 : changes[index] - changes[index - 1]);
    double normalize(double value, List<double> values) {
      final mean = values.reduce((a, b) => a + b) / values.length;
      final variance = values.map((item) => math.pow(item - mean, 2)).reduce((a, b) => a + b) / values.length;
      return (value - mean) / math.sqrt(variance).clamp(1.0, double.infinity);
    }
    return List.generate(samples.length, (index) {
      final magnitude = magnitudes[index];
      return (
        magnitude: normalize(magnitude, magnitudes),
        change: normalize(changes[index], changes),
        curvature: normalize(curvatures[index], curvatures),
      );
    });
  }

  List<({double magnitude, double change, double curvature})> _featuresFor(MagneticTrajectory trajectory) {
    return _featureCache.putIfAbsent(trajectory.id, () => _magneticFeatures(trajectory.samples));
  }

  Future<String> exportJson() async {
    if (trajectories.isEmpty && fingerprints.isEmpty) {
      throw StateError('No magnetic fingerprints captured. Export cancelled.');
    }
    final payload = const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'type': 'magnetic-fingerprint-session',
      'createdAt': DateTime.now().toIso8601String(),
      'fingerprints': fingerprints.map((fingerprint) => fingerprint.toJson()).toList(),
      'trajectories': trajectories.map((trajectory) => trajectory.toJson()).toList(),
    });
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/magnetic-fingerprints.json');
    await file.writeAsString(payload);
    await Clipboard.setData(ClipboardData(text: payload));
    return file.path;
  }

  Future<void> dispose() async {
    await stop();
    await _sampleController.close();
    await _errorController.close();
  }
}