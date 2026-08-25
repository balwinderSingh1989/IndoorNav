/// A node in the Ace Hardware catalog's category tree (from the
/// get-category-tree API) — used purely for browsing/display; it has no
/// relationship to the app's own beacon/aisle graph.
class ProductCategory {
  final int categoryId;
  final String name;
  final int level;
  final int productCount;
  final bool hasChildren;
  final List<ProductCategory> children;

  const ProductCategory({
    required this.categoryId,
    required this.name,
    required this.level,
    required this.productCount,
    required this.hasChildren,
    this.children = const [],
  });

  factory ProductCategory.fromJson(Map<String, dynamic> json) {
    final rawChildren = json['children'] as List?;
    return ProductCategory(
      categoryId: (json['categoryId'] as num).toInt(),
      name: json['name'] as String,
      level: (json['level'] as num?)?.toInt() ?? 1,
      productCount: (json['productCount'] as num?)?.toInt() ?? 0,
      hasChildren: json['hasChildren'] as bool? ?? false,
      children: rawChildren == null
          ? const []
          : rawChildren
              .map((c) => ProductCategory.fromJson(c as Map<String, dynamic>))
              .toList(),
    );
  }
}
