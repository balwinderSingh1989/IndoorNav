import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

import 'package:indoor_nav/services/store_data_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads the floor map asset and dimensions', () async {
    final repository = StoreDataRepository();
    final storeMap = await repository.loadStoreMap();

    expect(storeMap.mapAsset, 'assets/floorMap.svg');
    final svg = await rootBundle.loadString('assets/floorMap.svg');
    final viewBox = RegExp(r'''viewBox\s*=\s*["']\s*[-\d.]+\s+[-\d.]+\s+([\d.]+)\s+([\d.]+)''').firstMatch(svg);
    expect(viewBox, isNotNull);
    expect(storeMap.mapWidth, double.parse(viewBox!.group(1)!));
    expect(storeMap.mapHeight, double.parse(viewBox.group(2)!));
    expect(storeMap.beacons, isNotEmpty);
  });
}
