import 'package:flutter/material.dart';
import 'package:indoor_nav_engine/indoor_nav_engine.dart';

import 'services/navigation_config_repository.dart';
import 'services/store_data_repository.dart';
import 'ui/screens/home_screen.dart';

RssiFilterMode _filterModeFromConfig(String value) {
  switch (value.toLowerCase()) {
    case 'median':
      return RssiFilterMode.median;
    case 'kalman':
      return RssiFilterMode.kalman;
    case 'both':
    default:
      return RssiFilterMode.both;
  }
}

class IndoorNavApp extends StatefulWidget {
  const IndoorNavApp({super.key});

  @override
  State<IndoorNavApp> createState() => _IndoorNavAppState();
}

class _IndoorNavAppState extends State<IndoorNavApp> {
  // Cached once so that hot-reload rebuilds don't create a new Future,
  // which would cause FutureBuilder to reset and recreate the
  // NavigationController without ever calling start() on it.
  late final Future<StoreMap> _storeMapFuture =
      StoreDataRepository().loadStoreMap();
  late final Future<IndoorNavConfig> _navigationConfigFuture =
      NavigationConfigRepository().load();
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
            return const Scaffold(
                body: Center(child: CircularProgressIndicator()));
          }

          return FutureBuilder<IndoorNavConfig>(
            future: _navigationConfigFuture,
            builder: (context, configSnapshot) {
              if (configSnapshot.hasError) {
                return _ErrorScreen(error: configSnapshot.error.toString());
              }
              final navigationConfig = configSnapshot.data;
              if (navigationConfig == null) {
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }

              _bleScanner ??= BleScannerService(
                iosProximityUuids: storeMap.beacons
                    .map((beacon) => beacon.bleId)
                    .where((uuid) => uuid.isNotEmpty)
                    .toSet()
                    .toList(growable: false),
                rollingWindow: navigationConfig.rollingWindow,
                filterMode: _filterModeFromConfig(navigationConfig.filterMode),
                enableComparisonLogging:
                    navigationConfig.enableComparisonLogging,
                kalmanMeasurementError: navigationConfig.kalmanMeasurementError,
                kalmanProcessNoise: navigationConfig.kalmanProcessNoise,
                kalmanInitialError: navigationConfig.kalmanInitialError,
                staleBeaconTimeout: navigationConfig.staleBeaconTimeout,
                staleSweepInterval: navigationConfig.staleSweepInterval,
                watchdogNoDeviceThreshold:
                    navigationConfig.watchdogNoDeviceThreshold,
                watchdogCheckInterval: navigationConfig.watchdogCheckInterval,
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
                observationSource: _bleScanner!,
                motionService: MotionService(
                  metersPerUnit: storeMap.metersPerUnit,
                  mapNorthOffsetDegrees: storeMap.mapNorthOffsetDegrees,
                ),
                navigationConfig: navigationConfig,
              );

              return HomeScreen(
                controller: _controller!,
                bleScanner: _bleScanner!,
              );
            },
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
