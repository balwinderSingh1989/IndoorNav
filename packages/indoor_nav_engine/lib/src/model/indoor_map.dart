/// A beacon identity and optional map position supplied by the host map JSON.
class IndoorBeacon {
  const IndoorBeacon({
    required this.id,
    required this.bleId,
    required this.name,
    this.major,
    this.minor,
    this.x,
    this.y,
  });

  final String id;
  final String bleId;
  final String name;
  final int? major;
  final int? minor;
  final double? x;
  final double? y;

  String get normalizedBleId => bleId.toLowerCase();

  factory IndoorBeacon.fromJson(Map<String, dynamic> json) => IndoorBeacon(
        id: json['id'] as String,
        bleId: json['bleId'] as String,
        name: json['name'] as String,
        major: json['major'] as int?,
        minor: json['minor'] as int?,
        x: (json['x'] as num?)?.toDouble(),
        y: (json['y'] as num?)?.toDouble(),
      );
}

/// An undirected navigable connection between two configured beacons.
class IndoorMapEdge {
  const IndoorMapEdge({required this.from, required this.to, required this.distanceMeters});

  final String from;
  final String to;
  final double distanceMeters;

  factory IndoorMapEdge.fromJson(Map<String, dynamic> json) => IndoorMapEdge(
        from: json['from'] as String,
        to: json['to'] as String,
        distanceMeters: (json['distanceMeters'] as num).toDouble(),
      );
}

/// Engine-facing map configuration. Presentation-only fields stay in the host app.
class IndoorMap {
  const IndoorMap({required this.beacons, required this.edges});

  final List<IndoorBeacon> beacons;
  final List<IndoorMapEdge> edges;

  factory IndoorMap.fromJson(Map<String, dynamic> json) => IndoorMap(
        beacons: (json['beacons'] as List<dynamic>)
            .map((beacon) => IndoorBeacon.fromJson(beacon as Map<String, dynamic>))
            .toList(growable: false),
        edges: (json['edges'] as List<dynamic>? ?? const [])
            .map((edge) => IndoorMapEdge.fromJson(edge as Map<String, dynamic>))
            .toList(growable: false),
      );

  IndoorBeacon? beaconById(String id) {
    for (final beacon in beacons) {
      if (beacon.id == id) return beacon;
    }
    return null;
  }

  bool areAdjacent(String firstBeaconId, String secondBeaconId) {
    return edges.any(
      (edge) =>
          (edge.from == firstBeaconId && edge.to == secondBeaconId) ||
          (edge.from == secondBeaconId && edge.to == firstBeaconId),
    );
  }
}
