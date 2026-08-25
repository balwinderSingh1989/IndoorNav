/// A product from the Ace Hardware catalog API (either
/// get-product-listing or search-query-api-deployment — both return the
/// same product shape). Carries no in-store location: the catalog is a
/// generic e-commerce feed with no knowledge of this app's beacon graph.
class Product {
  final String productCode;
  final String name;
  final String brand;
  final String? image;
  final double price;
  final double? salePrice;
  final String currency;
  final int categoryId;
  final bool hasStock;
  final int stockCount;
  final String? shortDescription;

  const Product({
    required this.productCode,
    required this.name,
    required this.brand,
    required this.image,
    required this.price,
    required this.salePrice,
    required this.currency,
    required this.categoryId,
    required this.hasStock,
    required this.stockCount,
    required this.shortDescription,
  });

  /// The price to actually show/charge: the sale price when the product is
  /// discounted, otherwise the regular price.
  double get displayPrice => salePrice ?? price;

  bool get isOnSale => salePrice != null && salePrice! < price;

  /// Whole-percent discount off [price], or null when not [isOnSale].
  int? get discountPercent {
    if (!isOnSale || price == 0) return null;
    return (((price - salePrice!) / price) * 100).round();
  }

  factory Product.fromJson(Map<String, dynamic> json) {
    return Product(
      productCode: (json['productCode'] ?? json['id'] ?? json['sku']).toString(),
      name: json['name'] as String? ?? 'Unknown product',
      brand: json['brand'] as String? ?? '',
      image: json['image'] as String?,
      price: (json['price'] as num?)?.toDouble() ?? 0,
      salePrice: (json['salePrice'] as num?)?.toDouble(),
      currency: json['currency'] as String? ?? '',
      categoryId: (json['categoryId'] as num?)?.toInt() ?? 0,
      hasStock: json['hasStock'] as bool? ?? false,
      stockCount: (json['stockCount'] as num?)?.toInt() ?? 0,
      shortDescription: json['shortDescription'] as String?,
    );
  }
}
