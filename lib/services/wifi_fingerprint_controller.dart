import 'dart:async';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/wifi_fingerprint.dart';
import 'wifi_fingerprint_service.dart';

enum WifiMatchingMode { knn, weightedKnn }

class WifiFingerprintController extends ChangeNotifier {
  WifiFingerprintController({required this.service}) {
    _observationSub = service.observations.listen(_onObservation);
    _errorSub = service.errors.listen((message) {
      errorMessage = message;
      notifyListeners();
    });
  }

  static const int targetPointSampleCount = 10;

  final WifiFingerprintService service;
  StreamSubscription<WifiObservation>? _observationSub;
  StreamSubscription<String>? _errorSub;
  Timer? _captureTimer;
  final List<WifiObservation> _captureSamples = [];
  final List<Offset> _captureRoutePoints = [];
  final Set<String> selectedBssids = <String>{};
  final Set<String> selectedSsidNames = <String>{};
  final Set<String> anchorBssids = <String>{};
  final Map<String, String> anchorNames = <String, String>{};
  bool _selectionInitialized = false;
  int _lastCompletedSampleCount = 0;
  int _lastCompletedUniqueVectorCount = 0;
  bool _hasSavedSsidDefaults = false;

  WifiObservation? latestObservation;
  WifiMatch? currentMatch;
  Offset? estimatedPosition;
  Offset? selectedPosition;
  bool isCapturing = false;
  String? errorMessage;
  WifiMatchingMode matchingMode = WifiMatchingMode.weightedKnn;

  int get fingerprintCount => service.fingerprints.length;
  int get captureSampleCount => _captureSamples.length;
  bool get pointCaptureTargetReached => _captureSamples.length >= targetPointSampleCount;
  int get captureUniqueRssiVectorCount => _captureSamples.map((sample) => sample.rssiByBssid.toString()).toSet().length;
  int get captureSamplesPerPoint => _captureSamples.length;
  int get lastCompletedSampleCount => _lastCompletedSampleCount;
  int get lastCompletedUniqueVectorCount => _lastCompletedUniqueVectorCount;
  DateTime? get latestScanRequestedAt => latestObservation?.scanRequestedAt;
  int? get latestScanResultTimestampMicros => latestObservation?.scanResultTimestampMicros;
  int get visibleAccessPointCount => latestObservation?.rssiByBssid.length ?? 0;
  Map<String, double> get visibleAccessPoints => latestObservation?.rssiByBssid ?? const {};
  Map<String, String> get visibleAccessPointNames => latestObservation?.ssidByBssid ?? const {};
  bool get hasSelectedAccessPoints => selectedBssids.isNotEmpty;
  bool get hasSelectedAnchors => anchorBssids.isNotEmpty;
  bool get hasSavedSsidDefaults => _hasSavedSsidDefaults;
  String? get activeAnchorBssid => currentMatch?.anchorBssid;
  Offset? get activeAnchorPosition {
    final bssid = activeAnchorBssid;
    return bssid == null ? null : service.anchorPositions[bssid];
  }

  String? get activeAnchorName {
    final bssid = activeAnchorBssid;
    return bssid == null ? null : anchorDisplayName(bssid);
  }

  Future<void> start() async {
    final preferences = await SharedPreferences.getInstance();
    final savedNames = preferences.getStringList(_savedSsidNamesKey) ?? const <String>[];
    final savedAnchors = preferences.getStringList(_savedAnchorBssidsKey) ?? const <String>[];
    final savedAnchorNames = preferences.getStringList(_savedAnchorNamesKey) ?? const <String>[];
    selectedSsidNames
      ..clear()
      ..addAll(savedNames);
    _hasSavedSsidDefaults = savedNames.isNotEmpty;
    anchorBssids
      ..clear()
      ..addAll(savedAnchors);
    anchorNames
      ..clear()
      ..addEntries(savedAnchorNames.map((value) {
        final separator = value.indexOf('|');
        return MapEntry(separator < 0 ? value : value.substring(0, separator), separator < 0 ? value : value.substring(separator + 1));
      }));
    await service.loadPersisted();
    await service.start();
  }

  static const _savedSsidNamesKey = 'wifi_selected_ssid_names';
  static const _savedAnchorBssidsKey = 'wifi_anchor_bssids';
  static const _savedAnchorNamesKey = 'wifi_anchor_names';

  String anchorDisplayName(String bssid) => anchorNames[bssid] ?? visibleAccessPointNames[bssid] ?? bssid;

  void selectCapturePoint(Offset position) {
    if (isCapturing) return;
    selectedPosition = position;
    notifyListeners();
  }

  void clearSelection() {
    if (isCapturing) return;
    selectedPosition = null;
    notifyListeners();
  }

  void beginCapture() {
    if (isCapturing || selectedPosition == null || selectedBssids.isEmpty) return;
    _captureSamples.clear();
    isCapturing = true;
    errorMessage = null;
    notifyListeners();
  }

  void beginWalkingCapture(List<Offset> routePoints) {
    if (isCapturing || routePoints.length < 2 || selectedBssids.isEmpty) return;
    _captureSamples.clear();
    _captureRoutePoints
      ..clear()
      ..addAll(routePoints);
    isCapturing = true;
    errorMessage = null;
    notifyListeners();
  }

  void finishCapture() {
    if (!isCapturing) return;
    if (_captureRoutePoints.isEmpty && !pointCaptureTargetReached) return;
    _captureTimer?.cancel();
    _captureTimer = null;
    final position = selectedPosition;
    if (position != null && _captureSamples.isNotEmpty) {
      _recordCaptureQuality();
      service.addFingerprint(floorId: 'default-floor', position: position, samples: _captureSamples);
    }
    isCapturing = false;
    selectedPosition = null;
    _captureSamples.clear();
    notifyListeners();
  }

  void finishWalkingCapture() {
    if (!isCapturing || _captureRoutePoints.length < 2) return;
    service.addWalkingFingerprints(
      floorId: 'default-floor',
      samples: List<WifiObservation>.from(_captureSamples),
      positions: _positionsAlongRoute(_captureSamples.length),
    );
    _recordCaptureQuality();
    isCapturing = false;
    _captureSamples.clear();
    _captureRoutePoints.clear();
    notifyListeners();
  }

  void _recordCaptureQuality() {
    _lastCompletedSampleCount = _captureSamples.length;
    _lastCompletedUniqueVectorCount = captureUniqueRssiVectorCount;
  }

  List<Offset> _positionsAlongRoute(int count) {
    if (count == 0) return const [];
    final lengths = <double>[0];
    for (var i = 1; i < _captureRoutePoints.length; i++) {
      lengths.add(lengths.last + (_captureRoutePoints[i] - _captureRoutePoints[i - 1]).distance);
    }
    final total = lengths.last;
    if (total == 0) return List<Offset>.filled(count, _captureRoutePoints.first);
    return List.generate(count, (index) {
      final distance = total * (count == 1 ? 0 : index / (count - 1));
      var segment = 1;
      while (segment < lengths.length - 1 && lengths[segment] < distance) {
        segment++;
      }
      final segmentLength = lengths[segment] - lengths[segment - 1];
      final fraction = segmentLength == 0 ? 0.0 : (distance - lengths[segment - 1]) / segmentLength;
      return Offset.lerp(_captureRoutePoints[segment - 1], _captureRoutePoints[segment], fraction)!;
    });
  }

  void _onObservation(WifiObservation observation) {
    latestObservation = observation;
    if (!_selectionInitialized) {
      _selectionInitialized = true;
    }
    for (final entry in observation.rssiByBssid.entries) {
      final ssid = observation.ssidByBssid[entry.key]?.trim() ?? '';
      if (_hasSavedSsidDefaults && selectedSsidNames.contains(ssid)) selectedBssids.add(entry.key);
    }
    final filtered = _filter(observation.rssiByBssid);
    final selectedObservation = WifiObservation(
      timestamp: observation.timestamp,
      rssiByBssid: filtered,
      ssidByBssid: {
        for (final bssid in filtered.keys)
          if (observation.ssidByBssid.containsKey(bssid)) bssid: observation.ssidByBssid[bssid]!,
      },
      scanRequestedAt: observation.scanRequestedAt,
      scanResultTimestampMicros: observation.scanResultTimestampMicros,
    );
    if (isCapturing) _captureSamples.add(selectedObservation);
    if (isCapturing && _captureRoutePoints.isEmpty && pointCaptureTargetReached) {
      finishCapture();
      return;
    }
    final match = service.match(filtered, weighted: matchingMode == WifiMatchingMode.weightedKnn, allowedBssids: hasSelectedAnchors ? anchorBssids : selectedBssids);
    if (match != null && match.confidence >= 0.35) {
      currentMatch = match;
      final previous = estimatedPosition;
      estimatedPosition = previous == null
          ? match.position
          : Offset.lerp(previous, match.position, 0.25)!;
    } else {
      currentMatch = null;
      estimatedPosition = null;
    }
    notifyListeners();
  }

  Map<String, double> _filter(Map<String, double> readings) => {
        for (final entry in readings.entries)
          if (selectedBssids.contains(entry.key)) entry.key: entry.value,
      };

  void setAccessPointSelected(String bssid, bool selected) {
    if (isCapturing) return;
    if (selected) {
      selectedBssids.add(bssid);
    } else {
      selectedBssids.remove(bssid);
    }
    notifyListeners();
  }

  Future<void> setSsidSelected(String ssid, bool selected) async {
    if (isCapturing) return;
    final bssids = visibleAccessPointNames.entries
        .where((entry) => entry.value.trim() == ssid)
        .map((entry) => entry.key)
        .toSet();
    if (selected) {
      selectedSsidNames.add(ssid);
      selectedBssids.addAll(bssids);
    } else {
      selectedSsidNames.remove(ssid);
      selectedBssids.removeAll(bssids);
    }
    _hasSavedSsidDefaults = true;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(_savedSsidNamesKey, selectedSsidNames.toList()..sort());
    notifyListeners();
  }

  bool isSsidSelected(String ssid) => selectedSsidNames.contains(ssid);

  Future<void> setNetworkGroupSelected(String groupKey, Iterable<String> bssids, bool selected) async {
    if (isCapturing) return;
    final groupBssids = bssids.toSet();
    if (selected) {
      selectedSsidNames.add(groupKey);
      selectedBssids.addAll(groupBssids);
    } else {
      selectedSsidNames.remove(groupKey);
      selectedBssids.removeAll(groupBssids);
    }
    _hasSavedSsidDefaults = true;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(_savedSsidNamesKey, selectedSsidNames.toList()..sort());
    notifyListeners();
  }

  Future<void> setAnchorSelected(String bssid, bool selected) async {
    if (isCapturing) return;
    if (selected) {
      anchorBssids.add(bssid);
      selectedBssids.add(bssid);
    } else {
      anchorBssids.remove(bssid);
      selectedBssids.remove(bssid);
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(_savedAnchorBssidsKey, anchorBssids.toList()..sort());
    final latest = latestObservation;
    if (latest != null) {
      currentMatch = service.match(_filter(latest.rssiByBssid), weighted: matchingMode == WifiMatchingMode.weightedKnn, allowedBssids: hasSelectedAnchors ? anchorBssids : selectedBssids);
      estimatedPosition = currentMatch?.position;
    }
    notifyListeners();
  }

  Future<void> useSuggestedAnchors(Iterable<String> bssids) async {
    if (isCapturing) return;
    anchorBssids
      ..clear()
      ..addAll(bssids);
    selectedBssids.addAll(anchorBssids);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(_savedAnchorBssidsKey, anchorBssids.toList()..sort());
    final latest = latestObservation;
    if (latest != null) {
      currentMatch = service.match(
        _filter(latest.rssiByBssid),
        weighted: matchingMode == WifiMatchingMode.weightedKnn,
        allowedBssids: hasSelectedAnchors ? anchorBssids : selectedBssids,
      );
      estimatedPosition = currentMatch?.position;
    }
    notifyListeners();
  }

  Future<void> renameAnchor(String bssid, String name) async {
    if (name.trim().isEmpty) {
      anchorNames.remove(bssid);
    } else {
      anchorNames[bssid] = name.trim();
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(_savedAnchorNamesKey, anchorNames.entries.map((entry) => '${entry.key}|${entry.value}').toList()..sort());
    notifyListeners();
  }

  void setMatchingMode(WifiMatchingMode mode) {
    if (isCapturing || matchingMode == mode) return;
    matchingMode = mode;
    final latest = latestObservation;
    if (latest != null) {
      currentMatch = service.match(_filter(latest.rssiByBssid), weighted: mode == WifiMatchingMode.weightedKnn, allowedBssids: hasSelectedAnchors ? anchorBssids : selectedBssids);
      if (currentMatch == null || currentMatch!.confidence < 0.35) {
        currentMatch = null;
      } else {
        estimatedPosition = currentMatch!.position;
      }
    }
    notifyListeners();
  }

  Future<String> export() => service.exportJson();

  Future<int> importJson(String contents) async {
    final count = await service.importJson(contents);
    notifyListeners();
    return count;
  }

  void clearFingerprints() {
    service.fingerprints.clear();
    currentMatch = null;
    estimatedPosition = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    _observationSub?.cancel();
    _errorSub?.cancel();
    service.dispose();
    super.dispose();
  }
}