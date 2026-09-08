import 'dart:ui' show Offset;

class WifiObservation {
  const WifiObservation({required this.timestamp, required this.rssiByBssid, this.ssidByBssid = const {}, this.scanRequestedAt, this.scanResultTimestampMicros});

  final DateTime timestamp;
  final Map<String, double> rssiByBssid;
  final Map<String, String> ssidByBssid;
  final DateTime? scanRequestedAt;
  final int? scanResultTimestampMicros;

  factory WifiObservation.fromJson(Map<String, dynamic> json) {
    return WifiObservation(
      timestamp: DateTime.parse(json['timestamp'] as String),
      rssiByBssid: (json['rssiByBssid'] as Map<String, dynamic>).map((key, value) => MapEntry(key, (value as num).toDouble())),
      ssidByBssid: (json['ssidByBssid'] as Map<String, dynamic>? ?? {}).map((key, value) => MapEntry(key, value as String)),
      scanRequestedAt: json['scanRequestedAt'] == null ? null : DateTime.parse(json['scanRequestedAt'] as String),
      scanResultTimestampMicros: (json['scanResultTimestampMicros'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'rssiByBssid': rssiByBssid,
        'ssidByBssid': ssidByBssid,
        'scanRequestedAt': scanRequestedAt?.toIso8601String(),
        'scanResultTimestampMicros': scanResultTimestampMicros,
      };
}

class WifiFingerprint {
  const WifiFingerprint({
    required this.id,
    required this.floorId,
    required this.position,
    required this.capturedAt,
    required this.rssiByBssid,
    required this.samples,
  });

  final String id;
  final String floorId;
  final Offset position;
  final DateTime capturedAt;
  final Map<String, double> rssiByBssid;
  final List<WifiObservation> samples;

  int get uniqueRssiVectorCount => samples.map((sample) => sample.rssiByBssid.toString()).toSet().length;

  factory WifiFingerprint.fromJson(Map<String, dynamic> json) {
    final rawSamples = (json['samples'] as List<dynamic>? ?? const [])
        .map((sample) => WifiObservation.fromJson(sample as Map<String, dynamic>))
        .toList();
    final rawValues = (json['rssiByBssid'] as Map<String, dynamic>? ?? {})
        .map((key, value) => MapEntry(key, (value as num).toDouble()));
    return WifiFingerprint(
      id: json['id'] as String,
      floorId: json['floorId'] as String? ?? 'default-floor',
      position: Offset((json['x'] as num).toDouble(), (json['y'] as num).toDouble()),
      capturedAt: DateTime.parse(json['capturedAt'] as String),
      rssiByBssid: rawValues,
      samples: rawSamples,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'floorId': floorId,
        'x': position.dx,
        'y': position.dy,
        'capturedAt': capturedAt.toIso8601String(),
        'rssiByBssid': rssiByBssid,
        'samples': samples.map((sample) => sample.toJson()).toList(),
        'samplesCaptured': samples.length,
        'uniqueRssiVectors': uniqueRssiVectorCount,
      };
}

class WifiMatch {
  const WifiMatch({required this.position, required this.distance, required this.neighborCount, required this.sharedAccessPointCount, required this.confidence, this.anchorBssid});

  final Offset position;
  final double distance;
  final int neighborCount;
  final int sharedAccessPointCount;
  final double confidence;
  final String? anchorBssid;
}

class WifiAnchorSuggestion {
  const WifiAnchorSuggestion({
    required this.bssid,
    required this.ssid,
    required this.coverage,
    required this.rssiSpread,
    required this.zoneSpread,
    required this.score,
  });

  final String bssid;
  final String ssid;
  final double coverage;
  final double rssiSpread;
  final double zoneSpread;
  final double score;
}