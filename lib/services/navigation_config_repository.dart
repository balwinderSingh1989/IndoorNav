import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:indoor_nav_engine/indoor_nav_engine.dart';

/// Loads the site's editable navigation tuning from a bundled JSON asset.
class NavigationConfigRepository {
  Future<IndoorNavConfig> load({
    String assetPath = 'assets/navigation_config.json',
  }) async {
    final raw = await rootBundle.loadString(assetPath);
    return IndoorNavConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }
}
