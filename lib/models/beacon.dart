import 'dart:ui';

/// A physical BLE beacon mounted at an aisle end, plus its position on the store map.
class Beacon {
  final String id;
  final String bleId;
  final int? major;
  final int? minor;
  final String name;
  final Offset position;

  const Beacon({
    required this.id,
    required this.bleId,
    required this.name,
    this.major,
    this.minor,
    required this.position,
  });

  String get normalizedBleId => bleId.toLowerCase();

  String? get fullBleKey {
    if (major != null && minor != null) {
      return '$normalizedBleId:$major:$minor';
    }
    return null;
  }

  bool matchesBleId(String bleId) {
    final normalizedKey = bleId.toLowerCase();
    if (normalizedKey == normalizedBleId) return true;
    if (fullBleKey != null && normalizedKey == fullBleKey) return true;
    if (!normalizedBleId.contains(':') && normalizedKey.contains(':')) {
      return normalizedKey.startsWith('$normalizedBleId:');
    }
    if (normalizedBleId.contains(':') && !normalizedKey.contains(':')) {
      return normalizedBleId.startsWith('$normalizedKey:');
    }

    // If both sides include the same major/minor pair, accept the match even
    // if the UUIDs differ. This makes the app resilient if the beacon
    // hardware UUIDs don't exactly match the store data but the beacon IDs
    // still use unique major/minor values.
    final keyParts = normalizedKey.split(':');
    final fullParts = fullBleKey?.split(':');
    if (keyParts.length == 3 && fullParts?.length == 3) {
      return keyParts[1] == fullParts![1] && keyParts[2] == fullParts[2];
    }
    return false;
  }

  factory Beacon.fromJson(Map<String, dynamic> json) {
    return Beacon(
      id: json['id'] as String,
      bleId: json['bleId'] as String,
      major: json['major'] as int?,
      minor: json['minor'] as int?,
      name: json['name'] as String,
      position: Offset(
        (json['x'] as num).toDouble(),
        (json['y'] as num).toDouble(),
      ),
    );
  }
}
