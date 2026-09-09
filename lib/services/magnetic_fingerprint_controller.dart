import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import '../models/magnetic_fingerprint.dart';
import '../models/store_map.dart';
import 'magnetic_fingerprint_service.dart';
import 'motion_service.dart';

class MagneticFingerprintController extends ChangeNotifier {
  MagneticFingerprintController({required this.storeMap, required this.service, this.motionService}) {
    _sampleSub = service.samples.listen(_onSample);
    _errorSub = service.errors.listen((message) {
      errorMessage = message;
      notifyListeners();
    });
    if (motionService != null) {
      _stepSub = motionService!.stepDistances.listen(_onStep);
      _headingSub = motionService!.headingStream.listen((heading) {
        currentHeadingDegrees = heading;
        notifyListeners();
      });
      _motionErrorSub = motionService!.errors.listen((message) {
        errorMessage = message;
        notifyListeners();
      });
    }
  }

  final StoreMap storeMap;
  final MagneticFingerprintService service;
  final MotionService? motionService;
  StreamSubscription<MagneticSample>? _sampleSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<double>? _stepSub;
  StreamSubscription<double>? _headingSub;
  StreamSubscription<String>? _motionErrorSub;
  Timer? _captureTimer;
  final List<MagneticSample> _captureSamples = [];
  final List<MagneticSample> _liveSamples = [];
  final List<Offset> routePoints = [];
  Offset? _pdrPosition;
  Offset? _lastAppliedAnchor;
  int _samplesSinceMagneticCorrection = 0;

  MagneticSample? latestSample;
  MagneticMatch? currentMatch;
  MagneticTrajectoryMatch? currentTrajectoryMatch;
  Offset? estimatedPosition;
  Offset? pendingCapturePosition;
  bool isCapturing = false;
  String? errorMessage;
  double? currentHeadingDegrees;
  Offset? anchorPosition;
  double anchorConfidence = 0;
  int capturedStepCount = 0;
  double capturedStepDistanceMeters = 0;

  bool get isBeaconConfident => anchorConfidence >= 0.60;
  bool get isBeaconAmbiguous => anchorConfidence >= 0.35 && anchorConfidence < 0.60;

  int get fingerprintCount => service.fingerprints.length;
  int get trajectoryCount => service.trajectories.length;
  int get captureSampleCount => _captureSamples.length;
  int get liveSequenceSampleCount => _liveSamples.length;

  Future<void> start() async {
    await service.loadPersisted();
    await service.start();
    await motionService?.start();
  }

  void _onStep(double distanceMeters) {
    if (isCapturing) {
      capturedStepCount++;
      capturedStepDistanceMeters += distanceMeters;
    }
    final base = _pdrPosition ?? estimatedPosition;
    final heading = currentHeadingDegrees;
    if (base == null || heading == null) return;
    final radians = (heading - storeMap.mapNorthOffsetDegrees) * math.pi / 180;
    final distanceUnits = distanceMeters / storeMap.metersPerUnit;
    final proposed = base + Offset(math.sin(radians) * distanceUnits, -math.cos(radians) * distanceUnits);
    final graphSnapped = storeMap.snapToGraph(proposed).point;
    final snapped = service.constrainToCoverage(
      graphSnapped,
      anchorPosition: anchorConfidence >= 0.35 ? anchorPosition : null,
    );
    _pdrPosition = snapped;
    estimatedPosition = snapped;
    notifyListeners();
  }

  /// Receives a coarse fix from an external anchor provider. In the final
  /// design, beacon RSSI is authoritative and magnetic is only a tie-breaker
  /// when the beacon is ambiguous.
  void updateAnchor(Offset position, {double confidence = 1}) {
    final normalizedConfidence = confidence.clamp(0.0, 1.0);
    final anchorMoved = _lastAppliedAnchor == null || (_lastAppliedAnchor! - position).distance >= 12;
    anchorPosition = position;
    anchorConfidence = normalizedConfidence;

    final firstAnchor = _lastAppliedAnchor == null && normalizedConfidence >= 0.35;
    final confidentReset = normalizedConfidence >= 0.60 && anchorMoved;
    if (firstAnchor || confidentReset) {
      estimatedPosition = position;
      _pdrPosition = position;
      _lastAppliedAnchor = position;
    } else if (normalizedConfidence < 0.35) {
      anchorPosition = null;
      _lastAppliedAnchor = null;
    }
    notifyListeners();
  }

  void selectCapturePoint(Offset position) {
    if (isCapturing) return;
    pendingCapturePosition = position;
    notifyListeners();
  }

  void addRoutePoint(Offset position) {
    if (isCapturing) return;
    routePoints.add(position);
    notifyListeners();
  }

  void removeLastRoutePoint() {
    if (routePoints.isEmpty || isCapturing) return;
    routePoints.removeLast();
    notifyListeners();
  }

  void clearRoute() {
    if (isCapturing) return;
    routePoints.clear();
    notifyListeners();
  }

  void _onSample(MagneticSample sample) {
    latestSample = sample;
    if (isCapturing) _captureSamples.add(sample);
    _liveSamples.add(sample);
    if (_liveSamples.length > 80) _liveSamples.removeAt(0);
    _samplesSinceMagneticCorrection++;

    final lastKnownPosition = _pdrPosition ?? estimatedPosition;
    final shouldUseMagneticTieBreak = isBeaconAmbiguous && anchorPosition != null && lastKnownPosition != null;

    if (_samplesSinceMagneticCorrection >= 8 && shouldUseMagneticTieBreak) {
      _samplesSinceMagneticCorrection = 0;
      final trajectoryMatch = service.matchSequence(
        _liveSamples,
        previousPosition: lastKnownPosition,
        anchorPosition: anchorPosition,
      );
      if (trajectoryMatch != null && trajectoryMatch.confidence >= 0.35) {
        currentTrajectoryMatch = trajectoryMatch;
        final base = lastKnownPosition;
        final candidatePosition = trajectoryMatch.position;
        final reachable = (candidatePosition - base).distance <= 140;
        if (reachable) {
          estimatedPosition = Offset.lerp(base, candidatePosition, 0.25);
          _pdrPosition = estimatedPosition;
        }
      } else {
        currentTrajectoryMatch = null;
      }
    } else {
      currentTrajectoryMatch = null;
    }

    // A confident beacon reading is authoritative. Magnetic mismatches must
    // never override it, even when a trajectory fits the signatures.
    final match = service.match(sample);
    if (match != null && service.trajectories.isEmpty && !isBeaconConfident) {
      currentMatch = match;
      estimatedPosition = match.position;
    } else if (isBeaconConfident) {
      currentMatch = null;
    }
    notifyListeners();
  }

  void beginCapture(Offset position) {
    if (isCapturing) return;
    pendingCapturePosition = position;
    _captureSamples.clear();
    isCapturing = true;
    errorMessage = null;
    _captureTimer = Timer(const Duration(seconds: 5), finishCapture);
    notifyListeners();
  }

  void beginWalkingCapture() {
    if (isCapturing || routePoints.length < 2) return;
    pendingCapturePosition = null;
    _captureSamples.clear();
    capturedStepCount = 0;
    capturedStepDistanceMeters = 0;
    isCapturing = true;
    errorMessage = null;
    notifyListeners();
  }

  void finishWalkingCapture() {
    if (!isCapturing || routePoints.length < 2) return;
    final samples = List<MagneticSample>.from(_captureSamples);
    if (capturedStepCount < 2) {
      errorMessage = 'Magnetic trajectory rejected: no walking steps detected.';
      isCapturing = false;
      _captureSamples.clear();
      notifyListeners();
      return;
    }
    service.addTrajectory(
      floorId: 'default-floor',
      samples: samples,
      positions: _positionsAlongRoute(samples.length),
    );
    isCapturing = false;
    _captureSamples.clear();
    notifyListeners();
  }

  List<Offset> _positionsAlongRoute(int count) {
    final lengths = <double>[0];
    for (var i = 1; i < routePoints.length; i++) {
      lengths.add(lengths.last + (routePoints[i] - routePoints[i - 1]).distance);
    }
    final total = lengths.last;
    if (total == 0) return List<Offset>.filled(count, routePoints.first);
    return List.generate(count, (index) {
      final distance = total * (count == 1 ? 0 : index / (count - 1));
      var segment = 1;
      while (segment < lengths.length - 1 && lengths[segment] < distance) {
        segment++;
      }
      final startDistance = lengths[segment - 1];
      final fraction = (distance - startDistance) / (lengths[segment] - startDistance);
      return Offset.lerp(routePoints[segment - 1], routePoints[segment], fraction)!;
    });
  }

  void cancelCapturePoint() {
    if (isCapturing) return;
    pendingCapturePosition = null;
    notifyListeners();
  }

  void finishCapture() {
    if (!isCapturing) return;
    _captureTimer?.cancel();
    _captureTimer = null;
    final position = pendingCapturePosition;
    if (position != null && _captureSamples.isNotEmpty) {
      service.addFingerprint(floorId: 'default-floor', position: position, samples: _captureSamples);
    }
    isCapturing = false;
    pendingCapturePosition = null;
    _captureSamples.clear();
    notifyListeners();
  }

  void clearFingerprints() {
    service.fingerprints.clear();
    service.trajectories.clear();
    currentMatch = null;
    currentTrajectoryMatch = null;
    estimatedPosition = null;
    notifyListeners();
  }

  Future<String> export() => service.exportJson();

  Future<int> importJson(String contents) async {
    final count = await service.importJson(contents);
    notifyListeners();
    return count;
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    _sampleSub?.cancel();
    _errorSub?.cancel();
    _stepSub?.cancel();
    _headingSub?.cancel();
    _motionErrorSub?.cancel();
    service.dispose();
    motionService?.dispose();
    super.dispose();
  }
}