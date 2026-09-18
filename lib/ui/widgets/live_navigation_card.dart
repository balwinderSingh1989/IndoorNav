import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../models/product.dart';
import '../../models/store_map.dart';
import '../../services/navigation_controller.dart';
import 'map_painter.dart';
import 'zone_offers_banner.dart';

/// The live tracking bundle — status line, animated map, and turn-by-turn
/// waypoint chips — as one reusable block. Used on both the home screen
/// (an always-visible preview of "where am I") and [NavigationScreen] (the
/// dedicated full-screen view reached after picking a destination), so the
/// two never drift out of sync with each other.
class LiveNavigationCard extends StatelessWidget {
  const LiveNavigationCard({super.key, required this.controller, this.catalogOffers = const []});

  final NavigationController controller;

  /// Discounted products from the live catalog's Offers category, shown in
  /// [ZoneOffersBanner] alongside store_data.json's own local offers.
  final List<Product> catalogOffers;

  @override
  Widget build(BuildContext context) {
    final storeMap = controller.storeMap;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StatusCard(controller: controller),
            const SizedBox(height: 12),
            _MapFrame(controller: controller, storeMap: storeMap),
            ZoneOffersBanner(controller: controller, catalogOffers: catalogOffers),
            _DirectionsList(controller: controller),
          ],
        );
      },
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller});

  final NavigationController controller;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final hasFix = controller.currentBeacon != null;
    final confidence = controller.beaconConfidence;
    final here = controller.currentBeacon?.name ?? 'Finding your location…';
    final there = controller.destinationBeacon?.name;
    final status = switch (controller.status) {
      NavigationStatus.checkingLocation => 'Checking your location…',
      NavigationStatus.rerouting => 'Recalculating route…',
      NavigationStatus.arrived => 'Arrived',
      NavigationStatus.navigating => 'Navigating',
      NavigationStatus.idle => null,
    };
    final stride = controller.calibratedStepLengthMeters;
    final strideLabel = controller.strideCalibrationSampleCount == 0
      ? 'default'
      : '${controller.strideCalibrationSampleCount} samples';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _LocationConfidenceIndicator(hasFix: hasFix, confidence: confidence),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      if (hasFix)
                        TextSpan(text: 'You are near  ', style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
                      TextSpan(
                        text: here,
                        style: hasFix
                            ? textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)
                            : textTheme.bodyMedium?.copyWith(
                                fontStyle: FontStyle.italic,
                                color: colorScheme.onSurfaceVariant,
                              ),
                      ),
                      if (hasFix && confidence < 0.999)
                        TextSpan(
                          text: '  · confirming',
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.flag_outlined, size: 16, color: colorScheme.secondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: 'Going to  ', style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
                      TextSpan(
                        text: there ?? 'Pick a destination',
                        style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (controller.currentDistanceMeters != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.straighten, size: 16, color: colorScheme.tertiary),
                const SizedBox(width: 8),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: 'Distance  ', style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
                      TextSpan(
                        text: _formatDistance(controller.currentDistanceMeters!),
                        style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
          if (status != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.navigation_outlined, size: 16, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(status, style: textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.directions_walk, size: 16, color: colorScheme.tertiary),
              const SizedBox(width: 8),
              Text('Step distance  ', style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
              Text('${stride.toStringAsFixed(2)} m ($strideLabel)', style: textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
            ],
          ),
        ],
      ),
    );
  }

  String _formatDistance(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }
}

/// Reflects [NavigationController.beaconConfidence] instead of a plain
/// static pin — a filling ring while the pick is still settling, a pulsing
/// dot before any fix at all, so a later flip doesn't read as the app
/// having been "wrong" about a name it never confidently committed to.
class _LocationConfidenceIndicator extends StatefulWidget {
  const _LocationConfidenceIndicator({required this.hasFix, required this.confidence});

  final bool hasFix;
  final double confidence;

  @override
  State<_LocationConfidenceIndicator> createState() => _LocationConfidenceIndicatorState();
}

class _LocationConfidenceIndicatorState extends State<_LocationConfidenceIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (!widget.hasFix) {
      return FadeTransition(
        opacity: Tween(begin: 0.35, end: 1.0).animate(_pulse),
        child: Icon(Icons.location_searching, size: 16, color: colorScheme.primary),
      );
    }

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: widget.confidence),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      builder: (context, value, _) {
        if (value >= 0.999) {
          return Icon(Icons.my_location, size: 16, color: colorScheme.primary);
        }
        return SizedBox(
          width: 16,
          height: 16,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: value,
                strokeWidth: 2,
                color: colorScheme.primary,
                backgroundColor: colorScheme.primary.withValues(alpha: 0.15),
              ),
              Icon(Icons.my_location, size: 8, color: colorScheme.primary),
            ],
          ),
        );
      },
    );
  }
}

/// Draws the map + live arrow. The arrow's on-screen position is animated
/// (tweened) between updates rather than redrawn instantly at each new
/// [NavigationController.liveUserPosition] — smooths over the gaps between
/// its ~80ms position ticks so motion reads as fluid rather than a series
/// of tiny discrete hops.
class _MapFrame extends StatefulWidget {
  const _MapFrame({required this.controller, required this.storeMap});

  final NavigationController controller;
  final StoreMap storeMap;

  @override
  State<_MapFrame> createState() => _MapFrameState();
}

class _MapFrameState extends State<_MapFrame> with SingleTickerProviderStateMixin {
  late final AnimationController _positionAnim;
  Offset? _animFrom;
  Offset? _animTo;

  @override
  void initState() {
    super.initState();
    // Shorter than the old 350ms: NavigationController now emits position
    // updates continuously (~every 50ms) rather than in one lump per
    // detected step, so a long ease here would just stack lag on top of
    // lag instead of smoothing anything.
    _positionAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 15))
      ..addListener(() => setState(() {}));
    _animTo = widget.controller.liveUserPosition;
    widget.controller.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    final target = widget.controller.liveUserPosition;
    if (target == null || target == _animTo) return;
    _animFrom = _currentPosition ?? target;
    _animTo = target;
    _positionAnim.forward(from: 0);
  }

  Offset? get _currentPosition {
    if (_animFrom == null || _animTo == null) return _animTo;
    return Offset.lerp(_animFrom, _animTo, Curves.easeOut.transform(_positionAnim.value));
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _positionAnim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final storeMap = widget.storeMap;
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: colorScheme.surfaceContainerLow,
        boxShadow: [
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: storeMap.mapWidth / storeMap.mapHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            SvgPicture.asset(
              storeMap.mapAsset,
              fit: BoxFit.contain,
              placeholderBuilder: (context) => const Center(child: CircularProgressIndicator()),
              errorBuilder: (context, error, stackTrace) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Failed to load ${storeMap.mapAsset}:\n$error',
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              ),
              semanticsLabel: 'Store map',
            ),
            CustomPaint(
              painter: MapPainter(
                mapSize: Size(storeMap.mapWidth, storeMap.mapHeight),
                path: controller.currentPath,
                edges: storeMap.edges,
                userLocation: controller.currentBeacon,
                livePosition: _currentPosition,
                headingDegrees: controller.headingDegrees,
                mapNorthOffsetDegrees: storeMap.mapNorthOffsetDegrees,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DirectionsList extends StatelessWidget {
  const _DirectionsList({required this.controller});

  final NavigationController controller;

  @override
  Widget build(BuildContext context) {
    final path = controller.currentPath;
    if (path.length < 2) return const SizedBox.shrink();

    return SizedBox(
      height: 44,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        scrollDirection: Axis.horizontal,
        itemCount: path.length,
        separatorBuilder: (_, __) => const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Icon(Icons.arrow_forward, size: 14),
        ),
        itemBuilder: (context, i) => Chip(
          label: Text(path[i].name),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}
