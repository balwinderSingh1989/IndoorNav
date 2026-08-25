import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/product.dart';
import '../../models/store_map.dart';
import '../../services/catalog_api_service.dart';
import '../utils/zone_assignment.dart';
import 'product_grid_tile.dart';

/// Search-as-you-type over the live Ace Hardware catalog
/// (search-query-api-deployment). Debounced so it doesn't fire a network
/// request on every keystroke. Returns the selected [Product], or null if
/// the user backs out without picking one.
class ProductSearchDelegate extends SearchDelegate<Product?> {
  ProductSearchDelegate(this._api, this._storeMap);

  final CatalogApiService _api;
  final StoreMap _storeMap;

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: () => query = '',
          ),
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => close(context, null),
      );

  @override
  Widget buildResults(BuildContext context) => _SearchResults(
        api: _api,
        storeMap: _storeMap,
        query: query,
        onSelected: (product) => close(context, product),
      );

  @override
  Widget buildSuggestions(BuildContext context) => _SearchResults(
        api: _api,
        storeMap: _storeMap,
        query: query,
        onSelected: (product) => close(context, product),
      );
}

class _SearchResults extends StatefulWidget {
  const _SearchResults({
    required this.api,
    required this.storeMap,
    required this.query,
    required this.onSelected,
  });

  final CatalogApiService api;
  final StoreMap storeMap;
  final String query;
  final ValueChanged<Product> onSelected;

  @override
  State<_SearchResults> createState() => _SearchResultsState();
}

enum _Status { idle, loading, error, done }

class _SearchResultsState extends State<_SearchResults> {
  static const _debounceDuration = Duration(milliseconds: 500);

  Timer? _debounce;

  // A monotonic counter rather than tracking "is a request in flight":
  // each search call captures the generation it was started at, and only
  // applies its result if that's still the current generation when it
  // completes — so a stale, slower response from an earlier keystroke can
  // never clobber a newer one, without needing to coordinate multiple
  // requests against each other.
  int _generation = 0;

  _Status _status = _Status.idle;
  Object? _error;
  List<Product> _results = const [];

  @override
  void initState() {
    super.initState();
    _scheduleSearch();
  }

  @override
  void didUpdateWidget(covariant _SearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) _scheduleSearch();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _scheduleSearch() {
    _debounce?.cancel();
    final query = widget.query.trim();
    _generation++;
    if (query.isEmpty) {
      setState(() {
        _status = _Status.idle;
        _results = const [];
      });
      return;
    }
    setState(() => _status = _Status.loading);
    final generation = _generation;
    _debounce = Timer(_debounceDuration, () => _runSearch(query, generation));
  }

  Future<void> _runSearch(String query, int generation) async {
    try {
      final results = await widget.api.searchProducts(query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _status = _Status.done;
        _results = results;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _status = _Status.error;
        _error = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    switch (_status) {
      case _Status.idle:
        return const Center(child: Text('Search for a product'));
      case _Status.loading:
        return _SearchingIndicator(textTheme: textTheme, colorScheme: colorScheme);
      case _Status.error:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '$_error',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ),
        );
      case _Status.done:
        // search-query-api-deployment ranks by semantic/hybrid similarity,
        // not literal text match, so a product whose name literally
        // contains the typed query can still land buried well below (or
        // effectively invisible next to) loosely-related results. Boost
        // literal matches to the top, keeping the API's own ranking within
        // each group.
        final products = _prioritizeLiteralMatches(_results, widget.query);
        if (products.isEmpty) {
          return const Center(child: Text('No products found'));
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
              onTap: () => widget.onSelected(product),
            );
          },
        );
    }
  }
}

/// The catalog search is genuinely slow (5-7+ seconds per call on this
/// backend) — a bare spinner with nothing else reads as broken/frozen once
/// it runs past a couple of seconds, so this pairs it with a caption
/// setting that expectation.
class _SearchingIndicator extends StatelessWidget {
  const _SearchingIndicator({required this.textTheme, required this.colorScheme});

  final TextTheme textTheme;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            'Searching the catalog…\nthis can take a few seconds',
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Stable partition — products whose name literally contains [query] first
/// (in their existing relative order), everything else after — rather than
/// a sort, so it never reorders within either group.
List<Product> _prioritizeLiteralMatches(List<Product> products, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return products;
  final matches = <Product>[];
  final rest = <Product>[];
  for (final product in products) {
    if (product.name.toLowerCase().contains(q)) {
      matches.add(product);
    } else {
      rest.add(product);
    }
  }
  return [...matches, ...rest];
}
