import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wifi_scan/wifi_scan.dart';

import '../models/wifi_fingerprint.dart';

/// Owns WiFi scanning and fingerprint matching. It has no routing or beacon dependency.
class WifiFingerprintService {
  WifiFingerprintService({this.scanInterval = const Duration(seconds: 2)});

  final Duration scanInterval;
  final _observationController = StreamController<WifiObservation>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final List<WifiFingerprint> fingerprints = [];
  Timer? _timer;
  StreamSubscription<List<WiFiAccessPoint>>? _resultsSub;
  bool _scanInFlight = false;
  bool _loaded = false;
  bool _starting = false;
  DateTime? _lastPublishedAt;
  DateTime? _scanRequestedAt;

  Stream<WifiObservation> get observations => _observationController.stream;
  Stream<String> get errors => _errorController.stream;
  List<WifiFingerprint> get surveyFingerprints => List.unmodifiable(fingerprints);

  List<WifiAnchorSuggestion> get anchorSuggestions {
    if (fingerprints.isEmpty) return const [];
    final totalPoints = fingerprints.length;
    final result = <WifiAnchorSuggestion>[];
    final bssids = fingerprints.expand((fingerprint) => fingerprint.rssiByBssid.keys).toSet();
    for (final bssid in bssids) {
      final entries = fingerprints.where((fingerprint) => fingerprint.rssiByBssid.containsKey(bssid)).toList();
      final coverage = entries.length / totalPoints;
      if (coverage < 0.5) continue;
      final values = entries.map((fingerprint) => fingerprint.rssiByBssid[bssid]!).toList();
      final mean = values.reduce((a, b) => a + b) / values.length;
      final variance = values.map((value) => math.pow(value - mean, 2)).reduce((a, b) => a + b) / values.length;
      final spread = math.sqrt(variance);
      final zoneSpread = _zoneSpread(entries, bssid);
      final score = coverage * 0.35 + (spread / 20).clamp(0.0, 1.0) * 0.25 + (zoneSpread / 30).clamp(0.0, 1.0) * 0.40;
      final ssid = entries.first.samples.expand((sample) => sample.ssidByBssid.entries)
          .where((entry) => entry.key == bssid)
          .map((entry) => entry.value)
          .firstWhere((value) => value.isNotEmpty, orElse: () => 'Hidden network');
      result.add(WifiAnchorSuggestion(bssid: bssid, ssid: ssid, coverage: coverage, rssiSpread: spread, zoneSpread: zoneSpread, score: score));
    }
    return result..sort((a, b) => b.score.compareTo(a.score));
  }

  Map<String, Offset> get anchorPositions => {
        for (final suggestion in anchorSuggestions)
          suggestion.bssid: _strongestPosition(suggestion.bssid),
      };

  Offset _strongestPosition(String bssid) {
    final point = fingerprints
        .where((fingerprint) => fingerprint.rssiByBssid.containsKey(bssid))
        .reduce((a, b) => a.rssiByBssid[bssid]! > b.rssiByBssid[bssid]! ? a : b);
    return point.position;
  }

  double _zoneSpread(List<WifiFingerprint> entries, String bssid) {
    if (entries.length < 2) return 0;
    var maximum = 0.0;
    for (var i = 0; i < entries.length; i++) {
      for (var j = i + 1; j < entries.length; j++) {
        if ((entries[i].rssiByBssid[bssid]! - entries[j].rssiByBssid[bssid]!).abs() > 3) {
          maximum = math.max(maximum, (entries[i].position - entries[j].position).distance);
        }
      }
    }
    return maximum;
  }

  Future<void> start() async {
    if (_timer != null || _starting) return;
    _starting = true;
    try {
      final capability = await WiFiScan.instance.canGetScannedResults(askPermissions: true);
      if (capability != CanGetScannedResults.yes) {
        _errorController.add('WiFi scan permission or capability unavailable: $capability');
        return;
      }
      _resultsSub = WiFiScan.instance.onScannedResultsAvailable.listen(_publishResults);
      _timer = Timer.periodic(scanInterval, (_) => _scanOnce());
      await _scanOnce();
    } finally {
      _starting = false;
    }
  }

  Future<void> _scanOnce() async {
    if (_scanInFlight) return;
    _scanInFlight = true;
    final scanStartedAt = DateTime.now();
    _scanRequestedAt = scanStartedAt;
    try {
      await WiFiScan.instance.startScan();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (_lastPublishedAt == null || !_lastPublishedAt!.isAfter(scanStartedAt)) {
        final results = await WiFiScan.instance.getScannedResults();
        _publishResults(results, scanRequestedAt: scanStartedAt);
      }
    } catch (error) {
      _errorController.add('WiFi scan error: $error');
    } finally {
      _scanInFlight = false;
    }
  }

  void _publishResults(List<WiFiAccessPoint> accessPoints, {DateTime? scanRequestedAt}) {
    try {
      final readings = <String, double>{};
      final names = <String, String>{};
      int? resultTimestampMicros;
      for (final accessPoint in accessPoints) {
        final bssid = accessPoint.bssid.trim().toLowerCase();
        if (bssid.isNotEmpty) {
          readings[bssid] = accessPoint.level.toDouble();
          names[bssid] = accessPoint.ssid.trim();
          final timestamp = accessPoint.timestamp;
          if (timestamp != null && (resultTimestampMicros == null || timestamp > resultTimestampMicros)) {
            resultTimestampMicros = timestamp;
          }
        }
      }
      if (readings.isNotEmpty) {
        _lastPublishedAt = DateTime.now();
        _observationController.add(WifiObservation(
          timestamp: DateTime.now(),
          rssiByBssid: readings,
          ssidByBssid: names,
          scanRequestedAt: scanRequestedAt ?? _scanRequestedAt,
          scanResultTimestampMicros: resultTimestampMicros,
        ));
      }
    } catch (error) {
      _errorController.add('WiFi scan error: $error');
    }
  }

  void addFingerprint({required String floorId, required Offset position, required List<WifiObservation> samples}) {
    if (samples.isEmpty) return;
    final valuesByBssid = <String, List<double>>{};
    for (final sample in samples) {
      for (final entry in sample.rssiByBssid.entries) {
        valuesByBssid.putIfAbsent(entry.key, () => []).add(entry.value);
      }
    }
    final average = <String, double>{
      for (final entry in valuesByBssid.entries) entry.key: _median(entry.value),
    };
    fingerprints.add(WifiFingerprint(
      id: 'wifi-${DateTime.now().microsecondsSinceEpoch}',
      floorId: floorId,
      position: position,
      capturedAt: DateTime.now(),
      rssiByBssid: average,
      samples: List.unmodifiable(samples),
    ));
  }

  void addWalkingFingerprints({required String floorId, required List<WifiObservation> samples, required List<Offset> positions}) {
    if (samples.isEmpty || samples.length != positions.length) return;
    const samplesPerPoint = 5;
    for (var start = 0; start < samples.length; start += samplesPerPoint) {
      final end = (start + samplesPerPoint).clamp(0, samples.length);
      final batch = samples.sublist(start, end);
      final batchPositions = positions.sublist(start, end);
      final x = batchPositions.map((position) => position.dx).reduce((a, b) => a + b) / batchPositions.length;
      final y = batchPositions.map((position) => position.dy).reduce((a, b) => a + b) / batchPositions.length;
      addFingerprint(floorId: floorId, position: Offset(x, y), samples: batch);
    }
  }

  WifiMatch? match(Map<String, double> live, {int k = 3, bool weighted = true, Set<String>? allowedBssids}) {
    if (live.isEmpty || fingerprints.isEmpty) return null;
    final filteredLive = allowedBssids == null ? live : Map.fromEntries(live.entries.where((entry) => allowedBssids.contains(entry.key)));
    if (filteredLive.isEmpty) return null;
    final reliability = _reliabilityByBssid();
    final ranked = fingerprints.map((fingerprint) {
      final shared = filteredLive.keys.toSet().intersection(fingerprint.rssiByBssid.keys.toSet()).where((bssid) => reliability[bssid] != null).toSet();
      if (shared.isEmpty) return (fingerprint: fingerprint, distance: double.infinity);
      var weightedError = 0.0;
      var totalReliability = 0.0;
      for (final bssid in shared) {
        final weight = reliability[bssid]!;
        final difference = _difference(filteredLive[bssid]!, fingerprint.rssiByBssid[bssid]!);
        weightedError += difference * difference * weight;
        totalReliability += weight;
      }
      // Penalize fingerprints that miss APs visible in the live scan, but do not
      // treat every absent AP as a real -100 dBm measurement.
      final coveragePenalty = (filteredLive.length - shared.length) * 4.0;
      return (fingerprint: fingerprint, distance: weightedError / totalReliability + coveragePenalty);
    }).where((entry) => entry.distance.isFinite).toList()
      ..sort((a, b) => a.distance.compareTo(b.distance));
    if (ranked.isEmpty) return null;
    final neighbors = ranked.take(k).toList();
    var totalWeight = 0.0;
    var x = 0.0;
    var y = 0.0;
    for (final neighbor in neighbors) {
      final weight = weighted ? 1 / (neighbor.distance + 0.01) : 1.0;
      totalWeight += weight;
      x += neighbor.fingerprint.position.dx * weight;
      y += neighbor.fingerprint.position.dy * weight;
    }
    final sharedCount = neighbors.map((neighbor) => filteredLive.keys.toSet().intersection(neighbor.fingerprint.rssiByBssid.keys.toSet()).where((bssid) => reliability[bssid] != null).length).reduce(math.min);
    final confidence = (sharedCount / math.max(1, reliability.length)) * (1 / (1 + neighbors.first.distance / 100));
    final strongestAnchor = neighbors.first.fingerprint.rssiByBssid.entries
        .where((entry) => filteredLive.containsKey(entry.key))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return WifiMatch(
      position: Offset(x / totalWeight, y / totalWeight),
      distance: neighbors.first.distance,
      neighborCount: neighbors.length,
      sharedAccessPointCount: sharedCount,
      confidence: confidence.clamp(0.0, 1.0),
      anchorBssid: strongestAnchor.isEmpty ? null : strongestAnchor.first.key,
    );
  }

  double _median(List<double> values) {
    final sorted = List<double>.from(values)..sort();
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
  }

  Future<void> loadPersisted() async {
    if (_loaded) return;
    _loaded = true;
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/wifi-fingerprints.json');
    if (!await file.exists()) return;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final entries = (json['fingerprints'] as List<dynamic>? ?? const []);
    fingerprints
      ..clear()
      ..addAll(entries.map((entry) => WifiFingerprint.fromJson(entry as Map<String, dynamic>)));
  }

  Future<int> importJson(String contents) async {
    final json = jsonDecode(contents) as Map<String, dynamic>;
    final entries = json['fingerprints'] as List<dynamic>? ?? const [];
    final imported = entries.map((entry) => WifiFingerprint.fromJson(entry as Map<String, dynamic>)).toList();
    fingerprints.addAll(imported);
    return imported.length;
  }

  double _difference(double live, double reference) => live - reference;

  Map<String, double> _reliabilityByBssid() {
    final result = <String, double>{};
    for (final bssid in fingerprints.expand((fingerprint) => fingerprint.rssiByBssid.keys).toSet()) {
      final values = fingerprints
          .where((fingerprint) => fingerprint.rssiByBssid.containsKey(bssid))
          .map((fingerprint) => fingerprint.rssiByBssid[bssid]!)
          .toList();
      final availability = values.length / fingerprints.length;
      if (availability < 0.4) continue;
      final localNoise = <double>[];
      for (final fingerprint in fingerprints) {
        final pointValues = fingerprint.samples
            .where((sample) => sample.rssiByBssid.containsKey(bssid))
            .map((sample) => sample.rssiByBssid[bssid]!)
            .toList();
        if (pointValues.length < 2) continue;
        final pointMean = pointValues.reduce((a, b) => a + b) / pointValues.length;
        final pointVariance = pointValues.map((value) => math.pow(value - pointMean, 2)).reduce((a, b) => a + b) / pointValues.length;
        localNoise.add(math.sqrt(pointVariance));
      }
      final standardDeviation = localNoise.isEmpty ? 2.0 : localNoise.reduce((a, b) => a + b) / localNoise.length;
      result[bssid] = availability / (1 + standardDeviation / 6);
    }
    return result;
  }

  Future<String> exportJson() async {
    if (fingerprints.isEmpty) {
      throw StateError('No WiFi fingerprints captured. Export cancelled.');
    }
    final payload = const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'type': 'wifi-fingerprint-session',
      'createdAt': DateTime.now().toIso8601String(),
      'fingerprints': fingerprints.map((fingerprint) => fingerprint.toJson()).toList(),
    });
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/wifi-fingerprints.json');
    await file.writeAsString(payload);
    await Clipboard.setData(ClipboardData(text: payload));
    return file.path;
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _resultsSub?.cancel();
    await _observationController.close();
    await _errorController.close();
  }
}