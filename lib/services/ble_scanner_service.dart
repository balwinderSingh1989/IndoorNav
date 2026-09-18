import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

class _TimedRssi {
  final DateTime time;
  final int rssi;
  _TimedRssi(this.time, this.rssi);
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
class BleScannerService {
  BleScannerService({
    FlutterReactiveBle? ble,
    // 2s rather than the old 3s: a straight lag/noise trade-off — a
    // longer window smooths single-packet RSSI noise better, but also
    // means a real movement (or a genuine zone change) takes that much
    // longer to actually show up in the average. Still plenty of samples
    // to average given typical advertising intervals well under a second.
    this.rollingWindow = const Duration(milliseconds: 2000),
  }) : _ble = ble;

  FlutterReactiveBle? _ble;
  final Duration rollingWindow;

  /// How long a beacon can go unseen before its last-known reading is
  /// pruned and it disappears from [rssiStream]/[scanInfoStream]. Without
  /// this, a beacon that drops out of range keeps reporting its last
  /// (increasingly stale) RSSI forever, since [_readings] is only pruned
  /// reactively — inside [_onDeviceSeen], which stops running for that key
  /// the moment it stops being detected.
  static const Duration _staleBeaconTimeout = Duration(seconds: 5);
  static const Duration _staleSweepInterval = Duration(seconds: 2);

  /// If no device of any kind has been seen for this long while the
  /// adapter reports ready, treat the scan as silently stalled and
  /// restart it. This is the backstop for failure modes that produce
  /// neither an error nor a stream-done event — a known flakiness pattern
  /// on some Android BLE stacks/OEMs.
  static const Duration _watchdogNoDeviceThreshold = Duration(seconds: 10);
  static const Duration _watchdogCheckInterval = Duration(seconds: 5);

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
  final _scanInfoController = StreamController<List<BeaconScanInfo>>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<BleStatus>? _statusSub;
  Timer? _staleSweepTimer;
  Timer? _watchdogTimer;
  DateTime? _lastDeviceSeenAt;
  bool _restarting = false;
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
    if (_ble == null && (Platform.isAndroid || Platform.isIOS)) {
      _ble = FlutterReactiveBle();
    }
    if (_ble == null) return;

    final permissionError = await _ensurePermissions();
    if (permissionError != null) {
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

    // lowLatency maximizes scan duty cycle (vs the balanced/lowPower
    // defaults), which matters for beacons with a sparse advertising
    // interval — nRF Connect and similar dedicated scanner apps tend to
    // scan more aggressively by default, which is why they can see a
    // beacon a lower-duty-cycle scan mode would miss.
    _scanSub = _ble!.scanForDevices(withServices: [], scanMode: ScanMode.lowLatency).listen(
      _onDeviceSeen,
      onError: (Object e) {
        _errorController.add('BLE scan error: $e — restarting scan.');
        _restartScan();
      },
      onDone: () {
        // The scan stream closed without an error — this happens on
        // some Android adapters/OEMs after a silent internal reset.
        // Treated the same as an error: restart rather than leave
        // scanning permanently stopped with no signal that it happened.
        _errorController.add('BLE scan stream ended unexpectedly — restarting scan.');
        _restartScan();
      },
    );

    _lastDeviceSeenAt ??= DateTime.now(); // don't immediately trip the watchdog on a cold start
    _staleSweepTimer = Timer.periodic(_staleSweepInterval, (_) => _pruneStaleReadings());
    _watchdogTimer = Timer.periodic(_watchdogCheckInterval, (_) => _checkScanHealth());
  }

  Future<void> _restartScan() async {
    if (_restarting) return; // avoid overlapping restarts if multiple signals fire close together
    _restarting = true;
    try {
      await _scanSub?.cancel();
      _scanSub = null;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await startScan();
    } finally {
      _restarting = false;
    }
  }

  void _checkScanHealth() {
    final last = _lastDeviceSeenAt;
    if (last == null) return;
    if (DateTime.now().difference(last) > _watchdogNoDeviceThreshold) {
      _errorController.add(
        'No BLE devices seen for ${_watchdogNoDeviceThreshold.inSeconds}s — '
            'scan may have silently stalled, restarting.',
      );
      _lastDeviceSeenAt = DateTime.now(); // reset so the watchdog doesn't refire every tick during the restart
      _restartScan();
    }
  }

  void _pruneStaleReadings() {
    final now = DateTime.now();
    final staleKeys = _scanInfoByKey.entries
        .where((entry) => now.difference(entry.value.lastSeen) > _staleBeaconTimeout)
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
      final denied = statuses.entries.where((e) => !e.value.isGranted).map((e) => e.key.toString());
      if (denied.isNotEmpty) {
        return 'Missing permissions: ${denied.join(', ')}. Grant them in system settings.';
      }
      return null;
    }
    if (Platform.isIOS) {
      final status = await Permission.bluetooth.request();
      if (!status.isGranted) {
        return 'Bluetooth permission denied. Grant it in Settings > Privacy > Bluetooth.';
      }
      return null;
    }
    return null;
  }

  void _onDeviceSeen(DiscoveredDevice device) {


    final manufacturerHex = device.manufacturerData.isNotEmpty
        ? device.manufacturerData.map((b) => b.toRadixString(16).padLeft(2, '0')).join()
        : '<empty>';
    final beacon = parseIBeacon(device.manufacturerData);
    String? key;

    final normalizedDeviceId = device.id.replaceAll(':', '').toLowerCase();
    if (_debugTargetMacToKey.containsKey(normalizedDeviceId)) {
      key = _debugTargetMacToKey[normalizedDeviceId]!;
      print('BLE scan: mapped device=${device.id} to beacon key=$key via MAC');
    } else if (beacon != null) {
      key = beacon.key;
      print('BLE scan: mapped device=${device.id} to beacon key=$key via iBeacon');
    }



    if (key == null) {
      return;
    }else {
      print('BLE scan: device=${device.id} name=${device.name} rssi=${device.rssi} '
          'services=${device.serviceUuids} manufacturerData=$manufacturerHex parsedIBeacon=$beacon key=$key');
      _lastDeviceSeenAt = DateTime.now();
    }

    final now = DateTime.now();
    final history = _readings.putIfAbsent(key, () => []);
    history.add(_TimedRssi(now, device.rssi));
    history.removeWhere((r) => now.difference(r.time) > rollingWindow);
    _scanInfoByKey[key] = BeaconScanInfo(
      key: key,
      scannerId: device.id,
      name: device.name,
      rssi: device.rssi.toDouble(),
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

  Map<String, double> _averagedRssi() {
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

  void stopScan() {
    _scanSub?.cancel();
    _scanSub = null;
    _statusSub?.cancel();
    _statusSub = null;
    _staleSweepTimer?.cancel();
    _staleSweepTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  void dispose() {
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
IBeacon? parseIBeacon(Uint8List data) {
  final rawHex = data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  if (data.length < 4) {
    //print('parseIBeacon: data too short to contain iBeacon header');
    return null;
  }

  for (var i = 0; i <= data.length - 4; i++) {
    if (data[i] == 0x4C && data[i + 1] == 0x00 && data[i + 2] == 0x02 && data[i + 3] == 0x15) {
      if (i + 24 > data.length) {
       // print('parseIBeacon: found prefix at $i but payload is too short (${data.length - i} bytes)');
        return null;
      }
      final uuidBytes = data.sublist(i + 4, i + 20);
      final hex = uuidBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final uuid = '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
          '${hex.substring(16, 20)}-${hex.substring(20, 32)}';
      final major = (data[i + 20] << 8) | data[i + 21];
      final minor = (data[i + 22] << 8) | data[i + 23];
      final beacon = IBeacon(uuid: uuid, major: major, minor: minor);
     // print('parseIBeacon: parsed=$beacon at offset=$i');
      return beacon;
    }
  }

  return null;
}