import 'dart:ui' show Offset;

import 'package:flutter/material.dart';

import '../../models/beacon.dart';
import '../../models/store_map.dart';
import '../../services/beacon_placement_generator.dart';

class BeaconSettingsEditor extends StatefulWidget {
  const BeaconSettingsEditor({
    super.key,
    required this.beacon,
  });

  final Beacon beacon;

  @override
  State<BeaconSettingsEditor> createState() => _BeaconSettingsEditorState();
}

class _BeaconSettingsEditorState extends State<BeaconSettingsEditor> {
  late final TextEditingController _nameController;
  late final TextEditingController _bleIdController;
  late final TextEditingController _majorController;
  late final TextEditingController _minorController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.beacon.name);
    _bleIdController = TextEditingController(text: widget.beacon.bleId);
    _majorController = TextEditingController(text: widget.beacon.major?.toString() ?? '');
    _minorController = TextEditingController(text: widget.beacon.minor?.toString() ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bleIdController.dispose();
    _majorController.dispose();
    _minorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Beacon settings'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Beacon name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _bleIdController,
                decoration: const InputDecoration(labelText: 'UUID / MAC'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _majorController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: false),
                      decoration: const InputDecoration(labelText: 'Major'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _minorController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: false),
                      decoration: const InputDecoration(labelText: 'Minor'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final updated = Beacon(
              id: widget.beacon.id,
              bleId: _bleIdController.text.trim(),
              name: _nameController.text.trim().isEmpty ? widget.beacon.name : _nameController.text.trim(),
              major: int.tryParse(_majorController.text.trim()),
              minor: int.tryParse(_minorController.text.trim()),
              position: widget.beacon.position,
            );
            Navigator.of(context).pop(updated);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class BeaconPlacementDemo {
  static Future<List<BeaconPlacementSuggestion>> generateSuggestionsForMap() async {
    return const BeaconPlacementGenerator().generate(
      StoreMapDummyData.example,
    );
  }
}

class StoreMapDummyData {
  static final StoreMap example = StoreMap(
    mapAsset: 'assets/floorMap.svg',
    mapWidth: 297,
    mapHeight: 210,
    metersPerUnit: 0.104,
    mapNorthOffsetDegrees: 180,
    beacons: [
      Beacon(
        id: 'b1',
        bleId: '00000000-0000-0000-0000-000000000001',
        name: 'Beacon 1',
        major: 0,
        minor: 1,
        position: const Offset(120, 50),
      ),
      Beacon(
        id: 'b2',
        bleId: '00000000-0000-0000-0000-000000000002',
        name: 'Beacon 2',
        major: 0,
        minor: 2,
        position: const Offset(160, 90),
      ),
      Beacon(
        id: 'b3',
        bleId: '00000000-0000-0000-0000-000000000003',
        name: 'Beacon 3',
        major: 0,
        minor: 3,
        position: const Offset(200, 130),
      ),
      Beacon(
        id: 'b4',
        bleId: '00000000-0000-0000-0000-000000000004',
        name: 'Beacon 4',
        major: 0,
        minor: 4,
        position: const Offset(240, 70),
      ),
    ],
    edges: const [],
    items: const [],
    beaconPlacement: const BeaconPlacementConfig(
      minSpacingMeters: 3,
      maxSpacingMeters: 6,
      targetSpacingMeters: 4.5,
      axisToleranceUnits: 2,
      dedupeRadiusMeters: 1.5,
      mountOffsetXUnits: 0,
      mountOffsetYUnits: 0,
    ),
  );
}
