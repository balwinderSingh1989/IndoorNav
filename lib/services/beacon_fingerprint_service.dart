import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:path_provider/path_provider.dart';
import '../models/beacon_fingerprint.dart';

class BeaconFingerprintService {
  static const String _fingerprintFileName = 'beacon_fingerprints.json';
  
  final Map<String, BeaconZoneFingerprint> _fingerprints = {};
  BeaconDistanceAlgorithm _currentAlgorithm = BeaconDistanceAlgorithm.euclidean;
  
  double euclideanThreshold = 50.0; // Tunable threshold
  double mahalanobisThreshold = 3.0; // Mahalanobis distance threshold
  double correlationThreshold = 0.6; // Correlation threshold (0-1)

  /// Get current algorithm
  BeaconDistanceAlgorithm get currentAlgorithm => _currentAlgorithm;

  /// Switch to different algorithm
  void setAlgorithm(BeaconDistanceAlgorithm algorithm) {
    _currentAlgorithm = algorithm;
    print('🔄 Switched to ${algorithm.displayName} algorithm');
  }

  /// Get all available algorithms
  List<BeaconDistanceAlgorithm> get availableAlgorithms =>
      BeaconDistanceAlgorithm.values;

  /// Capture beacon fingerprint for a zone
  Future<void> captureZoneFingerprint({
    required String zoneName,
    required List<BeaconReading> beaconReadings,
    int samplesPerBeacon = 30,
  }) async {
    if (beaconReadings.isEmpty) {
      throw Exception('No beacon readings provided');
    }

    // Group readings by beacon
    Map<String, List<int>> beaconRssiMap = {};
    for (var reading in beaconReadings) {
      String beaconId = '${reading.uuid}:${reading.major}:${reading.minor}';
      beaconRssiMap.putIfAbsent(beaconId, () => []);
      beaconRssiMap[beaconId]!.add(reading.rssi);
    }

    // Create signatures
    Map<String, BeaconSignature> signatures = {};
    beaconRssiMap.forEach((beaconId, rssiList) {
      final parts = beaconId.split(':');
      signatures[beaconId] = BeaconSignature(
        uuid: parts[0],
        major: int.parse(parts[1]),
        minor: int.parse(parts[2]),
        rssiReadings: rssiList,
      );
    });

    final fingerprint = BeaconZoneFingerprint(
      zoneName: zoneName,
      beaconSignatures: signatures,
    );

    _fingerprints[zoneName] = fingerprint;
    await _saveFingerprints();

    print('✅ Captured beacon fingerprint for zone: $zoneName');
    print('   Beacons: ${signatures.length}, Samples: ${beaconReadings.length}');
  }

  /// Evaluate every saved zone using [algorithm].
  List<DistanceResult> evaluate(
    List<BeaconReading> currentReadings,
    BeaconDistanceAlgorithm algorithm,
  ) {
    if (_fingerprints.isEmpty) {
      throw Exception('No fingerprints available. Capture zones first.');
    }

    if (currentReadings.isEmpty) {
      throw Exception('No beacon readings available');
    }

    List<DistanceResult> results = [];

    for (var entry in _fingerprints.entries) {
      final zoneName = entry.key;
      final fingerprint = entry.value;

      double distance;
      int matchedBeacons = 0;

      switch (algorithm) {
        case BeaconDistanceAlgorithm.euclidean:
          distance = _calculateEuclideanDistance(currentReadings, fingerprint);
          matchedBeacons = _countMatchedBeacons(currentReadings, fingerprint);
          break;

        case BeaconDistanceAlgorithm.mahalanobis:
          distance = _calculateMahalanobisDistance(currentReadings, fingerprint);
          matchedBeacons = _countMatchedBeacons(currentReadings, fingerprint);
          break;

        case BeaconDistanceAlgorithm.timeSeries:
          distance = _calculateTimeSeriesDistance(currentReadings, fingerprint);
          matchedBeacons = _countMatchedBeacons(currentReadings, fingerprint);
          break;
      }

      results.add(DistanceResult(
        zoneName: zoneName,
        distance: distance,
        algorithm: algorithm.displayName,
        matchedBeaconCount: matchedBeacons,
      ));
    }

    // Sort by distance (lower is better for Euclidean/Mahalanobis, higher for correlation)
    results.sort((a, b) {
      if (algorithm == BeaconDistanceAlgorithm.timeSeries) {
        return b.distance.compareTo(a.distance); // Higher correlation = better
      }
      return a.distance.compareTo(b.distance); // Lower distance = better
    });

    return results;
  }

  /// Detect the best matching zone using the selected algorithm.
  Future<DistanceResult?> detectZone(List<BeaconReading> currentReadings) async {
    final results = evaluate(currentReadings, _currentAlgorithm);
    return results.isEmpty ? null : results.first;
  }

  /// ALGORITHM 1: Euclidean Distance
  /// D = sqrt((RSSI1-RSSI2)² + (RSSI3-RSSI4)² + ...)
  double _calculateEuclideanDistance(
    List<BeaconReading> currentReadings,
    BeaconZoneFingerprint fingerprint,
  ) {
    double sumSquares = 0;
    int count = 0;

    // Create map of current readings
    Map<String, int> currentRssiMap = {};
    for (var reading in currentReadings) {
      String beaconId = '${reading.uuid}:${reading.major}:${reading.minor}';
      currentRssiMap[beaconId] = reading.rssi;
    }

    // Compare with stored fingerprint
    fingerprint.beaconSignatures.forEach((beaconId, signature) {
      if (currentRssiMap.containsKey(beaconId)) {
        int currentRssi = currentRssiMap[beaconId]!;
        double storedMeanRssi = signature.meanRssi;
        double diff = currentRssi - storedMeanRssi;
        sumSquares += diff * diff;
        count++;
      }
    });

    if (count == 0) return double.infinity;
    final rmsDistance = math.sqrt(sumSquares / count);
    return rmsDistance.isNaN ? double.infinity : rmsDistance;
  }

  /// ALGORITHM 2: Mahalanobis Distance
  /// D = sqrt((RSSI - μ)ᵀ × Σ⁻¹ × (RSSI - μ))
  /// Accounts for variance and covariance in the data
  double _calculateMahalanobisDistance(
    List<BeaconReading> currentReadings,
    BeaconZoneFingerprint fingerprint,
  ) {
    // Create map of current readings
    Map<String, int> currentRssiMap = {};
    for (var reading in currentReadings) {
      String beaconId = '${reading.uuid}:${reading.major}:${reading.minor}';
      currentRssiMap[beaconId] = reading.rssi;
    }

    double mahalanobisSum = 0;
    int count = 0;

    fingerprint.beaconSignatures.forEach((beaconId, signature) {
      if (currentRssiMap.containsKey(beaconId)) {
        double currentRssi = currentRssiMap[beaconId]!.toDouble();
        double mean = signature.meanRssi;
        double stdDev = signature.stdDevRssi;

        // Avoid division by zero
        if (stdDev < 0.1) stdDev = 0.1;

        // Mahalanobis: (x - μ)² / σ²
        double term = ((currentRssi - mean) / stdDev);
        mahalanobisSum += term * term;
        count++;
      }
    });

    if (count == 0) return double.infinity;
    final result = math.sqrt(mahalanobisSum / count);
    return result.isNaN ? double.infinity : result;
  }

  /// ALGORITHM 3: Time-Series Correlation
  /// Matches beacon signal patterns (correlation between beacon lists)
  /// Returns value between 0 and 1 (1 = perfect match)
  double _calculateTimeSeriesDistance(
    List<BeaconReading> currentReadings,
    BeaconZoneFingerprint fingerprint,
  ) {
    // Create vectors of RSSI values in consistent order
    final allBeaconIds = <String>{};
    
    // Collect all beacon IDs from both current and stored
    for (var reading in currentReadings) {
      allBeaconIds.add('${reading.uuid}:${reading.major}:${reading.minor}');
    }
    fingerprint.beaconSignatures.forEach((id, _) => allBeaconIds.add(id));
    
    final beaconIds = allBeaconIds.toList();

    // Create vector for current readings
    List<double> currentVector = [];
    for (final beaconId in beaconIds) {
      double rssi = -100; // Default weak signal
      for (var reading in currentReadings) {
        String readingId =
            '${reading.uuid}:${reading.major}:${reading.minor}';
        if (readingId == beaconId) {
          rssi = reading.rssi.toDouble();
          break;
        }
      }
      currentVector.add(rssi);
    }

    // Create vector for stored fingerprint
    List<double> storedVector = [];
    for (final beaconId in beaconIds) {
      double rssi = -100;
      if (fingerprint.beaconSignatures.containsKey(beaconId)) {
        rssi = fingerprint.beaconSignatures[beaconId]!.meanRssi;
      }
      storedVector.add(rssi);
    }

    // Calculate Pearson correlation coefficient
    double correlation = _pearsonCorrelation(currentVector, storedVector);
    
    // Convert to distance (0 = perfect match, closer to 0 is better)
    // But return correlation for time-series (higher = better match)
    return correlation;
  }

  /// Calculate Pearson correlation coefficient between two vectors
  double _pearsonCorrelation(List<double> x, List<double> y) {
    if (x.length != y.length || x.isEmpty) return 0;

    double meanX = x.reduce((a, b) => a + b) / x.length;
    double meanY = y.reduce((a, b) => a + b) / y.length;

    double numerator = 0;
    double sumSqX = 0;
    double sumSqY = 0;

    for (int i = 0; i < x.length; i++) {
      double dx = x[i] - meanX;
      double dy = y[i] - meanY;
      numerator += dx * dy;
      sumSqX += dx * dx;
      sumSqY += dy * dy;
    }

    final denominator = math.sqrt(sumSqX * sumSqY);
    if (denominator == 0) return 0;

    double correlation = numerator / denominator;
    return correlation.clamp(-1.0, 1.0);
  }

  /// Count how many beacons matched
  int _countMatchedBeacons(
    List<BeaconReading> currentReadings,
    BeaconZoneFingerprint fingerprint,
  ) {
    Set<String> currentIds = currentReadings
        .map((r) => '${r.uuid}:${r.major}:${r.minor}')
        .toSet();
    
    return currentIds
        .where((id) => fingerprint.beaconSignatures.containsKey(id))
        .length;
  }

  /// Get all captured fingerprints
  Map<String, BeaconZoneFingerprint> get fingerprints => _fingerprints;

  /// Delete a zone fingerprint
  Future<void> deleteZoneFingerprint(String zoneName) async {
    _fingerprints.remove(zoneName);
    await _saveFingerprints();
    print('🗑️  Deleted fingerprint for zone: $zoneName');
  }

  /// Clear all fingerprints
  Future<void> clearAllFingerprints() async {
    _fingerprints.clear();
    await _saveFingerprints();
    print('🗑️  Cleared all fingerprints');
  }

  /// Load fingerprints from storage
  Future<void> loadFingerprints() async {
    try {
      final file = await _getFingerprintFile();
      if (!await file.exists()) {
        print('ℹ️  No saved beacon fingerprints found');
        return;
      }

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;

      _fingerprints.clear();
      json.forEach((zoneName, data) {
        _fingerprints[zoneName] =
            BeaconZoneFingerprint.fromJson(data);
      });

      print('✅ Loaded ${_fingerprints.length} beacon fingerprints');
    } catch (e) {
      print('❌ Error loading fingerprints: $e');
    }
  }

  /// Save fingerprints to storage
  Future<void> _saveFingerprints() async {
    try {
      final file = await _getFingerprintFile();
      final json = _fingerprints.map(
        (zoneName, fingerprint) =>
            MapEntry(zoneName, fingerprint.toJson()),
      );
      await file.writeAsString(jsonEncode(json), flush: true);
      print('✅ Saved ${_fingerprints.length} beacon fingerprints');
    } catch (e) {
      print('❌ Error saving fingerprints: $e');
    }
  }

  /// Get fingerprint file path
  Future<File> _getFingerprintFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fingerprintFileName');
  }

  /// Export fingerprints as JSON
  String exportFingerprints() {
    final json = _fingerprints.map(
      (zoneName, fingerprint) =>
          MapEntry(zoneName, fingerprint.toJson()),
    );
    return JsonEncoder.withIndent('  ').convert(json);
  }

  /// Import fingerprints from JSON
  Future<void> importFingerprints(String jsonString) async {
    try {
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      _fingerprints.clear();
      json.forEach((zoneName, data) {
        _fingerprints[zoneName] =
            BeaconZoneFingerprint.fromJson(data);
      });
      await _saveFingerprints();
      print('✅ Imported ${_fingerprints.length} beacon fingerprints');
    } catch (e) {
      print('❌ Error importing fingerprints: $e');
      rethrow;
    }
  }
}

/// Simple beacon reading data class
class BeaconReading {
  final String uuid;
  final int major;
  final int minor;
  final int rssi; // Signal strength in dBm (negative value)
  final DateTime timestamp;

  BeaconReading({
    required this.uuid,
    required this.major,
    required this.minor,
    required this.rssi,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() =>
      'Beacon($uuid:$major:$minor) RSSI:$rssi dBm';
}
