import 'package:flutter/material.dart';

import 'models/store_map.dart';
import 'services/activity_logger.dart';
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
  final ActivityLogger _logger = ActivityLogger();

  @override
  void dispose() {
    _controller?.dispose();
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
          _controller ??= NavigationController(
            storeMap: storeMap,
            bleScanner: BleScannerService(),
            motionService: MotionService(
              metersPerUnit: storeMap.metersPerUnit,
              mapNorthOffsetDegrees: storeMap.mapNorthOffsetDegrees,
            ),
            logger: _logger,
          );
          return HomeScreen(controller: _controller!, activityLogger: _logger);
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
