/// A searchable item, the beacon nearest to where it's kept, the general
/// kind of thing it is (e.g. "Electronics"), and an optional current offer
/// — all used purely for display (grouping/search/zone notifications);
/// navigation itself only ever cares about [beaconId].
class Item {
  final String name;
  final String beaconId;
  final String category;
  final String? offer;

  const Item({required this.name, required this.beaconId, required this.category, this.offer});

  factory Item.fromJson(Map<String, dynamic> json) {
    return Item(
      name: json['name'] as String,
      beaconId: json['beaconId'] as String,
      category: json['category'] as String? ?? 'Other',
      offer: json['offer'] as String?,
    );
  }
}
