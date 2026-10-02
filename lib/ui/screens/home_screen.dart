import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../models/product.dart';
import '../../models/product_category.dart';
import '../../services/analytics_service.dart';
import '../../services/catalog_api_service.dart';
import 'package:indoor_nav_engine/indoor_nav_engine.dart';
import '../utils/icon_lookup.dart';
import '../utils/zone_assignment.dart';
import '../widgets/live_navigation_card.dart';
import '../widgets/product_search_delegate.dart';
import '../widgets/section_header.dart';
import 'beacon_settings_screen.dart';
import '../beacon_fingerprint_screen.dart';
import 'logs_screen.dart';
import 'navigation_screen.dart';
import 'product_listing_screen.dart';

/// Landing screen: search and a browsable category grid, both backed live
/// by the Ace Hardware catalog API — tapping a category opens
/// [ProductListingScreen]; tapping a product (there, or in search) is
/// assigned a zone (see [assignZone] — the catalog has no notion of this
/// app's beacon graph) and opens [NavigationScreen].
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.bleScanner,
    this.activityLogger,
  });

  final NavigationController controller;
  final BleScannerService bleScanner;
  final ActivityLogger? activityLogger;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  StreamSubscription<String>? _scanErrorSub;
  StreamSubscription<String>? _motionErrorSub;
  StreamSubscription<Beacon>? _zoneEnteredSub;

  late final ActivityLogger _activityLogger;
  final _analytics = AnalyticsService();
  final _catalogApi = CatalogApiService();

  List<ProductCategory>? _categories;
  Object? _categoriesError;
  List<Product> _offerProducts = const [];
  bool _motionPermissionDialogVisible = false;
  final _homeFingerprintService = BeaconFingerprintService();
  late final BeaconFingerprintController _homeFingerprintController;
  final _fingerprintFusionSelector = FingerprintFusionSelector();
  String? _confirmedFingerprintZoneId;

  @override
  void initState() {
    super.initState();
    _activityLogger = widget.activityLogger ?? ActivityLogger();
    WidgetsBinding.instance.addObserver(this);
    // Started once, here, at app launch — BLE/motion tracking should run
    // for the app's whole lifetime, not just while the map screen happens
    // to be the visible route.
    widget.controller.start();
    _scanErrorSub = widget.bleScanner.errors.listen((message) {
      _activityLogger.log('BLE error: $message');
      _showError(message);
    });
    _homeFingerprintController = BeaconFingerprintController(
      _homeFingerprintService,
      widget.bleScanner,
      widget.controller.storeMap.beacons,
    )..addListener(_onFingerprintControllerChanged);
    _homeFingerprintController.init();
    _motionErrorSub = widget.controller.motionService.errors.listen((message) {
      _activityLogger.log('Motion error: $message');
      if (message.startsWith('Motion permission denied')) {
        _showMotionPermissionDialog();
        return;
      }
      _showError(message);
    });
    _zoneEnteredSub =
        widget.controller.zoneEnteredStream.listen(_onZoneEntered);
    // zoneEnteredStream fires once per *confirmed* zone change (debounced
    // upstream in NavigationController) — the same signal drives both the
    // dwell-time analytics file and the general activity log, so "time

    // spent per zone" and "what happened when" both start counting from
    // app launch, not from whenever a destination happens to be picked.
    _analytics.start(widget.controller.zoneEnteredStream);
    _activityLogger.log('App started');
    _loadCategories();
  }

  void _onFingerprintControllerChanged() {
    final candidate = _homeFingerprintController.fusionCandidate;
    final committed = _fingerprintFusionSelector.update(candidate);
    if (committed != null) _confirmedFingerprintZoneId = committed;
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Leaving the app (backgrounded, or on the way to being closed
    // outright) drops the in-progress route — coming back should feel
    // like a fresh start, not resume a stale destination/path from
    // whatever the user was doing before. BLE/PDR tracking itself keeps
    // running regardless; only the chosen destination/route resets.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      widget.controller.clearDestination();
      // Close out whatever zone visit is in progress rather than losing it
      // — there's no further zoneEnteredStream event coming if the app
      // doesn't reopen.
      _analytics.flush();
      _activityLogger.log('App backgrounded/closed');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
    );
  }

  Future<void> _showMotionPermissionDialog() async {
    if (!mounted || _motionPermissionDialogVisible) return;
    _motionPermissionDialogVisible = true;
    final openSettings = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Motion permission needed'),
        content: const Text(
          'Step tracking needs motion permission to estimate movement between beacon updates. You can enable it in system settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    _motionPermissionDialogVisible = false;

    if (openSettings != true) return;
    await openAppSettings();
    if (!mounted) return;
    await widget.controller.motionService.start();
  }

  void _onZoneEntered(Beacon zone) {
    // Offers are shown as an inline banner in LiveNavigationCard
    // (ZoneOffersBanner), reactively driven off currentBeacon — this
    // listener now exists purely to log the zone change.
    _activityLogger.log('Zone entered: ${zone.id} (${zone.name})');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanErrorSub?.cancel();
    _homeFingerprintController
      ..removeListener(_onFingerprintControllerChanged)
      ..dispose();
    _motionErrorSub?.cancel();
    _zoneEnteredSub?.cancel();
    _analytics.dispose();
    _catalogApi.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    try {
      final categories = await _catalogApi.getCategoryTree();
      if (!mounted) return;
      setState(() {
        // Top-level, non-empty categories only — deep drill-down isn't
        // needed here since tapping a category goes straight to its
        // product listing (falling back to its subcategories — see
        // [CatalogApiService.getProductsForCategory]).
        _categories = categories.where((c) => c.productCount > 0).toList();
        _categoriesError = null;
      });
      ProductCategory? offersCategory;
      for (final c in categories) {
        if (c.name.toLowerCase() == 'offers') {
          offersCategory = c;
          break;
        }
      }
      if (offersCategory != null) _loadOfferProducts(offersCategory);
    } catch (e) {
      if (!mounted) return;
      setState(() => _categoriesError = e);
    }
  }

  Future<void> _loadOfferProducts(ProductCategory offersCategory) async {
    try {
      final products = await _catalogApi.getProductsForCategory(offersCategory);
      if (!mounted) return;
      // The Offers category also includes things like Best Sellers/New
      // Arrivals that aren't necessarily discounted — the zone banner is
      // specifically about savings, so only keep products with a real
      // markdown.
      setState(
          () => _offerProducts = products.where((p) => p.isOnSale).toList());
    } catch (_) {
      // Best-effort: the zone offers banner simply stays empty if this fails.
    }
  }

  Future<void> _openSearch() async {
    final api = CatalogApiService();
    final product = await showSearch<Product?>(
      context: context,
      delegate: ProductSearchDelegate(api, widget.controller.storeMap),
    );
    api.dispose();
    if (product != null) _navigateToProduct(product);
  }

  void _navigateToProduct(Product product) {
    final beacon = assignZone(widget.controller.storeMap, product.productCode);
    if (beacon == null) return;
    widget.controller.setDestination(beacon);
    _activityLogger.log('Destination set: ${product.name} (${beacon.id})');
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NavigationScreen(
            controller: widget.controller, catalogOffers: _offerProducts),
      ),
    );
  }

  void _navigateToZone(Beacon beacon) {
    widget.controller.setDestination(beacon);
    _activityLogger.log('Destination set: zone (${beacon.id})');
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NavigationScreen(
            controller: widget.controller, catalogOffers: _offerProducts),
      ),
    );
  }

  void _openLogs() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            LogsScreen(activityLogger: _activityLogger, analytics: _analytics),
      ),
    );
  }

  void _openBeaconSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BeaconSettingsScreen(
          storeMap: widget.controller.storeMap,
          bleScanner: widget.bleScanner,
        ),
      ),
    );
  }

  void _openBeaconFingerprinting() {
    final fpController = BeaconFingerprintController(
      _homeFingerprintService,
      widget.bleScanner,
      widget.controller.storeMap.beacons,
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BeaconFingerprintScreen(controller: fpController),
      ),
    );
  }

  void _openCategory(ProductCategory category) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProductListingScreen(
          category: category,
          storeMap: widget.controller.storeMap,
          onProductSelected: _navigateToProduct,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: const Text('Way Finder'),
        actions: [
          IconButton(
            icon: const Icon(Icons.location_searching),
            tooltip: 'Beacon fingerprinting',
            onPressed: _openBeaconFingerprinting,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Beacon settings',
            onPressed: _openBeaconSettings,
          ),
          IconButton(
            icon: const Icon(Icons.insights_outlined),
            tooltip: 'Logs & analytics',
            onPressed: _openLogs,
          ),
          // IconButton(
          //   icon: const Icon(Icons.smart_toy_outlined),
          //   tooltip: 'Collect ML training data',
          //   onPressed: _openMlDataCollection,
          // ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _SearchBar(onTap: _openSearch),
            const SizedBox(height: 12),
            _buildFingerprintStatus(colorScheme, textTheme),
            const SizedBox(height: 28),
            const SectionHeader(icon: Icons.map_outlined, label: 'Live map'),
            const SizedBox(height: 12),
            LiveNavigationCard(
                controller: widget.controller, catalogOffers: _offerProducts),
            const SizedBox(height: 28),
            const SectionHeader(icon: Icons.pin_drop_outlined, label: 'Zones'),
            const SizedBox(height: 12),
            _buildZonesSection(colorScheme, textTheme),
            const SizedBox(height: 28),
            const SectionHeader(
                icon: Icons.category_outlined, label: 'Categories'),
            const SizedBox(height: 12),
            _buildCategoriesSection(colorScheme, textTheme),
          ],
        ),
      ),
    );
  }

  Widget _buildFingerprintStatus(ColorScheme colorScheme, TextTheme textTheme) {
    final matches = _homeFingerprintController.bestMatchesByAlgorithm;
    if (matches.isEmpty) {
      return Card(
        child: ListTile(
          dense: true,
          leading: Icon(Icons.radar, color: colorScheme.onSurfaceVariant),
          title: const Text('Fingerprint zone: waiting for a match'),
          subtitle: const Text(
              'Capture zone fingerprints to enable this test signal.'),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            const ListTile(
              dense: true,
              leading: Icon(Icons.radar),
              title: Text('Fingerprint zone detection'),
              subtitle:
                  Text('All algorithms evaluated from the live fingerprint.'),
            ),
            if (_confirmedFingerprintZoneId != null)
              ListTile(
                dense: true,
                leading: const Icon(Icons.verified, color: Colors.green),
                title: Text(
                  'Confirmed: ${widget.controller.storeMap.beaconById(_confirmedFingerprintZoneId!)?.name ?? _confirmedFingerprintZoneId}',
                ),
                subtitle: Text(
                  'Stable fingerprint candidate after hysteresis',
                  style: textTheme.bodySmall,
                ),
              ),
            for (final algorithm in BeaconDistanceAlgorithm.values)
              _buildFingerprintAlgorithmRow(
                algorithm,
                matches[algorithm],
                colorScheme,
                textTheme,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFingerprintAlgorithmRow(
    BeaconDistanceAlgorithm algorithm,
    DistanceResult? match,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    if (match == null) {
      return ListTile(
        dense: true,
        leading: Icon(Icons.circle, size: 12, color: colorScheme.outline),
        title: Text(algorithm.displayName),
        subtitle: const Text('Waiting for enough fingerprint readings.'),
      );
    }

    final beacon = widget.controller.storeMap.beaconById(match.zoneName);
    final confidence =
        (_homeFingerprintService.confidenceFor(match) * 100).round();
    final passesThreshold = _homeFingerprintController.passesThresholdFor(
      match,
      algorithm,
    );
    return ListTile(
      dense: true,
      leading: Icon(
        Icons.circle,
        size: 12,
        color: passesThreshold ? Colors.red : colorScheme.outline,
      ),
      title:
          Text('${algorithm.displayName}: ${beacon?.name ?? match.zoneName}'),
      subtitle: Text(
        '$confidence% confidence · ${match.matchedBeaconCount} beacons matched · '
        '${passesThreshold ? 'threshold passed' : 'below threshold'}',
        style: textTheme.bodySmall,
      ),
    );
  }

  Widget _buildCategoriesSection(ColorScheme colorScheme, TextTheme textTheme) {
    if (_categoriesError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$_categoriesError',
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              FilledButton(
                  onPressed: _loadCategories, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    final categories = _categories;
    if (categories == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (categories.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'No categories yet',
            style: textTheme.bodyMedium
                ?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return _CategoryGrid(categories: categories, onSelected: _openCategory);
  }

  Widget _buildZonesSection(ColorScheme colorScheme, TextTheme textTheme) {
    final zones = navigableBeacons(widget.controller.storeMap);
    if (zones.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'No zones yet',
            style: textTheme.bodyMedium
                ?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return _ZoneGrid(zones: zones, onSelected: _navigateToZone);
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.search, color: colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Text(
                'Search for a product…',
                style: TextStyle(
                    color: colorScheme.onSurfaceVariant, fontSize: 15),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryGrid extends StatelessWidget {
  const _CategoryGrid({required this.categories, required this.onSelected});

  final List<ProductCategory> categories;
  final ValueChanged<ProductCategory> onSelected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Cycled across cards purely for visual variety — all four are
    // theme-derived tonal pairs, so they stay legible/on-brand in both
    // light and dark mode without any hardcoded colors.
    final accents = [
      (
        background: colorScheme.primaryContainer,
        foreground: colorScheme.onPrimaryContainer
      ),
      (
        background: colorScheme.secondaryContainer,
        foreground: colorScheme.onSecondaryContainer
      ),
      (
        background: colorScheme.tertiaryContainer,
        foreground: colorScheme.onTertiaryContainer
      ),
      (
        background: colorScheme.errorContainer,
        foreground: colorScheme.onErrorContainer
      ),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        mainAxisExtent: 152,
      ),
      itemCount: categories.length,
      itemBuilder: (context, index) {
        final category = categories[index];
        final accent = accents[index % accents.length];
        return _CategoryCard(
          category: category,
          background: accent.background,
          foreground: accent.foreground,
          onTap: () => onSelected(category),
        );
      },
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.category,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  final ProductCategory category;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: background,
      elevation: 1,
      shadowColor: foreground.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: foreground.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(iconForCategory(category.name),
                    size: 24, color: foreground),
              ),
              const Spacer(),
              Text(
                category.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleSmall
                    ?.copyWith(color: foreground, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              // Not a product count: get-category-tree's declared
              // productCount for a category is frequently wrong relative to
              // what get-product-listing actually returns for it (see
              // CatalogApiService.getProductsForCategory), so showing that
              // number here would just be showing wrong information.
              Text(
                'Browse products',
                style: textTheme.bodySmall
                    ?.copyWith(color: foreground.withValues(alpha: 0.75)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ZoneGrid extends StatelessWidget {
  const _ZoneGrid({required this.zones, required this.onSelected});

  final List<Beacon> zones;
  final ValueChanged<Beacon> onSelected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Same theme-derived tonal pairs as the category grid, cycled purely
    // for visual variety.
    final accents = [
      (
        background: colorScheme.primaryContainer,
        foreground: colorScheme.onPrimaryContainer
      ),
      (
        background: colorScheme.secondaryContainer,
        foreground: colorScheme.onSecondaryContainer
      ),
      (
        background: colorScheme.tertiaryContainer,
        foreground: colorScheme.onTertiaryContainer
      ),
      (
        background: colorScheme.errorContainer,
        foreground: colorScheme.onErrorContainer
      ),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        mainAxisExtent: 152,
      ),
      itemCount: zones.length,
      itemBuilder: (context, index) {
        final zone = zones[index];
        final accent = accents[index % accents.length];
        return _ZoneCard(
          zone: zone,
          background: accent.background,
          foreground: accent.foreground,
          onTap: () => onSelected(zone),
        );
      },
    );
  }
}

class _ZoneCard extends StatelessWidget {
  const _ZoneCard({
    required this.zone,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  final Beacon zone;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: background,
      elevation: 1,
      shadowColor: foreground.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: foreground.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.place_outlined, size: 24, color: foreground),
              ),
              const Spacer(),
              Text(
                zone.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleSmall
                    ?.copyWith(color: foreground, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(
                'Navigate here',
                style: textTheme.bodySmall
                    ?.copyWith(color: foreground.withValues(alpha: 0.75)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
