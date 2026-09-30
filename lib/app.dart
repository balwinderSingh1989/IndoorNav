import 'package:flutter/material.dart';

import 'models/store_map.dart';
import 'services/ble_scanner_service.dart';
import 'services/motion_service.dart';
import 'services/navigation_controller.dart';
import 'services/store_data_repository.dart';
import 'ui/screens/home_screen.dart';

class IndoorNavApp extends StatefulWidget {
  const IndoorNavApp({super.key});

  @override
  State<IndoorNavApp> createState() => _IndoorNavAppState();
}

class _IndoorNavAppState extends State<IndoorNavApp> {
  // Cached once so that hot-reload rebuilds don't create a new Future,
  // which would cause FutureBuilder to reset and recreate the
  // NavigationController without ever calling start() on it.
  late final Future<StoreMap> _storeMapFuture = StoreDataRepository().loadStoreMap();
  NavigationController? _controller;
  BleScannerService? _bleScanner;

  @override
  void dispose() {
    _controller?.dispose();
    _bleScanner?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Way Finder',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: FutureBuilder<StoreMap>(
        future: _storeMapFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _ErrorScreen(error: snapshot.error.toString());
          }
          final storeMap = snapshot.data;
          if (storeMap == null) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }

          _bleScanner ??= BleScannerService(
            // Filter mode: Use kalman for faster response with smoothness
            filterMode: RssiFilterMode.both,
            enableComparisonLogging: true,
            
            // ===== TUNING PARAMETERS (Sept 28, 16:45) =====
            // BALANCED TUNING (accuracy-optimized, slight delay acceptable):
            // Goal: Better noise immunity + prevent multipath flapping
            // Trade: ~100-200ms extra delay from aggressive, but much more stable
            
            // Rationale:
            // - measurementError 1.0: Kalman gain ~50%, blends equally (new 50%, old 50%)
            //   Smooths multipath spikes better than 0.6 while still responsive
            // - processNoise 0.03: Expect moderate RSSI variance (less volatile model)
            //   Reduces jitter in stationary zones
            // - initialError 2.5: Moderate initial uncertainty for steady convergence
            
            kalmanMeasurementError: 1.0,      // Balanced trust (Kalman gain ~50%)
            kalmanProcessNoise: 0.03,         // Moderate volatility model for 4-5m
            kalmanInitialError: 2.5,          // Steady convergence, ~500-700ms total
            
            // Reference tunings:
            // AGGRESSIVE (speed, 250-400ms, flaps at zone boundary):
            //   measurementError: 0.6, processNoise: 0.07, initialError: 3.5
            // BALANCED (accuracy, 500-700ms, stable):
            //   measurementError: 1.0, processNoise: 0.03, initialError: 2.5
            // SMOOTH (robust, 1000-1500ms, slow but very stable):
            //   measurementError: 1.5, processNoise: 0.01, initialError: 2.0
          );
          
          // Initialize beacon name lookup for logging
          final beaconNamesByKey = <String, String>{};
          for (final beacon in storeMap.beacons) {
            final key = beacon.fullBleKey ?? beacon.normalizedBleId;
            if (key != null) {
              beaconNamesByKey[key] = beacon.name;
            }
          }
          _bleScanner!.setBeaconNameLookup(beaconNamesByKey);
          
          _controller ??= NavigationController(
            storeMap: storeMap,
            bleScanner: _bleScanner!,
            motionService: MotionService(
              metersPerUnit: storeMap.metersPerUnit,
              mapNorthOffsetDegrees: storeMap.mapNorthOffsetDegrees,
            ),
          );

          return HomeScreen(
            controller: _controller!,
            bleScanner: _bleScanner!,
          );
        },
      ),
    );
  }
}

class _ErrorScreen extends StatelessWidget {
  const _ErrorScreen({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(child: Text('Failed to load store map:\n$error')),
    );
  }
}
