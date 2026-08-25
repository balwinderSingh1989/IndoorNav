import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/beacon.dart';
import '../../models/product.dart';
import '../../services/navigation_controller.dart';
import '../widgets/live_navigation_card.dart';
import '../widgets/section_header.dart';

/// The dedicated full-screen live tracking view. Reached by picking a
/// product or zone on [HomeScreen] or ProductListingScreen (which call
/// [NavigationController.setDestination] before pushing this screen), or
/// from the home screen's own map preview for a focused view of the same
/// [LiveNavigationCard].
class NavigationScreen extends StatefulWidget {
  const NavigationScreen({super.key, required this.controller, this.catalogOffers = const []});

  final NavigationController controller;

  /// Forwarded into [LiveNavigationCard] so the offers banner stays live
  /// here too, not just on the home screen's map preview.
  final List<Product> catalogOffers;

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  StreamSubscription<String>? _scanErrorSub;
  StreamSubscription<String>? _motionErrorSub;

  @override
  void initState() {
    super.initState();
    // NavigationController.start() is called once, from HomeScreen — BLE
    // scanning/motion tracking run continuously for the app's lifetime, not
    // just while this screen is on screen. Error snackbars are re-listened
    // here too, so they surface wherever the user currently is.
    _scanErrorSub = widget.controller.bleScanner.errors.listen(_showError);
    _motionErrorSub = widget.controller.motionService.errors.listen(_showError);
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
    );
  }

  @override
  void dispose() {
    _scanErrorSub?.cancel();
    _motionErrorSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final storeMap = controller.storeMap;
    final colorScheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: colorScheme.surface,
          appBar: AppBar(
            title: Text(controller.destinationBeacon?.name ?? 'Live Navigation'),
            actions: [
              PopupMenuButton<Beacon>(
                icon: const Icon(Icons.place_outlined),
                tooltip: 'Choose destination',
                onSelected: controller.setDestination,
                itemBuilder: (context) =>
                    storeMap.beacons.map((b) => PopupMenuItem(value: b, child: Text(b.name))).toList(),
              ),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                SectionHeader(
                  icon: Icons.map_outlined,
                  label: 'Live map',
                  trailing: IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Clear route',
                    visualDensity: VisualDensity.compact,
                    onPressed: controller.clearDestination,
                  ),
                ),
                const SizedBox(height: 12),
                LiveNavigationCard(controller: controller, catalogOffers: widget.catalogOffers),
              ],
            ),
          ),
        );
      },
    );
  }
}
