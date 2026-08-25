import '../../models/beacon.dart';
import '../../models/store_map.dart';

/// Beacon names that aren't real browsable areas of the store (an interim
/// staging beacon and an internal seating placeholder) — excluded from both
/// zone navigation and product-to-zone allocation.
const _excludedZoneNames = {'Interim', 'Seating 2-A'};

/// Every configured beacon that's a valid navigation destination, i.e. all
/// beacons except [_excludedZoneNames].
List<Beacon> navigableBeacons(StoreMap storeMap) =>
    storeMap.beacons.where((b) => !_excludedZoneNames.contains(b.name)).toList();

/// The Ace Hardware catalog API has no concept of this app's beacon/aisle
/// graph, so every product needs *some* zone to navigate to. Rather than
/// truly randomizing on every tap (which would send you somewhere new each
/// time you pick the same product), this deterministically spreads
/// products across whichever navigable beacons/zones exist by hashing the
/// product code — same product always lands on the same zone, different
/// products land all over the map.
Beacon? assignZone(StoreMap storeMap, String productCode) {
  final beacons = navigableBeacons(storeMap);
  if (beacons.isEmpty) return null;
  final index = productCode.hashCode.abs() % beacons.length;
  return beacons[index];
}
