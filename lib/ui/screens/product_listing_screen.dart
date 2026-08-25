import 'package:flutter/material.dart';

import '../../models/product.dart';
import '../../models/product_category.dart';
import '../../models/store_map.dart';
import '../../services/catalog_api_service.dart';
import '../utils/zone_assignment.dart';
import '../widgets/product_grid_tile.dart';

/// Amazon-style grid of products in one category, fetched live from
/// get-product-listing (falling back to aggregating its subcategories —
/// see [CatalogApiService.getProductsForCategory] — since this POC
/// backend doesn't always return products for a category id directly).
/// Reached by tapping a category card on [HomeScreen]; tapping a product
/// hands it back to [onProductSelected], which assigns it a zone and opens
/// navigation.
class ProductListingScreen extends StatefulWidget {
  const ProductListingScreen({
    super.key,
    required this.category,
    required this.storeMap,
    required this.onProductSelected,
  });

  final ProductCategory category;
  final StoreMap storeMap;
  final ValueChanged<Product> onProductSelected;

  @override
  State<ProductListingScreen> createState() => _ProductListingScreenState();
}

class _ProductListingScreenState extends State<ProductListingScreen> {
  final _api = CatalogApiService();
  late Future<List<Product>> _future;

  @override
  void initState() {
    super.initState();
    _future = _api.getProductsForCategory(widget.category);
  }

  @override
  void dispose() {
    _api.dispose();
    super.dispose();
  }

  void _retry() {
    setState(() => _future = _api.getProductsForCategory(widget.category));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(title: Text(widget.category.name)),
      body: SafeArea(
        child: FutureBuilder<List<Product>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${snapshot.error}',
                        textAlign: TextAlign.center,
                        style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _retry, child: const Text('Retry')),
                    ],
                  ),
                ),
              );
            }
            final products = snapshot.data ?? const [];
            if (products.isEmpty) {
              return Center(
                child: Text(
                  'No products in this category yet',
                  style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              );
            }
            return GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                mainAxisExtent: 280,
              ),
              itemCount: products.length,
              itemBuilder: (context, index) {
                final product = products[index];
                final beacon = assignZone(widget.storeMap, product.productCode);
                return ProductGridTile(
                  product: product,
                  location: beacon?.name,
                  onTap: () => widget.onProductSelected(product),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
