import 'package:flutter/material.dart';

/// Best-guess Material icon for an item name, purely cosmetic — picked by
/// keyword, falling back to a generic one otherwise.
IconData iconForItem(String name) {
  final lower = name.toLowerCase();
  if (lower.contains('coffee')) return Icons.coffee_outlined;
  if (lower.contains('printer')) return Icons.print_outlined;
  if (lower.contains('projector')) return Icons.videocam_outlined;
  if (lower.contains('cable') || lower.contains('hdmi')) return Icons.cable_outlined;
  if (lower.contains('whiteboard') || lower.contains('marker')) return Icons.draw_outlined;
  if (lower.contains('desk')) return Icons.table_restaurant_outlined;
  if (lower.contains('server') || lower.contains('rack')) return Icons.dns_outlined;
  if (lower.contains('chair') || lower.contains('lounge')) return Icons.chair_outlined;
  return Icons.inventory_2_outlined;
}

/// Curated outline icons cycled by name hash when no keyword matches, so
/// categories never collapse onto one repeated placeholder glyph.
const _categoryFallbackIcons = [
  Icons.widgets_outlined,
  Icons.storefront_outlined,
  Icons.local_mall_outlined,
  Icons.grid_view_outlined,
  Icons.inventory_2_outlined,
  Icons.category_outlined,
];

/// Best-guess Material icon for a category name, purely cosmetic — picked by
/// keyword, falling back to a deterministic (but varied) pick otherwise.
IconData iconForCategory(String name) {
  final lower = name.toLowerCase();
  if (lower.contains('tool') || lower.contains('drill') || lower.contains('grinder')) {
    return Icons.build_outlined;
  }
  if (lower.contains('saw') || lower.contains('blade') || lower.contains('screwdriver') || lower.contains('nail')) {
    return Icons.handyman_outlined;
  }
  if (lower.contains('paint')) return Icons.format_paint_outlined;
  if (lower.contains('electric')) return Icons.electrical_services_outlined;
  if (lower.contains('tap') || lower.contains('faucet')) return Icons.water_drop_outlined;
  if (lower.contains('basin') || lower.contains('sink') || lower.contains('bath')) {
    return Icons.bathtub_outlined;
  }
  if (lower.contains('plumb') || lower.contains('pump') || lower.contains('irrigation') || lower.contains('sprinkler')) {
    return Icons.plumbing_outlined;
  }
  if (lower.contains('garden') || lower.contains('outdoor') || lower.contains('lawn')) {
    return Icons.yard_outlined;
  }
  if (lower.contains('hardware') || lower.contains('fastener') || lower.contains('screw') || lower.contains('bolt')) {
    return Icons.hardware_outlined;
  }
  if (lower.contains('lighting') || lower.contains('lamp') || lower.contains('bulb')) {
    return Icons.lightbulb_outline;
  }
  if (lower.contains('storage') || lower.contains('organiz')) return Icons.inventory_2_outlined;
  if (lower.contains('safety') || lower.contains('security') || lower.contains('ppe') || lower.contains('workwear')) {
    return Icons.shield_outlined;
  }
  if (lower.contains('clean')) return Icons.cleaning_services_outlined;
  if (lower.contains('automotive') || lower.contains('car')) return Icons.directions_car_filled_outlined;
  if (lower.contains('kitchen') || lower.contains('appliance')) return Icons.kitchen_outlined;
  if (lower.contains('furniture') || lower.contains('desk') || lower.contains('chair')) {
    return Icons.chair_outlined;
  }
  if (lower.contains('door') || lower.contains('window')) return Icons.door_front_door_outlined;
  if (lower.contains('roof') || lower.contains('fence') || lower.contains('deck')) return Icons.roofing_outlined;
  if (lower.contains('floor') || lower.contains('tile')) return Icons.grid_view_outlined;
  if (lower.contains('ladder')) return Icons.stairs_outlined;
  if (lower.contains('pool')) return Icons.pool_outlined;
  if (lower.contains('bbq') || lower.contains('grill')) return Icons.outdoor_grill_outlined;
  if (lower.contains('heat') || lower.contains('cool') || lower.contains('hvac')) return Icons.thermostat_outlined;
  if (lower.contains('seasonal') || lower.contains('holiday') || lower.contains('christmas')) {
    return Icons.celebration_outlined;
  }
  if (lower.contains('summer')) return Icons.wb_sunny_outlined;
  if (lower.contains('welcome') || lower.contains('home')) return Icons.home_outlined;
  if (lower.contains('best sell') || lower.contains('trending') || lower.contains('popular') || lower.contains('top rated')) {
    return Icons.star_outline;
  }
  if (lower.contains('offer') || lower.contains('deal') || lower.contains('sale') || lower.contains('discount') || lower.contains('clearance')) {
    return Icons.local_offer_outlined;
  }
  return _categoryFallbackIcons[name.hashCode.abs() % _categoryFallbackIcons.length];
}
