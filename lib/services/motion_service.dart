import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_compass/flutter_compass.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Tracks live motion for PDR (pedestrian dead reckoning): the OS step
/// counter (accelerometer-backed) reports how far each step covers, and a
/// gyroscope+compass fusion reports which way the phone is facing.
/// Direction of *travel* (as opposed to facing) is decided by
/// [NavigationController], which prefers the current route's direction
/// over raw heading whenever one is available.
///
/// PDR alone drifts over time — [NavigationController] periodically resets
/// the accumulated position back to a known beacon location whenever BLE
/// zone-snap fires a new fix, which is the "fusion" between the two.
class MotionService {
  MotionService({
    required this.metersPerUnit,
    required this.mapNorthOffsetDegrees,
    this.stepLengthMeters = 0.75,
  }) : _calibratedStepLengthMeters = stepLengthMeters;

  /// Real-world meters per one map/SVG coordinate unit (see [StoreMap]).
  final double metersPerUnit;

  /// Compass bearing (degrees, 0 = North) that corresponds to the map's
  /// "up" (-y) direction — used to rotate compass headings into map space.
  final double mapNorthOffsetDegrees;

  /// Assumed distance covered per step. A rough average adult stride;
  /// personalize/calibrate later if needed.
  final double stepLengthMeters;
  double _calibratedStepLengthMeters;
  final List<double> _strideSamples = [];

  double get calibratedStepLengthMeters => _calibratedStepLengthMeters;

  final _stepDistanceController = StreamController<double>.broadcast();
  final _headingController = StreamController<double>.broadcast();
  final _errorController = StreamController<String>.broadcast();

  StreamSubscription<StepCount>? _stepSub;
  StreamSubscription<CompassEvent>? _compassSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;

  int? _lastStepCount;
  double? _fusedHeadingDegrees;
  DateTime? _lastGyroTime;

  /// Distance walked (meters), one event per detected step — direction is
  /// deliberately not baked in here; the caller decides it (e.g. along the
  /// current route, or via [headingStream] when there's no route).
  Stream<double> get stepDistances => _stepDistanceController.stream;

  /// Live compass heading in degrees (0 = North), gyroscope-smoothed —
  /// updated independently of steps so the arrow can rotate even while
  /// standing still.
  Stream<double> get headingStream => _headingController.stream;

  /// Human-readable reasons motion tracking couldn't start — e.g. a denied
  /// permission or a missing sensor. Surfaced instead of failing silently,
  /// same reasoning as [BleScannerService.errors].
  Stream<String> get errors => _errorController.stream;

  Future<void> start() async {
    final status = await Permission.activityRecognition.request();
    if (!status.isGranted) {
      _errorController.add('Motion permission denied — step tracking disabled. Grant it in system settings.');
      return;
    }

    final compassEvents = FlutterCompass.events;
    if (compassEvents == null) {
      _errorController.add('Compass not available on this device.');
    } else {
      _compassSub = compassEvents.listen(_onCompass);
    }

    _gyroSub = gyroscopeEventStream().listen(
      _onGyro,
      onError: (Object e) => _errorController.add('Gyroscope error: $e'),
    );

    _stepSub = Pedometer.stepCountStream.listen(
      _onStepCount,
      onError: (Object e) => _errorController.add('Step counter error: $e'),
    );
  }

  void _onStepCount(StepCount event) {
    final last = _lastStepCount;
    _lastStepCount = event.steps;
    if (last == null) return; // First reading is just a baseline.

    final newSteps = event.steps - last;
    if (newSteps <= 0) return;

    for (var i = 0; i < newSteps; i++) {
      _stepDistanceController.add(_calibratedStepLengthMeters);
    }
  }

  /// Adds a measured beacon-to-beacon stride sample and applies the median of
  /// recent samples, which is less sensitive to a delayed or noisy beacon fix.
  void recordStrideCalibration({required double distanceMeters, required int steps}) {
    if (distanceMeters <= 0 || steps <= 0) return;
    _strideSamples.add(distanceMeters / steps);
    if (_strideSamples.length > 9) _strideSamples.removeAt(0);
    final sorted = List<double>.from(_strideSamples)..sort();
    _calibratedStepLengthMeters = sorted[sorted.length ~/ 2];
  }

  /// Integrates rotation rate into the fused heading — fires far more
  /// often than the compass (typically 50-200 Hz vs. a magnetometer's
  /// noisier, coarser updates), so turns show up immediately instead of
  /// waiting on the next compass sample. Drifts on its own over time,
  /// which [_onCompass] continuously corrects.
  void _onGyro(GyroscopeEvent event) {
    final now = DateTime.now();
    final last = _lastGyroTime;
    _lastGyroTime = now;
    final current = _fusedHeadingDegrees;
    if (last == null || current == null) return; // Need a compass fix to anchor to first.

    final dtSeconds = now.difference(last).inMicroseconds / 1e6;
    if (dtSeconds <= 0 || dtSeconds > 0.5) return; // Skip large gaps (e.g. app backgrounded).

    // event.z is rotation rate (rad/s) around the phone's vertical axis
    // when held flat, positive = counter-clockwise; compass heading
    // increases clockwise, hence the negation.
    final deltaDegrees = -event.z * dtSeconds * 180 / math.pi;
    _fusedHeadingDegrees = _wrapDegrees(current + deltaDegrees);
    _headingController.add(_fusedHeadingDegrees!);
  }

  /// Anchors/corrects the gyro-integrated heading against the compass's
  /// absolute (but noisier, indoors-near-metal-unreliable) reading —
  /// a small correction weight per event so gyro drift gets continuously
  /// reined in without reintroducing the compass's raw jumpiness.
  void _onCompass(CompassEvent event) {
    final heading = event.heading;
    if (heading == null) return;

    final current = _fusedHeadingDegrees;
    _fusedHeadingDegrees = current == null ? heading : _blendHeading(current, heading, weight: 0.08);
    _headingController.add(_fusedHeadingDegrees!);
  }

  /// Circular blend (handles the 0°/360° wraparound correctly by averaging
  /// in Cartesian/unit-vector space) — naively averaging e.g. 350° and 10°
  /// would otherwise give 180° instead of ~0°.
  double _blendHeading(double base, double correction, {required double weight}) {
    final baseRad = base * math.pi / 180;
    final correctionRad = correction * math.pi / 180;
    final x = (1 - weight) * math.cos(baseRad) + weight * math.cos(correctionRad);
    final y = (1 - weight) * math.sin(baseRad) + weight * math.sin(correctionRad);
    return _wrapDegrees(math.atan2(y, x) * 180 / math.pi);
  }

  double _wrapDegrees(double degrees) => (degrees % 360 + 360) % 360;

  void stop() {
    _stepSub?.cancel();
    _stepSub = null;
    _compassSub?.cancel();
    _compassSub = null;
    _gyroSub?.cancel();
    _gyroSub = null;
  }

  void dispose() {
    stop();
    _stepDistanceController.close();
    _headingController.close();
    _errorController.close();
  }
}
