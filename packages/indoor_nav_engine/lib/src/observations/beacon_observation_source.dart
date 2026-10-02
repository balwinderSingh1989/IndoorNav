import 'dart:async';

/// Hardware-neutral RSSI observations consumed by the navigation engine.
///
/// Implementations may use iBeacon/CoreLocation, generic BLE advertisements,
/// Eddystone UID/URL, Wi-Fi, or another radio. The identifier must be a stable
/// key that the configured map can resolve to a beacon.
abstract interface class BeaconObservationSource {
  Stream<Map<String, double>> get rssiStream;

  Stream<String> get errors;

  Future<void> startScan();

  void stopScan();
  void dispose();
}
