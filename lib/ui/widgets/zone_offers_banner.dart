import 'package:flutter/material.dart';

import '../../models/product.dart';
import '../../services/navigation_controller.dart';
import '../utils/icon_lookup.dart';
import '../utils/zone_assignment.dart';

/// An inline banner, shown in the live-navigation area right below the
/// map, listing any current offers on items kept in
/// [NavigationController.currentBeacon]'s zone — both store_data.json's
/// own local items and (see [catalogOffers]) discounted products from the
/// live catalog's Offers category. Purely reactive — no dismiss, no
/// one-shot event — so it always reflects whichever zone you're in right
/// now, and simply hides itself ([SizedBox.shrink]) when that zone has
/// nothing on offer.
class ZoneOffersBanner extends StatelessWidget {
  const ZoneOffersBanner({super.key, required this.controller, this.catalogOffers = const []});

  final NavigationController controller;
  final List<Product> catalogOffers;

  @override
  Widget build(BuildContext context) {
    final zone = controller.currentBeacon;
    if (zone == null) return const SizedBox.shrink();

    final offerItems =
        controller.storeMap.items.where((i) => i.beaconId == zone.id && i.offer != null).toList();
    final offerProducts = catalogOffers
        .where((p) => assignZone(controller.storeMap, p.productCode)?.id == zone.id)
        .toList();
    if (offerItems.isEmpty && offerProducts.isEmpty) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.local_offer_outlined, size: 18, color: colorScheme.onTertiaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Offers near ${zone.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall?.copyWith(
                    color: colorScheme.onTertiaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final item in offerItems)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(iconForItem(item.name), size: 16, color: colorScheme.onTertiaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        style: textTheme.bodySmall?.copyWith(color: colorScheme.onTertiaryContainer),
                        children: [
                          TextSpan(text: '${item.name}: ', style: const TextStyle(fontWeight: FontWeight.w700)),
                          TextSpan(text: item.offer),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          for (final product in offerProducts)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.local_offer_outlined, size: 16, color: colorScheme.onTertiaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        style: textTheme.bodySmall?.copyWith(color: colorScheme.onTertiaryContainer),
                        children: [
                          TextSpan(
                            text: '${product.name}: ',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          TextSpan(
                            text: product.discountPercent != null
                                ? '${product.discountPercent}% off (${product.currency} ${product.displayPrice.toStringAsFixed(0)})'
                                : '${product.currency} ${product.displayPrice.toStringAsFixed(0)}',
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
