import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:dchs_flutter_beacon/dchs_flutter_beacon.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

import '../observations/beacon_observation_source.dart';

class _TimedRssi {
  final DateTime time;
  final int rssi;
  _TimedRssi(this.time, this.rssi);
}

/// Kalman filter state for a single beacon's RSSI tracking.
/// Estimates the true RSSI value given noisy measurements.
class _BeaconKalmanState {
  double estimate = -70.0; // Initial estimate (typical indoor RSSI)
  double estimateError; // Initial estimate error (in dB)
  double measurementError; // Measurement noise (in dB) — tunable
  double
      processNoise; // Process noise — how much signal can drift between readings

  _BeaconKalmanState({
    this.estimateError = 2.0,
    this.measurementError = 1.5,
    this.processNoise = 0.01,
  });

  /// Update the Kalman filter with a new RSSI measurement.
  /// Returns the updated estimate.
  double update(double measurement) {
    // Prediction phase: estimate stays same, error increases due to process noise
    final predictedError = estimateError + processNoise;

    // Update phase: Kalman gain tells us how much to trust the measurement
    final kalmanGain = predictedError / (predictedError + measurementError);

    // New estimate = old estimate + gain * (measurement - estimate)
    estimate = estimate + kalmanGain * (measurement - estimate);
    estimateError = (1.0 - kalmanGain) * predictedError;

    return estimate;
  }
}

enum RssiFilterMode {
  median,
  kalman,
  both, // Run both in parallel for testing/comparison
}

class BeaconScanInfo {
  const BeaconScanInfo({
    required this.key,
    required this.scannerId,
    required this.name,
    required this.rssi,
    required this.lastSeen,
  });

  final String key;
  final String scannerId;
  final String name;
  final double rssi;
  final DateTime lastSeen;

  BeaconScanInfo copyWith({double? rssi}) => BeaconScanInfo(
        key: key,
        scannerId: scannerId,
        name: name,
        rssi: rssi ?? this.rssi,
        lastSeen: lastSeen,
      );
}

/// Scans for nearby beacons and emits a rolling average RSSI per beacon
/// identity. Consumers (see [ZoneSnapService]) turn this into a location.
///
/// A beacon's identity is derived in [_onDeviceSeen], preferring (in order):
/// 1. MAC-to-beacon mapping for configured store beacons.
/// 2. iBeacon proximity UUID parsed from manufacturer data.
/// Never [DiscoveredDevice.id] — that's the scanning radio's own address
/// (a MAC on Android), unrelated to how a beacon identifies itself.
///
/// NOTE on iOS: [DiscoveredDevice.id] is a per-app, potentially-rotating
/// CoreBluetooth identifier on iOS, never a real MAC address — the
/// [_debugTargetMacToKey] table below can only ever match on Android. On
/// iOS every beacon must resolve through iBeacon manufacturer-data parsing.
///
/// This service is self-healing against silent scan failures: a stalled
/// or closed scan stream, a Bluetooth adapter toggle, or an OS-level scan
/// throttle would otherwise look identical to "no beacons nearby" with no
/// error surfaced — see [_statusSub], the scan subscription's `onDone`,
/// and [_watchdogTimer].
class BleScannerService implements BeaconObservationSource {
  BleScannerService({
    FlutterReactiveBle? ble,
    // INDOOR TUNING (Sept 28):
    // Rolling window reduced from 1800ms → 1000ms for fast 4-5m beacon transitions.
    // At ~25-30 Hz scan rate, still get 25-30 samples for smoothing.
    // Shorter window = detects zone changes ~40% faster while maintaining noise rejection.
    this.rollingWindow = const Duration(milliseconds: 1000),
    this.filterMode = RssiFilterMode.both,
    this.enableComparisonLogging = true,
    // Kalman tuning parameters (INDOOR OPTIMIZED Sept 28):
    // measurementError 1.5 → 1.0: Trust BLE readings more, faster response (~25% improvement)
    // processNoise 0.01 → 0.04: Model expects more signal change (short distances, multipath)
    // initialError 2.0 → 2.5: Start less confident for faster initial adaptation
    this.kalmanMeasurementError = 1.0,
    this.kalmanProcessNoise = 0.04,
    this.kalmanInitialError = 2.5,
    this.staleBeaconTimeout = const Duration(seconds: 5),
    this.staleSweepInterval = const Duration(seconds: 2),
    this.watchdogNoDeviceThreshold = const Duration(seconds: 10),
    this.watchdogCheckInterval = const Duration(seconds: 5),
    this.enableDiagnosticLogging = true,
    this.iosProximityUuids = const [],
  }) : _ble = ble;

  FlutterReactiveBle? _ble;
  final Duration rollingWindow;
  final RssiFilterMode filterMode;
  final bool enableComparisonLogging;

  /// Kalman filter tuning parameters (can be adjusted per environment)
  final double kalmanMeasurementError;
  final double kalmanProcessNoise;
  final double kalmanInitialError;
  final Duration staleBeaconTimeout;
  final Duration staleSweepInterval;
  final Duration watchdogNoDeviceThreshold;
  final Duration watchdogCheckInterval;
  final bool enableDiagnosticLogging;
  final List<String> iosProximityUuids;

  /// Per-beacon Kalman filter states for RSSI estimation
  final Map<String, _BeaconKalmanState> _kalmanStates = {};

  /// Beacon names by BLE key (e.g. "uuid:major:minor" -> "Safari")
  /// Populated from StoreMap.beacons at initialization
  final Map<String, String> _beaconNamesByKey = {};

  /// How long a beacon can go unseen before its last-known reading is
  /// pruned and it disappears from [rssiStream]/[scanInfoStream]. Without
  /// this, a beacon that drops out of range keeps reporting its last
  /// (increasingly stale) RSSI forever, since [_readings] is only pruned
  /// reactively — inside [_onDeviceSeen], which stops running for that key
  /// the moment it stops being detected.

  /// If no device of any kind has been seen for this long while the
  /// adapter reports ready, treat the scan as silently stalled and
  /// restart it. This is the backstop for failure modes that produce
  /// neither an error nor a stream-done event — a known flakiness pattern
  /// on some Android BLE stacks/OEMs.

  /// Initialize beacon name lookup from store data.
  /// Call this before scanning to ensure proper names in logs.
  void setBeaconNameLookup(Map<String, String> namesByKey) {
    _beaconNamesByKey.addAll(namesByKey);
  }

  /// Reset all Kalman filter states (useful after tuning parameter changes).
  /// This clears accumulated filter state for fresh estimation.
  void resetKalmanStates() {
    _kalmanStates.clear();
    print('[BLE] Kalman states reset for all beacons');
  }

  static const _debugTargetMacToKey = {
    'c300001318cb': 'e2c56db5-dffb-48d2-b060-d0f5a71096e0:0:0',
    'c300001318ba': 'e2c56db5-dffb-48d2-b060-d0f5a71096e1:0:1',
    'c300001318c3': 'e2c56db5-dffb-48d2-b060-d0f5a71096e2:0:2',
    'c300001318b9': 'e2c56db5-dffb-48d2-b060-d0f5a71096e3:0:3',
    'c300001318c4': 'e2c56db5-dffb-48d2-b060-d0f5a71096e4:0:4',
    'c300001318c5': 'e2c56db5-dffb-48d2-b060-d0f5a71096e5:0:5',
    'c300001318c8': 'e2c56db5-dffb-48d2-b060-d0f5a71096e6:0:6',
    'c300001318c9': 'e2c56db5-dffb-48d2-b060-d0f5a71096e7:0:7',
  };

  final Map<String, List<_TimedRssi>> _readings = {};
  final Map<String, BeaconScanInfo> _scanInfoByKey = {};
  final _rssiController = StreamController<Map<String, double>>.broadcast();
  final _scanInfoController =
      StreamController<List<BeaconScanInfo>>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<RangingResult>? _iosRangingSub;
  StreamSubscription<BleStatus>? _statusSub;
  Timer? _staleSweepTimer;
  Timer? _watchdogTimer;
  DateTime? _lastObservationAt;
  bool _restarting = false;
  bool _disposed = false;
  Future<void>? _startOperation;
  List<BeaconScanInfo> _latestScanInfo = const [];

  /// Averaged RSSI per beacon identity ("uuid:major:minor"), updated on
  /// every scan result.
  Stream<Map<String, double>> get rssiStream => _rssiController.stream;

  Stream<List<BeaconScanInfo>> get scanInfoStream => _scanInfoController.stream;

  List<BeaconScanInfo> get latestScanInfo => List.unmodifiable(_latestScanInfo);

  /// Human-readable reasons scanning couldn't start or was interrupted —
  /// e.g. a denied permission or disabled Bluetooth adapter. Surfaced here
  /// instead of failing silently, since a scan that finds nothing looks
  /// identical to a scan that never started.
  Stream<String> get errors => _errorController.stream;

  Future<void> startScan() async {
    if (_disposed) return;
    final activeStart = _startOperation;
    if (activeStart != null) return activeStart;

    late final Future<void> operation;
    operation = _startScanInternal();
    _startOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_startOperation, operation)) _startOperation = null;
    }
  }

  Future<void> _startScanInternal() async {
    _diagnostic(
      'startScan platform=${Platform.operatingSystem} '
      'filter=$filterMode rollingWindow=${rollingWindow.inMilliseconds}ms',
    );
    if (_ble == null && (Platform.isAndroid || Platform.isIOS)) {
      _ble = FlutterReactiveBle();
    }
    if (_ble == null) {
      _diagnostic('scan not started: FlutterReactiveBle instance is null');
      return;
    }

    if (Platform.isIOS) {
      await _startIosBeaconRanging();
      return;
    }

    final permissionError = await _ensurePermissions();
    if (permissionError != null) {
      _diagnostic('scan not started: $permissionError');
      _errorController.add(permissionError);
      return;
    }

    // Cancel any previous subscriptions/timers before re-establishing —
    // this method doubles as the restart path (see _restartScan), so it
    // must be safe to call repeatedly without stacking duplicates.
    await _scanSub?.cancel();
    await _statusSub?.cancel();
    _staleSweepTimer?.cancel();
    _watchdogTimer?.cancel();

    _statusSub = _ble!.statusStream.listen((status) {
      _diagnostic('adapter status=$status');
      if (status != BleStatus.ready) {
        _errorController.add('Bluetooth adapter not ready: $status');
        return;
      }
      // Adapter just became ready (e.g. user re-enabled Bluetooth) and
      // we're not actively scanning — resume.
      if (_scanSub == null && !_restarting) {
        startScan();
      }
    });

    if (_ble!.status != BleStatus.ready) {
      _diagnostic(
        'waiting for Android adapter readiness status=${_ble!.status}',
      );
      try {
        await _ble!.statusStream
            .firstWhere((status) => status == BleStatus.ready)
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        final status = _ble!.status;
        _diagnostic('Android adapter did not become ready status=$status');
        _errorController.add('Bluetooth adapter is not ready: $status');
        return;
      }
    }

    // lowLatency maximizes scan duty cycle (vs the balanced/lowPower
    // defaults), which matters for beacons with a sparse advertising
    // interval — nRF Connect and similar dedicated scanner apps tend to
    // scan more aggressively by default, which is why they can see a
    // beacon a lower-duty-cycle scan mode would miss.
    _scanSub = _ble!
        .scanForDevices(withServices: [], scanMode: ScanMode.lowLatency).listen(
      _onDeviceSeen,
      onError: (Object e) {
        _diagnostic('scan stream error=$e');
        _errorController.add('BLE scan error: $e — restarting scan.');
        _restartScan();
      },
      onDone: () {
        _diagnostic('scan stream done; restarting scan');
        // The scan stream closed without an error — this happens on
        // some Android adapters/OEMs after a silent internal reset.
        // Treated the same as an error: restart rather than leave
        // scanning permanently stopped with no signal that it happened.
        _errorController
            .add('BLE scan stream ended unexpectedly — restarting scan.');
        _restartScan();
      },
    );

    _lastObservationAt = DateTime.now();
    _diagnostic('scan subscription active; waiting for discovered devices');
    _staleSweepTimer =
        Timer.periodic(staleSweepInterval, (_) => _pruneStaleReadings());
    _watchdogTimer =
        Timer.periodic(watchdogCheckInterval, (_) => _checkScanHealth());
  }

  Future<void> _restartScan() async {
    if (_disposed || _restarting)
      return; // avoid overlapping restarts if multiple signals fire close together
    _restarting = true;
    try {
      await _scanSub?.cancel();
      _scanSub = null;
      await _iosRangingSub?.cancel();
      _iosRangingSub = null;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await startScan();
    } finally {
      _restarting = false;
    }
  }

  Future<void> _startIosBeaconRanging() async {
    if (iosProximityUuids.isEmpty) {
      const message =
          'iOS beacon ranging not started: no proximity UUID configured.';
      _diagnostic(message);
      _errorController.add(message);
      return;
    }

    await _scanSub?.cancel();
    _scanSub = null;
    await _iosRangingSub?.cancel();
    _iosRangingSub = null;
    _staleSweepTimer?.cancel();
    _watchdogTimer?.cancel();

    try {
      await flutterBeacon.setLocationAuthorizationTypeDefault(
        AuthorizationStatus.whenInUse,
      );

      var authorizationStatus = await flutterBeacon.authorizationStatus;
      _diagnostic('iOS location authorization status=$authorizationStatus');
      if (authorizationStatus == AuthorizationStatus.notDetermined) {
        final requested = await flutterBeacon.requestAuthorization;
        _diagnostic('iOS location authorization requested=$requested');
        authorizationStatus = await flutterBeacon.authorizationStatus;
        _diagnostic(
          'iOS location authorization status after request=$authorizationStatus',
        );
      }
      if (authorizationStatus == AuthorizationStatus.denied ||
          authorizationStatus == AuthorizationStatus.restricted) {
        _errorController.add(
          'iOS location permission is $authorizationStatus. Enable Location Services for this app in Settings.',
        );
        return;
      }

      final bluetoothState = await flutterBeacon.bluetoothState;
      final locationServicesEnabled =
          await flutterBeacon.checkLocationServicesIfEnabled;
      _diagnostic(
        'iOS readiness bluetooth=$bluetoothState '
        'locationServicesEnabled=$locationServicesEnabled',
      );
      if (bluetoothState != BluetoothState.stateOn) {
        _errorController.add(
          'iOS Bluetooth is $bluetoothState. Turn on Bluetooth and try again.',
        );
        return;
      }
      if (!locationServicesEnabled) {
        _errorController.add(
          'iOS Location Services are disabled. Enable them in Settings.',
        );
        return;
      }

      final initialized = await flutterBeacon.initializeScanning;
      _diagnostic(
        'iOS CoreLocation ranging initialized=$initialized '
        'uuids=${iosProximityUuids.join(',')}',
      );
      if (!initialized) {
        _errorController.add(
          'iOS beacon ranging could not initialize. Enable Bluetooth and Location Services.',
        );
        return;
      }

      final regions = iosProximityUuids
          .toSet()
          .map(
            (uuid) => Region(
              identifier: 'indoor-nav-${uuid.toLowerCase()}',
              proximityUUID: uuid,
            ),
          )
          .toList(growable: false);
      _iosRangingSub = flutterBeacon.ranging(regions).listen(
        _onIosRangingResult,
        onError: (Object error) {
          _diagnostic('iOS CoreLocation ranging error=$error');
          _errorController.add('iOS beacon ranging error: $error');
        },
      );
      _lastObservationAt = DateTime.now();
      _staleSweepTimer =
          Timer.periodic(staleSweepInterval, (_) => _pruneStaleReadings());
      _watchdogTimer =
          Timer.periodic(watchdogCheckInterval, (_) => _checkScanHealth());
    } catch (error) {
      _diagnostic('iOS CoreLocation ranging initialization error=$error');
      _errorController.add('iOS beacon ranging initialization error: $error');
    }
  }

  void _onIosRangingResult(RangingResult result) {
    _lastObservationAt = DateTime.now();
    _diagnostic(
      'iOS ranging region=${result.region.identifier} '
      'beaconCount=${result.beacons.length}',
    );
    for (final beacon in result.beacons) {
      final key =
          '${beacon.proximityUUID.toLowerCase()}:${beacon.major}:${beacon.minor}';
      _diagnostic(
        'iOS beacon key=$key rssi=${beacon.rssi} '
        'accuracy=${beacon.accuracy} proximity=${beacon.proximity}',
      );
      if (beacon.rssi == 0 || beacon.rssi == -1) continue;
      _recordBeacon(key: key, scannerId: 'ios:$key', rssi: beacon.rssi);
    }
  }

  void _checkScanHealth() {
    final last = _lastObservationAt;
    if (last == null) return;
    if (DateTime.now().difference(last) > watchdogNoDeviceThreshold) {
      _diagnostic(
        'watchdog fired: lastObservation=$last '
        'knownBeaconCount=${_scanInfoByKey.length}',
      );
      _errorController.add(
        'No BLE scan observations seen for ${watchdogNoDeviceThreshold.inSeconds}s — '
        'scan may have silently stalled, restarting.',
      );
      _lastObservationAt = DateTime.now();
      _restartScan();
    }
  }

  void _pruneStaleReadings() {
    final now = DateTime.now();
    final staleKeys = _scanInfoByKey.entries
        .where((entry) =>
            now.difference(entry.value.lastSeen) > staleBeaconTimeout)
        .map((entry) => entry.key)
        .toList();
    if (staleKeys.isEmpty) return;

    for (final key in staleKeys) {
      _readings.remove(key);
      _scanInfoByKey.remove(key);
    }

    final averaged = _averagedRssi();
    _rssiController.add(averaged);
    _latestScanInfo = [
      for (final entry in averaged.entries)
        _scanInfoByKey[entry.key]!.copyWith(rssi: entry.value),
    ]..sort((a, b) => b.rssi.compareTo(a.rssi));
    _scanInfoController.add(_latestScanInfo);
  }

  /// Requests the permissions BLE scanning needs on this platform. Returns
  /// null if everything required is granted, otherwise a message describing
  /// what's missing.
  Future<String?> _ensurePermissions() async {
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      _diagnostic('Android permission statuses=$statuses');
      final denied = statuses.entries
          .where((e) => !e.value.isGranted)
          .map((e) => e.key.toString());
      if (denied.isNotEmpty) {
        return 'Missing permissions: ${denied.join(', ')}. Grant them in system settings.';
      }
      return null;
    }
    if (Platform.isIOS) {
      final status = await Permission.bluetooth.request();
      _diagnostic('iOS Bluetooth permission status=$status');
      if (!status.isGranted) {
        return 'Bluetooth permission denied. Grant it in Settings > Privacy > Bluetooth.';
      }
      return null;
    }
    return null;
  }

  void _onDeviceSeen(DiscoveredDevice device) {
    _lastObservationAt = DateTime.now();
    final manufacturerHex = device.manufacturerData.isNotEmpty
        ? device.manufacturerData
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join()
        : '<empty>';
    final serviceDataHex = device.serviceData.isEmpty
        ? '<empty>'
        : device.serviceData.entries.map((entry) {
            final bytes = entry.value
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join();
            return '${entry.key}:$bytes';
          }).join(',');
    _diagnostic(
      'device id=${device.id} name=${device.name.isEmpty ? '<empty>' : device.name} '
      'rssi=${device.rssi} services=${device.serviceUuids} '
      'manufacturerLength=${device.manufacturerData.length} '
      'manufacturerData=$manufacturerHex serviceData=$serviceDataHex',
    );
    final beacon = parseIBeacon(device.manufacturerData,
        logDiagnostics: enableDiagnosticLogging);
    _diagnostic(
        'device id=${device.id} parseResult=${beacon ?? '<not an iBeacon>'}');
    String? key;

    final normalizedDeviceId = device.id.replaceAll(':', '').toLowerCase();
    if (_debugTargetMacToKey.containsKey(normalizedDeviceId)) {
      key = _debugTargetMacToKey[normalizedDeviceId]!;
      print('BLE scan: mapped device=${device.id} to beacon key=$key via MAC');
    } else if (beacon != null) {
      key = beacon.key;
      print(
          'BLE scan: mapped device=${device.id} to beacon key=$key via iBeacon');
    }

    if (key == null) {
      _diagnostic('device id=${device.id} ignored: no beacon key resolved');
      return;
    } else {
      print(
          'BLE scan: device=${device.id} name=${device.name} rssi=${device.rssi} '
          'services=${device.serviceUuids} manufacturerData=$manufacturerHex parsedIBeacon=$beacon key=$key');
    }

    _recordBeacon(
        key: key,
        scannerId: device.id,
        rssi: device.rssi,
        deviceName: beacon?.key);
  }

  void _recordBeacon({
    required String key,
    required String scannerId,
    required int rssi,
    String? deviceName,
  }) {
    final now = DateTime.now();
    final history = _readings.putIfAbsent(key, () => []);
    history.add(_TimedRssi(now, rssi));
    history.removeWhere((r) => now.difference(r.time) > rollingWindow);

    // Use beacon name from store data if available, otherwise use device name
    final beaconName = _beaconNamesByKey[key] ?? deviceName ?? key;

    _scanInfoByKey[key] = BeaconScanInfo(
      key: key,
      scannerId: scannerId,
      name: beaconName,
      rssi: rssi.toDouble(),
      lastSeen: now,
    );

    final averaged = _averagedRssi();
    _rssiController.add(averaged);
    _latestScanInfo = [
      for (final entry in averaged.entries)
        _scanInfoByKey[entry.key]!.copyWith(rssi: entry.value),
    ]..sort((a, b) => b.rssi.compareTo(a.rssi));
    _scanInfoController.add(_latestScanInfo);
  }

  void _diagnostic(String message) {
    if (enableDiagnosticLogging) print('[BLE_DIAGNOSTIC] $message');
  }

// //average - better for celing mounted BEacons
//   Map<String, double> _averagedRssi() {
//     final now = DateTime.now();
//     final result = <String, double>{};
//
//     for (final entry in _readings.entries) {
//       // 1. Filter out scans outside the rolling time window
//       final recent = entry.value
//           .where((r) => now.difference(r.time) <= rollingWindow)
//           .toList();
//
//       if (recent.isEmpty) continue;
//
//       // 2. Sum the raw RSSI values up
//       final sum = recent.map((r) => r.rssi).reduce((a, b) => a + b);
//
//       // 3. Compute a clean, smooth mathematical average
//       final average = sum / recent.length;
//       result[entry.key] = double.parse(average.toStringAsFixed(1));
//     }
//     return result;
//   }

  /// Main RSSI averaging method — delegates to configured filter mode.
  /// If [filterMode] is [RssiFilterMode.both], runs both and logs comparison.
  Map<String, double> _averagedRssi() {
    if (filterMode == RssiFilterMode.both) {
      final median = _averagedRssiMedian();
      final kalman = _averagedRssiKalman();
      if (enableComparisonLogging) {
        _logComparisonResults(median, kalman);
      }
      // Return median as the default for now (can be switched)
      return kalman;
    } else if (filterMode == RssiFilterMode.kalman) {
      return _averagedRssiKalman();
    } else {
      return _averagedRssiMedian();
    }
  }

  /// Median-based RSSI averaging — better for wall-mounted beacons.
  /// Robust against outliers; preserves peaks in RSSI trends.
  Map<String, double> _averagedRssiMedian() {
    final now = DateTime.now();
    final result = <String, double>{};
    for (final entry in _readings.entries) {
      final recent = entry.value
          .where((r) => now.difference(r.time) <= rollingWindow)
          .toList();
      if (recent.isEmpty) continue;
      final values = recent.map((r) => r.rssi).toList()..sort();
      final middle = values.length ~/ 2;
      result[entry.key] = values.length.isOdd
          ? values[middle].toDouble()
          : (values[middle - 1] + values[middle]) / 2.0;
    }
    return result;
  }

  /// Kalman-filtered RSSI averaging — adaptive filter that learns
  /// measurement noise and produces smoothed estimates.
  /// Each beacon maintains its own filter state across calls.
  Map<String, double> _averagedRssiKalman() {
    final now = DateTime.now();
    final result = <String, double>{};

    for (final entry in _readings.entries) {
      final key = entry.key;
      final recent = entry.value
          .where((r) => now.difference(r.time) <= rollingWindow)
          .toList();

      if (recent.isEmpty) {
        // No recent data — use last estimate if available
        final state = _kalmanStates[key];
        if (state != null) {
          result[key] = state.estimate;
        }
        continue;
      }

      // Get or create Kalman state for this beacon
      final state = _kalmanStates.putIfAbsent(
        key,
        () => _BeaconKalmanState(
          estimateError: kalmanInitialError,
          measurementError: kalmanMeasurementError,
          processNoise: kalmanProcessNoise,
        ),
      );

      // Feed all recent measurements through the filter (in order)
      for (final timedRssi in recent) {
        state.update(timedRssi.rssi.toDouble());
      }

      result[key] = state.estimate;
    }

    return result;
  }

  /// Log side-by-side comparison of median vs kalman for each beacon.
  void _logComparisonResults(
    Map<String, double> median,
    Map<String, double> kalman,
  ) {
    final keys = {...median.keys, ...kalman.keys};
    for (final key in keys) {
      final scanInfo = _scanInfoByKey[key];
      final storedName = _beaconNamesByKey[key];

      // Priority: scanInfo name > stored name lookup > key
      String beaconName = 'Unknown';
      if (scanInfo?.name.isNotEmpty ?? false) {
        beaconName = scanInfo!.name;
      } else if (storedName?.isNotEmpty ?? false) {
        beaconName = storedName!;
      } else {
        beaconName = 'Unknown (key: $key)';
      }

      final medianVal = median[key]?.toStringAsFixed(1) ?? 'N/A';
      final kalmanVal = kalman[key]?.toStringAsFixed(1) ?? 'N/A';
      final diff = (median[key] != null && kalman[key] != null)
          ? (median[key]! - kalman[key]!).toStringAsFixed(2)
          : 'N/A';

      print(
        '[BLE_FILTER_CMP] Beacon: $beaconName | '
        'Median: $medianVal dB | '
        'Kalman: $kalmanVal dB | '
        'Δ: $diff dB',
      );
    }
  }

  /// Switch filter mode at runtime for testing.
  void setFilterMode(RssiFilterMode mode, {bool enableLogging = false}) {
    // Note: This doesn't actually change the filterMode field (it's final),
    // but we can use a mutable field instead if needed for runtime switching.
    print('[BLE] Filter mode request: $mode (logging=$enableLogging) — '
        'requires app restart to take effect due to final configuration');
  }

  void stopScan() {
    _scanSub?.cancel();
    _scanSub = null;
    _iosRangingSub?.cancel();
    _iosRangingSub = null;
    _statusSub?.cancel();
    _statusSub = null;
    _staleSweepTimer?.cancel();
    _staleSweepTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _lastObservationAt = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stopScan();
    _rssiController.close();
    _scanInfoController.close();
    _errorController.close();
  }
}

class IBeacon {
  final String uuid;
  final int major;
  final int minor;
  const IBeacon({required this.uuid, required this.major, required this.minor});

  /// Store-data-compatible identity string, e.g.
  /// "01020304-0506-0708-090a-0b0c0d0e0f10:256:1".
  String get key => '$uuid:$major:$minor';

  @override
  String toString() => key;
}

/// Parses an iBeacon advertisement's manufacturer data (Apple company id
/// 0x004C, iBeacon type 0x0215) into its proximity UUID, major, and minor,
/// or null if [data] doesn't contain a valid iBeacon payload.
IBeacon? parseIBeacon(Uint8List data, {bool logDiagnostics = false}) {
  final rawHex = data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  if (data.length < 2) {
    if (logDiagnostics) {
      print(
          '[BLE_PARSE] rejected: data too short length=${data.length} hex=$rawHex');
    }
    return null;
  }

  for (var i = 0; i <= data.length - 2; i++) {
    final hasCompanyId = i + 4 <= data.length &&
        data[i] == 0x4C &&
        data[i + 1] == 0x00 &&
        data[i + 2] == 0x02 &&
        data[i + 3] == 0x15;
    final hasIBeaconType = data[i] == 0x02 && data[i + 1] == 0x15;
    if (hasCompanyId || hasIBeaconType) {
      final payloadStart = hasCompanyId ? i + 2 : i;
      if (logDiagnostics) {
        print(
          '[BLE_PARSE] header=${hasCompanyId ? 'apple-company-id' : 'iBeacon-type-only'} '
          'offset=$i payloadStart=$payloadStart dataLength=${data.length}',
        );
      }
      if (payloadStart + 24 > data.length) {
        if (logDiagnostics) {
          print(
            '[BLE_PARSE] rejected: incomplete payload '
            'available=${data.length - payloadStart} required=24 hex=$rawHex',
          );
        }
        return null;
      }
      final uuidBytes = data.sublist(payloadStart + 2, payloadStart + 18);
      final hex =
          uuidBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final uuid =
          '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
          '${hex.substring(16, 20)}-${hex.substring(20, 32)}';
      final major = (data[payloadStart + 18] << 8) | data[payloadStart + 19];
      final minor = (data[payloadStart + 20] << 8) | data[payloadStart + 21];
      final beacon = IBeacon(uuid: uuid, major: major, minor: minor);
      if (logDiagnostics) print('[BLE_PARSE] accepted beacon=$beacon');
      return beacon;
    }
  }

  if (logDiagnostics) {
    print('[BLE_PARSE] rejected: no iBeacon header found hex=$rawHex');
  }
  return null;
}
