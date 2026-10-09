/// Represents a single beacon's fingerprint data in a zone.
class BeaconSignature {
  final String uuid;
  final int major;
  final int minor;
  final List<int> rssiReadings;

  BeaconSignature({
    required this.uuid,
    required this.major,
    required this.minor,
    required this.rssiReadings,
  });

  double get meanRssi => rssiReadings.isEmpty
      ? 0
      : rssiReadings.reduce((a, b) => a + b) / rssiReadings.length;

  double get stdDevRssi {
    if (rssiReadings.isEmpty) return 0;
    final mean = meanRssi;
    final variance = rssiReadings
            .map((r) => (r - mean) * (r - mean))
            .reduce((a, b) => a + b) /
        rssiReadings.length;
    return variance.isNaN ? 0 : variance.sqrt();
  }

  int get minRssi =>
      rssiReadings.isEmpty ? 0 : rssiReadings.reduce((a, b) => a < b ? a : b);

  int get maxRssi =>
      rssiReadings.isEmpty ? 0 : rssiReadings.reduce((a, b) => a > b ? a : b);

  String get beaconId => '$uuid:$major:$minor';

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'major': major,
        'minor': minor,
        'rssiReadings': rssiReadings,
        'meanRssi': meanRssi,
        'stdDevRssi': stdDevRssi,
      };

  factory BeaconSignature.fromJson(Map<String, dynamic> json) =>
      BeaconSignature(
        uuid: json['uuid'] as String,
        major: (json['major'] as num).toInt(),
        minor: (json['minor'] as num).toInt(),
        rssiReadings: List<int>.from(json['rssiReadings'] ?? const []),
      );
}

class BeaconZoneFingerprint {
  final String zoneName;
  final DateTime capturedAt;
  final Map<String, BeaconSignature> beaconSignatures;

  BeaconZoneFingerprint({
    required this.zoneName,
    required this.beaconSignatures,
    DateTime? capturedAt,
  }) : capturedAt = capturedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'zoneName': zoneName,
        'capturedAt': capturedAt.toIso8601String(),
        'beaconSignatures': beaconSignatures.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
      };

  factory BeaconZoneFingerprint.fromJson(Map<String, dynamic> json) {
    final signatures = (json['beaconSignatures'] as Map<String, dynamic>).map(
      (key, value) => MapEntry(
        key,
        BeaconSignature.fromJson(value as Map<String, dynamic>),
      ),
    );
    return BeaconZoneFingerprint(
      zoneName: json['zoneName'] as String,
      beaconSignatures: signatures,
      capturedAt: DateTime.parse(json['capturedAt'] as String),
    );
  }
}

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

  bool get isSuccessful =>
      result != null && matchesSelectedZone && passesThreshold;
}

enum BeaconDistanceAlgorithm { euclidean, mahalanobis, timeSeries }

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

class BeaconReading {
  final String uuid;
  final int major;
  final int minor;
  final int rssi;
  final DateTime timestamp;

  BeaconReading({
    required this.uuid,
    required this.major,
    required this.minor,
    required this.rssi,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() => 'Beacon($uuid:$major:$minor) RSSI:$rssi dBm';
}
