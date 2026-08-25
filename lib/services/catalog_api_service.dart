import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/product.dart';
import '../models/product_category.dart';

class CatalogApiException implements Exception {
  final String message;
  const CatalogApiException(this.message);

  @override
  String toString() => message;
}

/// Client for the Ace Hardware POC catalog workflows (Kore.ai agent
/// endpoints) — category tree, product listing per category, and free-text
/// product search. Purely a product catalog: nothing it returns is aware
/// of this app's beacon/aisle graph.
class CatalogApiService {
  CatalogApiService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _baseUrl =
      'https://agents.kore.ai/api/v1/project/ace-hardware-poc/dev/workflow';
  static const _apiKey = 'pk_df3e02b35f5793293aea4b98fcc6ebc06490b653d6dce93c';

  /// This backend routinely takes 5-7+ seconds per call (it's an
  /// LLM/agent-driven workflow, not a simple lookup), so this needs to be
  /// generous — but without *some* bound, a stalled connection (flaky
  /// wifi/cellular, a DNS hiccup, a dropped TCP handshake) would otherwise
  /// hang indefinitely with no error ever surfacing, since plain
  /// `http.Client` calls have no timeout of their own.
  static const _requestTimeout = Duration(seconds: 25);

  Future<Map<String, dynamic>> _invoke(String workflow, Map<String, dynamic> input) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$_baseUrl/$workflow/invoke'),
            headers: const {
              'x-api-key': _apiKey,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'input': input}),
          )
          .timeout(_requestTimeout);
    } on TimeoutException {
      throw const CatalogApiException('Product catalog took too long to respond. Try again.');
    } catch (_) {
      throw const CatalogApiException('Could not reach the product catalog. Check your connection.');
    }

    if (response.statusCode != 200) {
      throw CatalogApiException('Product catalog request failed (${response.statusCode}).');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body['success'] != true) {
      throw const CatalogApiException('Product catalog request was unsuccessful.');
    }

    final data = body['data'] as Map<String, dynamic>?;
    final result = data?['result'] as Map<String, dynamic>?;
    if (result == null) {
      throw const CatalogApiException('Product catalog returned an unexpected response.');
    }
    return result;
  }

  Future<List<ProductCategory>> getCategoryTree() async {
    final result = await _invoke('get-category-tree', const {});
    final categories = result['categories'] as List? ?? const [];
    return categories
        .map((c) => ProductCategory.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  Future<List<Product>> getProductListing(int categoryId) async {
    final result = await _invoke('get-product-listing', {'categoryId': categoryId});
    final products = result['products'] as List? ?? const [];
    return products.map((p) => Product.fromJson(p as Map<String, dynamic>)).toList();
  }

  /// [getProductListing] keyed by a category from the tree, with fallbacks
  /// for quirks of this POC backend: a category's declared productCount
  /// (from get-category-tree) doesn't reliably predict whether
  /// get-product-listing actually returns anything for that exact id —
  /// some parent categories resolve directly, others come back empty even
  /// though a child (or grandchild) of theirs has real products, and some
  /// categories' ids in the tree don't match the id their own products are
  /// actually tagged with at all (e.g. the tree lists "Jigsaw Blade" as id
  /// 5935, but its real products carry categoryId 5746 — get-product-listing
  /// on 5935 finds nothing that will ever exist). So: try the category
  /// itself first, then aggregate across its children (depth-first) until
  /// enough products are found or the request budget runs out, and if that
  /// still comes up empty, fall back to searching by the category's own
  /// name — search-query-api-deployment matches on the product catalog
  /// directly rather than the (possibly stale) category tree ids.
  Future<List<Product>> getProductsForCategory(
    ProductCategory category, {
    int maxProducts = 30,
    int maxRequests = 8,
  }) async {
    var requestsLeft = maxRequests;

    Future<List<Product>> recurse(ProductCategory node) async {
      if (requestsLeft <= 0) return const [];
      requestsLeft--;
      final direct = await getProductListing(node.categoryId);
      if (direct.isNotEmpty) return direct;

      final collected = <Product>[];
      for (final child in node.children) {
        if (collected.length >= maxProducts || requestsLeft <= 0) break;
        collected.addAll(await recurse(child));
      }
      return collected;
    }

    final result = await recurse(category);
    if (result.isNotEmpty) return result;

    try {
      return await searchProducts(category.name);
    } catch (_) {
      return const [];
    }
  }

  Future<List<Product>> searchProducts(String query, {String lang = 'en'}) async {
    final result = await _invoke('search-query-api-deployment', {'UserQuery': query, 'Lang': lang});
    final products = result['products'] as List? ?? const [];
    return products.map((p) => Product.fromJson(p as Map<String, dynamic>)).toList();
  }

  void dispose() => _client.close();
}
