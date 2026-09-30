/// Represents a single beacon's fingerprint data in a zone
class BeaconSignature {
  final String uuid;
  final int major;
  final int minor;
  final List<int> rssiReadings; // Raw RSSI values in dBm

  BeaconSignature({
    required this.uuid,
    required this.major,
    required this.minor,
    required this.rssiReadings,
  });

  /// Calculate mean RSSI
  double get meanRssi {
    if (rssiReadings.isEmpty) return 0;
    return rssiReadings.reduce((a, b) => a + b) / rssiReadings.length;
  }

  /// Calculate standard deviation of RSSI
  double get stdDevRssi {
    if (rssiReadings.isEmpty) return 0;
    double mean = meanRssi;
    final variance =
        rssiReadings.map((r) => (r - mean) * (r - mean)).reduce((a, b) => a + b) /
            rssiReadings.length;
    return variance.isNaN ? 0 : variance.sqrt();
  }

  /// Get min/max RSSI
  int get minRssi => rssiReadings.isEmpty ? 0 : rssiReadings.reduce((a, b) => a < b ? a : b);
  int get maxRssi => rssiReadings.isEmpty ? 0 : rssiReadings.reduce((a, b) => a > b ? a : b);

  /// Beacon identifier
  String get beaconId => '$uuid:$major:$minor';

  toJson() => {
    'uuid': uuid,
    'major': major,
    'minor': minor,
    'rssiReadings': rssiReadings,
    'meanRssi': meanRssi,
    'stdDevRssi': stdDevRssi,
  };

  factory BeaconSignature.fromJson(Map<String, dynamic> json) {
    return BeaconSignature(
      uuid: json['uuid'],
      major: json['major'],
      minor: json['minor'],
      rssiReadings: List<int>.from(json['rssiReadings'] ?? []),
    );
  }
}

/// Zone fingerprint: collection of beacon signatures in a zone
class BeaconZoneFingerprint {
  final String zoneName;
  final DateTime capturedAt;
  final Map<String, BeaconSignature> beaconSignatures; // Key: beacon ID

  BeaconZoneFingerprint({
    required this.zoneName,
    required this.beaconSignatures,
    DateTime? capturedAt,
  }) : capturedAt = capturedAt ?? DateTime.now();

  toJson() => {
    'zoneName': zoneName,
    'capturedAt': capturedAt.toIso8601String(),
    'beaconSignatures': beaconSignatures.map((k, v) => MapEntry(k, v.toJson())),
  };

  factory BeaconZoneFingerprint.fromJson(Map<String, dynamic> json) {
    final signatures = (json['beaconSignatures'] as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, BeaconSignature.fromJson(v)));
    
    return BeaconZoneFingerprint(
      zoneName: json['zoneName'],
      beaconSignatures: signatures,
      capturedAt: DateTime.parse(json['capturedAt']),
    );
  }
}

/// Distance calculation result
class DistanceResult {
  final String zoneName;
  final double distance;
  final String algorithm;
  final int matchedBeaconCount;

  DistanceResult({
    required this.zoneName,
    required this.distance,
    required this.algorithm,
    required this.matchedBeaconCount,
  });

  @override
  String toString() =>
      'Zone: $zoneName, Distance: ${distance.toStringAsFixed(2)}, Algorithm: $algorithm, Beacons: $matchedBeaconCount';
}

/// Quality of the currently scanned beacon pattern against a selected zone.
class FingerprintQuality {
  const FingerprintQuality({
    required this.algorithm,
    required this.result,
    required this.matchesSelectedZone,
    required this.passesThreshold,
  });

  final BeaconDistanceAlgorithm algorithm;
  final DistanceResult? result;
  final bool matchesSelectedZone;
  final bool passesThreshold;

  bool get isSuccessful => result != null && matchesSelectedZone && passesThreshold;
}

/// Enum for distance calculation methods
enum BeaconDistanceAlgorithm {
  euclidean,
  mahalanobis,
  timeSeries,
}

extension on double {
  double sqrt() {
    if (this <= 0) return 0;
    var estimate = this;
    for (var iteration = 0; iteration < 12; iteration++) {
      estimate = (estimate + this / estimate) / 2;
    }
    return estimate;
  }
}

extension BeaconAlgorithmExt on BeaconDistanceAlgorithm {
  String get displayName {
    switch (this) {
      case BeaconDistanceAlgorithm.euclidean:
        return 'Euclidean';
      case BeaconDistanceAlgorithm.mahalanobis:
        return 'Mahalanobis';
      case BeaconDistanceAlgorithm.timeSeries:
        return 'Time-Series Correlation';
    }
  }

  String get description {
    switch (this) {
      case BeaconDistanceAlgorithm.euclidean:
        return 'Fast and simple (best for 3-5 zones)';
      case BeaconDistanceAlgorithm.mahalanobis:
        return 'Robust and accounts for variance';
      case BeaconDistanceAlgorithm.timeSeries:
        return 'Pattern-based matching';
    }
  }
}
