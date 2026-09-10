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
class BleScannerService {
  BleScannerService({
    FlutterReactiveBle? ble,
    // 2s rather than the old 3s: a straight lag/noise trade-off — a
    // longer window smooths single-packet RSSI noise better, but also
    // means a real movement (or a genuine zone change) takes that much
    // longer to actually show up in the average. Still plenty of samples
    // to average given typical advertising intervals well under a second.
    this.rollingWindow = const Duration(milliseconds: 1500),
  }) : _ble = ble;

  FlutterReactiveBle? _ble;
  final Duration rollingWindow;
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

    _scanSub?.cancel();
    // lowLatency maximizes scan duty cycle (vs the balanced/lowPower
    // defaults), which matters for beacons with a sparse advertising
    // interval — nRF Connect and similar dedicated scanner apps tend to
    // scan more aggressively by default, which is why they can see a
    // beacon our previous default scan mode missed.
    _scanSub = _ble!.scanForDevices(withServices: [], scanMode: ScanMode.lowLatency).listen(
          _onDeviceSeen,
          onError: (Object e) => _errorController.add('BLE scan error: $e'),
        );
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

    print('BLE scan: device=${device.id} name=${device.name} rssi=${device.rssi} '
        'services=${device.serviceUuids} manufacturerData=$manufacturerHex parsedIBeacon=$beacon key=$key');

    if (key == null) {
      print('BLE scan: skipped device ${device.id} because no iBeacon/manufacturer data and no service UUID');
      return;
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
  print('parseIBeacon: raw=$rawHex length=${data.length}');

  if (data.length < 4) {
    print('parseIBeacon: data too short to contain iBeacon header');
    return null;
  }

  for (var i = 0; i <= data.length - 4; i++) {
    if (data[i] == 0x4C && data[i + 1] == 0x00 && data[i + 2] == 0x02 && data[i + 3] == 0x15) {
      if (i + 24 > data.length) {
        print('parseIBeacon: found prefix at $i but payload is too short (${data.length - i} bytes)');
        return null;
      }
      final uuidBytes = data.sublist(i + 4, i + 20);
      final hex = uuidBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final uuid = '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
          '${hex.substring(16, 20)}-${hex.substring(20, 32)}';
      final major = (data[i + 20] << 8) | data[i + 21];
      final minor = (data[i + 22] << 8) | data[i + 23];
      final beacon = IBeacon(uuid: uuid, major: major, minor: minor);
      print('parseIBeacon: parsed=$beacon at offset=$i');
      return beacon;
    }
  }

  print('parseIBeacon: no iBeacon prefix found');
  return null;

  final uuidBytes = data.sublist(4, 20);
  final hex = uuidBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final uuid = '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  final major = (data[20] << 8) | data[21];
  final minor = (data[22] << 8) | data[23];
  return IBeacon(uuid: uuid, major: major, minor: minor);
}