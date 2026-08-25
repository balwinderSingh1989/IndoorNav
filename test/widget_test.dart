import 'package:flutter_test/flutter_test.dart';

import 'package:indoor_nav/services/store_data_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads the floor map asset and dimensions', () async {
    final repository = StoreDataRepository();
    final storeMap = await repository.loadStoreMap();

    expect(storeMap.mapAsset, 'assets/floorMap.svg');
    expect(storeMap.mapWidth, 210);
    expect(storeMap.mapHeight, 297);
    expect(storeMap.beacons, isNotEmpty);
  });
}
