import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../models/beacon.dart';
import '../../models/store_map.dart';
import '../../services/beacon_placement_generator.dart';
import '../widgets/beacon_settings_editor.dart';

class BeaconSettingsScreen extends StatefulWidget {
  const BeaconSettingsScreen({
    super.key,
    required this.storeMap,
  });

  final StoreMap storeMap;

  @override
  State<BeaconSettingsScreen> createState() => _BeaconSettingsScreenState();
}

class _BeaconSettingsScreenState extends State<BeaconSettingsScreen> {
  final _generator = const BeaconPlacementGenerator();
  late List<Beacon> _beacons;
  List<BeaconPlacementSuggestion> _suggestions = const [];

  @override
  void initState() {
    super.initState();
    _beacons = List<Beacon>.from(widget.storeMap.beacons);
    _loadSuggestions();
  }

  Future<void> _loadSuggestions() async {
    final suggestions = await _generator.generate(widget.storeMap);
    if (!mounted) return;
    setState(() {
      _suggestions = suggestions;
    });
  }

  Future<void> _editBeacon(Beacon beacon) async {
    final updated = await showDialog<Beacon>(
      context: context,
      builder: (_) => BeaconSettingsEditor(beacon: beacon),
    );

    if (updated == null || !mounted) return;

    setState(() {
      final index = _beacons.indexWhere((b) => b.id == beacon.id);
      if (index >= 0) {
        _beacons[index] = updated;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Beacon settings'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Suggested placement: 3–6 m spacing',
                style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Suggested positions appear on the map below. Pick one and set its UUID/MAC, major and minor.',
                style: textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 260,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      SvgPicture.asset(
                        widget.storeMap.mapAsset,
                        fit: BoxFit.contain,
                      ),
                      ..._suggestions.asMap().entries.map((entry) {
                        final suggestion = entry.value;
                        final point = suggestion.position;
                        final beaconIndex = entry.key + 1;
                        return Positioned(
                          left: point.dx - 11,
                          top: point.dy - 11,
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: const BoxDecoration(
                              color: Color(0xCCFF9800),
                              shape: BoxShape.circle,
                              border: Border.fromBorderSide(
                                BorderSide(color: Colors.white, width: 2),
                              ),
                            ),
                            child: Center(
                              child: Text(
                                '$beaconIndex',
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView.separated(
                  itemCount: _suggestions.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final suggestion = _suggestions[index];
                    final currentPosition = suggestion.position;
                    final beacon = Beacon(
                      id: 'suggested_${index + 1}',
                      bleId: '',
                      name: 'Suggested Beacon ${index + 1}',
                      major: 0,
                      minor: index + 1,
                      position: currentPosition,
                    );
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.orange,
                          child: Text('${index + 1}', style: const TextStyle(color: Colors.white)),
                        ),
                        title: Text(beacon.name),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 4),
                            Text('Position: (${currentPosition.dx.toStringAsFixed(1)}, ${currentPosition.dy.toStringAsFixed(1)})'),
                            Text('Target spacing: ${suggestion.distanceFromPreviousMeters.toStringAsFixed(1)} m'),
                          ],
                        ),
                        trailing: FilledButton.tonal(
                          onPressed: () => _editBeacon(beacon),
                          child: const Text('Set IDs'),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
