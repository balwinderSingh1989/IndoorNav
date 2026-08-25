import '../models/beacon.dart';
import '../models/store_map.dart';

/// A computed route: the beacon-by-beacon path, and its total edge-weight
/// distance (map units — multiply by [StoreMap.metersPerUnit] for meters).
class RouteResult {
  final List<Beacon> path;
  final double distanceUnits;

  const RouteResult({required this.path, required this.distanceUnits});

  static const empty = RouteResult(path: [], distanceUnits: 0);
}

/// Shortest path between two beacons over the aisle graph, via Dijkstra.
/// The store's beacon graph is small (tens of nodes), so a plain O(V^2)
/// implementation is simpler and fast enough for this MVP.
class PathfindingService {
  RouteResult findPath(StoreMap storeMap, String startId, String endId) {
    if (startId == endId) {
      final only = storeMap.beaconById(startId);
      return only == null ? RouteResult.empty : RouteResult(path: [only], distanceUnits: 0);
    }

    final adjacency = storeMap.adjacency;
    final distances = <String, double>{for (final b in storeMap.beacons) b.id: double.infinity};
    final previous = <String, String?>{};
    final visited = <String>{};

    distances[startId] = 0;

    while (visited.length < storeMap.beacons.length) {
      final currentId = _closestUnvisited(distances, visited);
      if (currentId == null) break;
      if (currentId == endId) break;
      visited.add(currentId);

      for (final edge in adjacency[currentId] ?? const []) {
        if (visited.contains(edge.to)) continue;
        final candidate = distances[currentId]! + edge.weight;
        if (candidate < (distances[edge.to] ?? double.infinity)) {
          distances[edge.to] = candidate;
          previous[edge.to] = currentId;
        }
      }
    }

    if (!previous.containsKey(endId) && startId != endId) return RouteResult.empty;
    final path = _reconstructPath(storeMap, previous, startId, endId);
    if (path.isEmpty) return RouteResult.empty;
    return RouteResult(path: path, distanceUnits: distances[endId] ?? 0);
  }

  String? _closestUnvisited(Map<String, double> distances, Set<String> visited) {
    String? closest;
    var closestDistance = double.infinity;
    for (final entry in distances.entries) {
      if (visited.contains(entry.key)) continue;
      if (entry.value < closestDistance) {
        closestDistance = entry.value;
        closest = entry.key;
      }
    }
    return closest;
  }

  List<Beacon> _reconstructPath(
    StoreMap storeMap,
    Map<String, String?> previous,
    String startId,
    String endId,
  ) {
    final pathIds = <String>[endId];
    var currentId = endId;
    while (currentId != startId) {
      final prev = previous[currentId];
      if (prev == null) return [];
      pathIds.add(prev);
      currentId = prev;
    }
    return pathIds.reversed.map((id) => storeMap.beaconById(id)!).toList();
  }
}
