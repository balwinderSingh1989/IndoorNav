import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:indoor_nav/models/beacon.dart';
import 'package:indoor_nav/models/product.dart';
import 'package:indoor_nav/models/store_map.dart';
import 'package:indoor_nav/services/catalog_api_service.dart';
import 'package:indoor_nav/ui/widgets/product_search_delegate.dart';

StoreMap _testStoreMap() {
  return const StoreMap(
    mapAsset: 'assets/floorMap.svg',
    mapWidth: 297,
    mapHeight: 210,
    metersPerUnit: 0.1,
    mapNorthOffsetDegrees: 0,
    beacons: [
      Beacon(id: 'b1', bleId: 'x', name: 'Zone 1', position: Offset(0, 0)),
    ],
    edges: [],
    items: [],
  );
}

void main() {
  testWidgets('ProductSearchDelegate renders products the API returns, end to end', (tester) async {
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      expect(request.url.toString(), contains('search-query-api-deployment/invoke'));
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect((body['input'] as Map)['UserQuery'], 'hammer');

      return http.Response(
        jsonEncode({
          'success': true,
          'data': {
            'executionId': 'test-exec',
            'status': 'completed',
            'result': {
              '_status': 0,
              'products': [
                {
                  'productCode': '2041397',
                  'name': 'Ace Steel Claw Hammer W/Hickory Handle (567 g)',
                  'brand': 'Ace',
                  'image': null,
                  'price': 25,
                  'currency': 'AED',
                  'categoryId': 5900,
                  'hasStock': true,
                  'stockCount': 12,
                },
              ],
            },
          },
        }),
        200,
      );
    });

    final api = CatalogApiService(client: client);
    final storeMap = _testStoreMap();

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showSearch<Product?>(
                  context: context,
                  delegate: ProductSearchDelegate(api, storeMap),
                ),
                child: const Text('open search'),
              ),
            ),
          ),
        ),
      ),
    );

    // Open the search page.
    await tester.tap(find.text('open search'));
    await tester.pumpAndSettle();

    // Before typing anything, the delegate's idle prompt should show —
    // proves the search page itself opened correctly.
    expect(find.text('Search for a product'), findsOneWidget);

    // Type a query — this is exactly what a user does on the phone.
    await tester.enterText(find.byType(TextField), 'hammer');

    // Past the 500ms debounce, but before the (instant, in this test)
    // mocked network call would have resolved.
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Let the mocked HTTP round-trip and subsequent setState/rebuild settle.
    await tester.pumpAndSettle();

    expect(requestCount, 1);
    expect(find.text('Ace Steel Claw Hammer W/Hickory Handle (567 g)'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
