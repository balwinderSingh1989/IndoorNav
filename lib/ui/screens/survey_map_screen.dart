import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../models/store_map.dart';
import '../../models/wifi_fingerprint.dart';
import '../../services/magnetic_fingerprint_controller.dart';
import '../../services/wifi_fingerprint_controller.dart';
import '../widgets/survey_map_painter.dart';

class SurveyMapScreen extends StatefulWidget {
  const SurveyMapScreen({super.key, required this.storeMap, required this.magneticController, required this.wifiController});

  final StoreMap storeMap;
  final MagneticFingerprintController magneticController;
  final WifiFingerprintController wifiController;

  @override
  State<SurveyMapScreen> createState() => _SurveyMapScreenState();
}

class _SurveyMapScreenState extends State<SurveyMapScreen> with SingleTickerProviderStateMixin {
  bool _showMagnetic = true;
  bool _showWifi = true;
  bool _showGaps = true;
  bool _showSimilar = true;
  String? _highlightedAnchorBssid;
  late final AnimationController _anchorBlink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _anchorBlink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.magneticController, widget.wifiController]),
      builder: (context, _) {
        final map = widget.storeMap;
        final trajectories = widget.magneticController.service.surveyTrajectories;
        final wifiPoints = widget.wifiController.service.surveyFingerprints;
        final anchorSuggestions = widget.wifiController.service.anchorSuggestions;
        final allAnchorPositions = widget.wifiController.service.anchorPositions;
        final anchorPositions = {
          for (final entry in allAnchorPositions.entries)
            if (widget.wifiController.anchorBssids.contains(entry.key)) entry.key: entry.value,
        };
        return Scaffold(
          appBar: AppBar(title: const Text('Survey Map')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _SurveySummary(trajectories: trajectories, wifiPoints: wifiPoints),
              const SizedBox(height: 12),
              AspectRatio(
                aspectRatio: map.mapWidth / map.mapHeight,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Stack(fit: StackFit.expand, children: [
                    SvgPicture.asset(map.mapAsset, fit: BoxFit.contain),
                    CustomPaint(
                      painter: SurveyMapPainter(
                        mapSize: Size(map.mapWidth, map.mapHeight),
                        trajectories: trajectories,
                        wifiFingerprints: wifiPoints,
                        showMagnetic: _showMagnetic,
                        showWifi: _showWifi,
                        showGaps: _showGaps,
                        showSimilarMagnetic: _showSimilar,
                        anchorPositions: anchorPositions,
                        highlightedAnchorBssid: _highlightedAnchorBssid,
                        highlightProgress: _anchorBlink.value,
                      ),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              _Legend(
                showMagnetic: _showMagnetic,
                showWifi: _showWifi,
                showGaps: _showGaps,
                showSimilar: _showSimilar,
                onChanged: (magnetic, wifi, gaps, similar) => setState(() {
                  _showMagnetic = magnetic;
                  _showWifi = wifi;
                  _showGaps = gaps;
                  _showSimilar = similar;
                }),
              ),
              const SizedBox(height: 12),
              _WifiAnchors(
                controller: widget.wifiController,
                suggestions: anchorSuggestions,
                highlightedBssid: _highlightedAnchorBssid,
                onHighlight: (bssid) => setState(() => _highlightedAnchorBssid = bssid),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SurveySummary extends StatelessWidget {
  const _SurveySummary({required this.trajectories, required this.wifiPoints});
  final List trajectories;
  final List wifiPoints;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Magnetic routes: ${trajectories.length}    WiFi points: ${wifiPoints.length}\nRed cells need more coverage • Orange markers show repeated magnetic ranges'),
        ),
      );
}

class _Legend extends StatelessWidget {
  const _Legend({required this.showMagnetic, required this.showWifi, required this.showGaps, required this.showSimilar, required this.onChanged});
  final bool showMagnetic;
  final bool showWifi;
  final bool showGaps;
  final bool showSimilar;
  final void Function(bool, bool, bool, bool) onChanged;

  @override
  Widget build(BuildContext context) => Card(
        child: Column(children: [
          SwitchListTile(title: const Text('Magnetic routes'), value: showMagnetic, onChanged: (value) => onChanged(value, showWifi, showGaps, showSimilar)),
          SwitchListTile(title: const Text('WiFi fingerprints'), value: showWifi, onChanged: (value) => onChanged(showMagnetic, value, showGaps, showSimilar)),
          SwitchListTile(title: const Text('Coverage gaps'), value: showGaps, onChanged: (value) => onChanged(showMagnetic, showWifi, value, showSimilar)),
          SwitchListTile(title: const Text('Similar magnetic areas'), value: showSimilar, onChanged: (value) => onChanged(showMagnetic, showWifi, showGaps, value)),
        ]),
      );
}

class _WifiAnchors extends StatelessWidget {
  const _WifiAnchors({required this.controller, required this.suggestions, required this.highlightedBssid, required this.onHighlight});
  final WifiFingerprintController controller;
  final List<WifiAnchorSuggestion> suggestions;
  final String? highlightedBssid;
  final ValueChanged<String> onHighlight;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ExpansionTile(
        title: const Text('Best WiFi anchors'),
        subtitle: const Text('APs present at the most surveyed points'),
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton.icon(
              onPressed: () async {
                await controller.useSuggestedAnchors(suggestions.take(8).map((suggestion) => suggestion.bssid));
              },
              icon: const Icon(Icons.star_outline),
              label: const Text('Keep suggested anchors only'),
            ),
          ),
              ...suggestions.take(12).map((suggestion) => InkWell(
                    onTap: () => onHighlight(suggestion.bssid),
                    child: CheckboxListTile(
                      value: controller.anchorBssids.contains(suggestion.bssid),
                      selected: highlightedBssid == suggestion.bssid,
                      onChanged: (selected) => controller.setAnchorSelected(suggestion.bssid, selected ?? false),
                      title: Text(controller.anchorDisplayName(suggestion.bssid)),
                      subtitle: Text('Zone spread ${suggestion.zoneSpread.toStringAsFixed(1)} • coverage ${(suggestion.coverage * 100).round()}% • ${suggestion.bssid}'),
                      secondary: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(suggestion.score.toStringAsFixed(2)),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: 'Name anchor',
                            onPressed: () async {
                              final nameController = TextEditingController(text: controller.anchorNames[suggestion.bssid] ?? suggestion.ssid);
                              final name = await showDialog<String>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Name WiFi anchor'),
                                  content: TextField(controller: nameController, autofocus: true, decoration: const InputDecoration(labelText: 'Anchor name')),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                                    FilledButton(onPressed: () => Navigator.pop(context, nameController.text), child: const Text('Save')),
                                  ],
                                ),
                              );
                              nameController.dispose();
                              if (name != null) await controller.renameAnchor(suggestion.bssid, name);
                            },
                          ),
                        ],
                      ),
                    ),
                  )),
        ],
      ),
    );
  }
}