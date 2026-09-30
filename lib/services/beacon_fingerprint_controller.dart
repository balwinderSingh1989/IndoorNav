import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/beacon.dart';
import '../models/beacon_fingerprint.dart';
import 'beacon_fingerprint_service.dart';
import 'ble_scanner_service.dart';

/// Coordinates beacon-zone fingerprint capture and live quality feedback.
class BeaconFingerprintController extends ChangeNotifier {
  BeaconFingerprintController(
    this._fingerprintService,
    this._bleScanner,
    List<Beacon> beacons,
  ) : _beacons = List.unmodifiable(beacons) {
    _selectedBeacon = _beacons.isEmpty ? null : _beacons.first;
  }

  final BeaconFingerprintService _fingerprintService;
  final BleScannerService _bleScanner;
  final List<Beacon> _beacons;
  StreamSubscription<List<BeaconScanInfo>>? _scanSubscription;

  bool _isCapturing = false;
  int _captureProgress = 0;
  String _statusMessage = '';
  Beacon? _selectedBeacon;
  List<BeaconReading> _currentReadings = const [];
  List<BeaconReading> _captureReadings = [];
  Map<BeaconDistanceAlgorithm, FingerprintQuality> _liveQuality = const {};

  int captureDuration = 5;

  bool get isCapturing => _isCapturing;
  int get captureProgress => _captureProgress;
  String get statusMessage => _statusMessage;
  List<Beacon> get beacons => _beacons;
  Beacon? get selectedBeacon => _selectedBeacon;
  List<BeaconReading> get currentReadings => List.unmodifiable(_currentReadings);
  Map<BeaconDistanceAlgorithm, FingerprintQuality> get liveQuality => _liveQuality;
  BeaconDistanceAlgorithm get currentAlgorithm => _fingerprintService.currentAlgorithm;
  Map<String, BeaconZoneFingerprint> get zones => _fingerprintService.fingerprints;

  Future<void> init() async {
    await _fingerprintService.loadFingerprints();
    _currentReadings = _toReadings(_bleScanner.latestScanInfo);
    _scanSubscription = _bleScanner.scanInfoStream.listen(_onScanInfo);
    _refreshLiveQuality();
    _setStatus(_beacons.isEmpty ? 'No configured beacons' : 'Select the beacon for this zone');
    notifyListeners();
  }

  void selectBeacon(Beacon? beacon) {
    if (beacon == null || _isCapturing) return;
    _selectedBeacon = beacon;
    _refreshLiveQuality();
    _setStatus('Selected ${beacon.name} as the standing zone');
    notifyListeners();
  }

  void switchAlgorithm(BeaconDistanceAlgorithm algorithm) {
    _fingerprintService.setAlgorithm(algorithm);
    notifyListeners();
  }

  Future<void> startCapture() async {
    final selectedBeacon = _selectedBeacon;
    if (_isCapturing || selectedBeacon == null) return;

    _isCapturing = true;
    _captureProgress = 0;
    _captureReadings = [];
    _setStatus('Capturing fingerprint for ${selectedBeacon.name}');
    notifyListeners();

    const tick = Duration(milliseconds: 100);
    final totalTicks = captureDuration * 10;
    for (var tickIndex = 0; tickIndex < totalTicks; tickIndex++) {
      await Future<void>.delayed(tick);
      _captureProgress = ((tickIndex + 1) * 100 ~/ totalTicks);
      notifyListeners();
    }

    try {
      if (_captureReadings.isEmpty) {
        _setStatus('No BLE readings received. Start BLE scanning and try again.');
        return;
      }
      await _fingerprintService.captureZoneFingerprint(
        zoneName: selectedBeacon.id,
        beaconReadings: _captureReadings,
      );
      _refreshLiveQuality();
      _setStatus('Saved ${selectedBeacon.name}. A red dot means the live pattern matches this zone.');
    } finally {
      _isCapturing = false;
      notifyListeners();
    }
  }

  void _onScanInfo(List<BeaconScanInfo> scanInfo) {
    _currentReadings = _toReadings(scanInfo);
    if (_isCapturing) {
      _captureReadings = [..._captureReadings, ..._currentReadings];
    }
    _refreshLiveQuality();
    notifyListeners();
  }

  List<BeaconReading> _toReadings(List<BeaconScanInfo> scanInfo) {
    return [
      for (final info in scanInfo)
        if (_parseReading(info) case final reading?) reading,
    ];
  }

  BeaconReading? _parseReading(BeaconScanInfo info) {
    final parts = info.key.split(':');
    if (parts.length < 3) return null;
    final major = int.tryParse(parts[parts.length - 2]);
    final minor = int.tryParse(parts.last);
    if (major == null || minor == null) return null;
    return BeaconReading(
      uuid: parts.sublist(0, parts.length - 2).join(':'),
      major: major,
      minor: minor,
      rssi: info.rssi.round(),
    );
  }

  void _refreshLiveQuality() {
    final selectedBeacon = _selectedBeacon;
    if (selectedBeacon == null || _currentReadings.isEmpty || !zones.containsKey(selectedBeacon.id)) {
      _liveQuality = const {};
      return;
    }

    final quality = <BeaconDistanceAlgorithm, FingerprintQuality>{};
    for (final algorithm in BeaconDistanceAlgorithm.values) {
      final results = _fingerprintService.evaluate(_currentReadings, algorithm);
      final expected = results.where((result) => result.zoneName == selectedBeacon.id).firstOrNull;
      final best = results.isEmpty ? null : results.first;
      quality[algorithm] = FingerprintQuality(
        algorithm: algorithm,
        result: expected,
        matchesSelectedZone: best?.zoneName == selectedBeacon.id,
        passesThreshold: expected != null && _passesThreshold(expected, algorithm),
      );
    }
    _liveQuality = quality;
  }

  bool _passesThreshold(DistanceResult result, BeaconDistanceAlgorithm algorithm) {
    switch (algorithm) {
      case BeaconDistanceAlgorithm.euclidean:
        return result.distance <= _fingerprintService.euclideanThreshold;
      case BeaconDistanceAlgorithm.mahalanobis:
        return result.distance <= _fingerprintService.mahalanobisThreshold;
      case BeaconDistanceAlgorithm.timeSeries:
        return result.distance >= _fingerprintService.correlationThreshold;
    }
  }

  void _setStatus(String message) => _statusMessage = message;

  @override
  void dispose() {
    _scanSubscription?.cancel();
    super.dispose();
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
