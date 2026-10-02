import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';

import '../models/beacon_fingerprint.dart';

class BeaconFingerprintService {
  static const _fingerprintFileName = 'beacon_fingerprints.json';

  final Map<String, BeaconZoneFingerprint> _fingerprints = {};
  BeaconDistanceAlgorithm _currentAlgorithm = BeaconDistanceAlgorithm.euclidean;

  double euclideanThreshold = 50.0;
  double mahalanobisThreshold = 3.0;
  double correlationThreshold = 0.6;

  BeaconDistanceAlgorithm get currentAlgorithm => _currentAlgorithm;
  List<BeaconDistanceAlgorithm> get availableAlgorithms =>
      BeaconDistanceAlgorithm.values;
  Map<String, BeaconZoneFingerprint> get fingerprints => _fingerprints;

  double confidenceFor(DistanceResult result) {
    switch (_currentAlgorithm) {
      case BeaconDistanceAlgorithm.euclidean:
        return (1 - result.distance / euclideanThreshold).clamp(0.0, 1.0);
      case BeaconDistanceAlgorithm.mahalanobis:
        return (1 - result.distance / mahalanobisThreshold).clamp(0.0, 1.0);
      case BeaconDistanceAlgorithm.timeSeries:
        return result.distance.clamp(0.0, 1.0);
    }
  }

  void setAlgorithm(BeaconDistanceAlgorithm algorithm) {
    _currentAlgorithm = algorithm;
  }

  Future<void> captureZoneFingerprint({
    required String zoneName,
    required List<BeaconReading> beaconReadings,
    int samplesPerBeacon = 30,
  }) async {
    if (beaconReadings.isEmpty) throw Exception('No beacon readings provided');

    final beaconRssiMap = <String, List<int>>{};
    for (final reading in beaconReadings) {
      final beaconId = '${reading.uuid}:${reading.major}:${reading.minor}';
      beaconRssiMap.putIfAbsent(beaconId, () => []).add(reading.rssi);
    }

    final signatures = <String, BeaconSignature>{};
    beaconRssiMap.forEach((beaconId, rssiList) {
      final parts = beaconId.split(':');
      signatures[beaconId] = BeaconSignature(
        uuid: parts.sublist(0, parts.length - 2).join(':'),
        major: int.parse(parts[parts.length - 2]),
        minor: int.parse(parts.last),
        rssiReadings: rssiList,
      );
    });

    _fingerprints[zoneName] = BeaconZoneFingerprint(
      zoneName: zoneName,
      beaconSignatures: signatures,
    );
    await _saveFingerprints();
  }

  List<DistanceResult> evaluate(
    List<BeaconReading> currentReadings,
    BeaconDistanceAlgorithm algorithm,
  ) {
    if (_fingerprints.isEmpty) {
      throw Exception('No fingerprints available. Capture zones first.');
    }
    if (currentReadings.isEmpty)
      throw Exception('No beacon readings available');

    final results = <DistanceResult>[];
    for (final entry in _fingerprints.entries) {
      final fingerprint = entry.value;
      final distance = switch (algorithm) {
        BeaconDistanceAlgorithm.euclidean =>
          _calculateEuclideanDistance(currentReadings, fingerprint),
        BeaconDistanceAlgorithm.mahalanobis =>
          _calculateMahalanobisDistance(currentReadings, fingerprint),
        BeaconDistanceAlgorithm.timeSeries =>
          _calculateTimeSeriesDistance(currentReadings, fingerprint),
      };
      results.add(DistanceResult(
        zoneName: entry.key,
        distance: distance,
        algorithm: algorithm.displayName,
        matchedBeaconCount: _countMatchedBeacons(currentReadings, fingerprint),
      ));
    }

    results.sort((a, b) => algorithm == BeaconDistanceAlgorithm.timeSeries
        ? b.distance.compareTo(a.distance)
        : a.distance.compareTo(b.distance));
    return results;
  }

  Future<DistanceResult?> detectZone(
      List<BeaconReading> currentReadings) async {
    final results = evaluate(currentReadings, _currentAlgorithm);
    return results.isEmpty ? null : results.first;
  }

  double _calculateEuclideanDistance(
    List<BeaconReading> currentReadings,
    BeaconZoneFingerprint fingerprint,
  ) {
    final current = _currentRssiMap(currentReadings);
    var sumSquares = 0.0;
    var count = 0;
    for (final entry in fingerprint.beaconSignatures.entries) {
      final value = current[entry.key];
      if (value == null) continue;
      final diff = value - entry.value.meanRssi;
      sumSquares += diff * diff;
      count++;
    }
    if (count == 0) return double.infinity;
    final result = math.sqrt(sumSquares / count);
    return result.isNaN ? double.infinity : result;
  }

  double _calculateMahalanobisDistance(
    List<BeaconReading> currentReadings,
    BeaconZoneFingerprint fingerprint,
  ) {
    final current = _currentRssiMap(currentReadings);
    var sum = 0.0;
    var count = 0;
    for (final entry in fingerprint.beaconSignatures.entries) {
      final value = current[entry.key];
      if (value == null) continue;
      final stdDev = math.max(entry.value.stdDevRssi, 0.1);
      final term = (value - entry.value.meanRssi) / stdDev;
      sum += term * term;
      count++;
    }
    if (count == 0) return double.infinity;
    final result = math.sqrt(sum / count);
    return result.isNaN ? double.infinity : result;
  }

  double _calculateTimeSeriesDistance(
    List<BeaconReading> currentReadings,
    BeaconZoneFingerprint fingerprint,
  ) {
    final ids = <String>{
      ...currentReadings.map(_readingId),
      ...fingerprint.beaconSignatures.keys,
    }.toList();
    final current = _currentRssiMap(currentReadings);
    final currentVector = [
      for (final id in ids) (current[id] ?? -100).toDouble()
    ];
    final storedVector = [
      for (final id in ids) fingerprint.beaconSignatures[id]?.meanRssi ?? -100,
    ];
    return _pearsonCorrelation(currentVector, storedVector);
  }

  double _pearsonCorrelation(List<double> x, List<double> y) {
    if (x.length != y.length || x.isEmpty) return 0;
    final meanX = x.reduce((a, b) => a + b) / x.length;
    final meanY = y.reduce((a, b) => a + b) / y.length;
    var numerator = 0.0;
    var sumSqX = 0.0;
    var sumSqY = 0.0;
    for (var index = 0; index < x.length; index++) {
      final dx = x[index] - meanX;
      final dy = y[index] - meanY;
      numerator += dx * dy;
      sumSqX += dx * dx;
      sumSqY += dy * dy;
    }
    final denominator = math.sqrt(sumSqX * sumSqY);
    if (denominator == 0) return 0;
    return (numerator / denominator).clamp(-1.0, 1.0);
  }

  int _countMatchedBeacons(
    List<BeaconReading> readings,
    BeaconZoneFingerprint fingerprint,
  ) {
    final ids = readings.map(_readingId).toSet();
    return ids.where(fingerprint.beaconSignatures.containsKey).length;
  }

  Map<String, int> _currentRssiMap(List<BeaconReading> readings) => {
        for (final reading in readings) _readingId(reading): reading.rssi,
      };

  String _readingId(BeaconReading reading) =>
      '${reading.uuid}:${reading.major}:${reading.minor}';

  Future<void> deleteZoneFingerprint(String zoneName) async {
    _fingerprints.remove(zoneName);
    await _saveFingerprints();
  }

  Future<void> clearAllFingerprints() async {
    _fingerprints.clear();
    await _saveFingerprints();
  }

  Future<void> loadFingerprints() async {
    try {
      final file = await _getFingerprintFile();
      if (!await file.exists()) return;
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      _fingerprints
        ..clear()
        ..addAll(json.map((zone, data) => MapEntry(
              zone,
              BeaconZoneFingerprint.fromJson(data as Map<String, dynamic>),
            )));
    } catch (_) {
      _fingerprints.clear();
    }
  }

  Future<void> _saveFingerprints() async {
    try {
      final file = await _getFingerprintFile();
      await file.writeAsString(
        jsonEncode(
            _fingerprints.map((zone, value) => MapEntry(zone, value.toJson()))),
        flush: true,
      );
    } catch (_) {}
  }

  Future<File> _getFingerprintFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fingerprintFileName');
  }

  String exportFingerprints() => JsonEncoder.withIndent('  ').convert(
        _fingerprints.map((zone, value) => MapEntry(zone, value.toJson())),
      );

  Future<void> importFingerprints(String jsonString) async {
    final json = jsonDecode(jsonString) as Map<String, dynamic>;
    _fingerprints
      ..clear()
      ..addAll(json.map((zone, data) => MapEntry(
            zone,
            BeaconZoneFingerprint.fromJson(data as Map<String, dynamic>),
          )));
    await _saveFingerprints();
  }
}
