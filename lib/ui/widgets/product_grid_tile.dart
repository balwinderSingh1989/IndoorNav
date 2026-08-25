import 'package:flutter/material.dart';

import '../../models/product.dart';

/// An Amazon-style catalog tile: product image on top, name/brand/price
/// below. Used for both category product listings and search results.
class ProductGridTile extends StatelessWidget {
  const ProductGridTile({super.key, required this.product, required this.onTap, this.location});

  final Product product;
  final VoidCallback onTap;

  /// The zone/room this product is assigned to (see `assignZone` — the
  /// catalog itself carries no location), shown so a shopper can see where
  /// they'd be headed before tapping in.
  final String? location;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Expanded rather than a fixed AspectRatio: the text block below
            // sizes itself first (brand/name/price/location can wrap to a
            // varying number of lines depending on content and text-scale
            // settings), and the image simply takes whatever's left — so
            // the tile can never overflow the grid's fixed cell height.
            Expanded(
              child: Container(
                width: double.infinity,
                color: colorScheme.surfaceContainerHighest,
                child: product.image == null
                    ? Icon(Icons.inventory_2_outlined, color: colorScheme.onSurfaceVariant)
                    : Image.network(
                        product.image!,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) =>
                            Icon(Icons.broken_image_outlined, color: colorScheme.onSurfaceVariant),
                        loadingBuilder: (context, child, progress) {
                          if (progress == null) return child;
                          return Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: colorScheme.primary),
                            ),
                          );
                        },
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (product.brand.isNotEmpty)
                    Text(
                      product.brand,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  Text(
                    product.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        '${product.currency} ${product.displayPrice.toStringAsFixed(0)}',
                        style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (product.isOnSale) ...[
                        const SizedBox(width: 6),
                        Text(
                          '${product.currency} ${product.price.toStringAsFixed(0)}',
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            decoration: TextDecoration.lineThrough,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (!product.hasStock)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Out of stock',
                        style: textTheme.labelSmall?.copyWith(color: colorScheme.error),
                      ),
                    ),
                  if (location != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          Icon(Icons.place_outlined, size: 12, color: colorScheme.primary),
                          const SizedBox(width: 3),
                          Expanded(
                            child: Text(
                              location!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.labelSmall
                                  ?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
