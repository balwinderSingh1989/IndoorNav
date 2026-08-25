import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/store_map.dart';

/// Loads the store's beacon/aisle graph from the bundled store_data.json asset.
class StoreDataRepository {
  Future<StoreMap> loadStoreMap({
    String assetPath = 'assets/store_data.json',
  }) async {
    final raw = await rootBundle.loadString(assetPath);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return StoreMap.fromJson(json);
  }
}
