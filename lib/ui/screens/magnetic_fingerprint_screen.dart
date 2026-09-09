import 'dart:math' as math;
import 'dart:io' show Platform;
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:file_picker/file_picker.dart';

import '../../models/store_map.dart';
import '../../services/magnetic_fingerprint_controller.dart';
import '../../services/wifi_fingerprint_controller.dart';
import 'survey_map_screen.dart';
import '../widgets/map_painter.dart';

enum PositioningMode { magnetic, wifi, combined }

class MagneticFingerprintScreen extends StatefulWidget {
  const MagneticFingerprintScreen({super.key, required this.controller, required this.wifiController});

  final MagneticFingerprintController controller;
  final WifiFingerprintController wifiController;

  @override
  State<MagneticFingerprintScreen> createState() => _MagneticFingerprintScreenState();
}

class _MagneticFingerprintScreenState extends State<MagneticFingerprintScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.start();
    if (!Platform.isIOS) {
      widget.wifiController.addListener(_applyWifiAnchor);
      widget.wifiController.start();
    }
  }

  void _applyWifiAnchor() {
    final match = widget.wifiController.currentMatch;
    if (match != null && match.confidence >= 0.35) {
      widget.controller.updateAnchor(match.position, confidence: match.confidence);
    }
  }

  @override
  void dispose() {
    widget.wifiController.removeListener(_applyWifiAnchor);
    super.dispose();
  }

  PositioningMode _mode = PositioningMode.magnetic;

  void _setMode(PositioningMode mode) {
    if (Platform.isIOS && mode == PositioningMode.wifi) {
      setState(() => _mode = PositioningMode.magnetic);
      return;
    }
    setState(() => _mode = mode);
    if (mode != PositioningMode.wifi) widget.controller.start();
    if (!Platform.isIOS && mode != PositioningMode.magnetic) widget.wifiController.start();
  }

  void _selectCapturePoint(Offset position) {
    if (_mode == PositioningMode.wifi) {
      widget.wifiController.selectCapturePoint(position);
    } else if (_mode == PositioningMode.magnetic || _mode == PositioningMode.combined) {
      widget.controller.addRoutePoint(position);
    }
  }

  void _startCapture() {
    if (_mode == PositioningMode.wifi) {
      if (!widget.wifiController.hasSelectedAccessPoints) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select at least one WiFi access point first.')));
        return;
      }
      widget.wifiController.beginCapture();
    } else {
      widget.controller.beginWalkingCapture();
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_mode == PositioningMode.wifi ? 'WiFi capture started. Hold the phone naturally.' : 'Walking capture started. Walk the highlighted route.')),
    );
  }

  Future<void> _export() async {
    final paths = <String>[];
    if (widget.controller.fingerprintCount + widget.controller.trajectoryCount > 0) {
      paths.add(await widget.controller.export());
    }
    if (widget.wifiController.fingerprintCount > 0) {
      paths.add(await widget.wifiController.export());
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved ${paths.join(', ')}')),
    );
  }

  Future<void> _import() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json'], withData: true);
    final bytes = result?.files.single.bytes;
    if (bytes == null) return;
    final contents = utf8.decode(bytes);
    final type = (jsonDecode(contents) as Map<String, dynamic>)['type'] as String? ?? '';
    final count = type == 'wifi-fingerprint-session'
        ? await widget.wifiController.importJson(contents)
        : await widget.controller.importJson(contents);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Imported $count fingerprints')));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final map = controller.storeMap;
    return AnimatedBuilder(
      animation: Listenable.merge([controller, widget.wifiController]),
      builder: (context, _) => Scaffold(
        appBar: AppBar(
            title: Text(_mode == PositioningMode.combined ? 'Combined Positioning' : 'Magnetic Positioning'),
          actions: [
            IconButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SurveyMapScreen(storeMap: widget.controller.storeMap, magneticController: widget.controller, wifiController: widget.wifiController))), icon: const Icon(Icons.layers_outlined), tooltip: 'Survey map'),
            IconButton(onPressed: _import, icon: const Icon(Icons.file_open_outlined), tooltip: 'Import fingerprint JSON'),
            IconButton(onPressed: controller.fingerprintCount + controller.trajectoryCount + widget.wifiController.fingerprintCount == 0 ? null : _export, icon: const Icon(Icons.ios_share), tooltip: 'Export fingerprints'),
            IconButton(onPressed: controller.fingerprintCount + controller.trajectoryCount + widget.wifiController.fingerprintCount == 0 ? null : () { controller.clearFingerprints(); widget.wifiController.clearFingerprints(); }, icon: const Icon(Icons.delete_outline), tooltip: 'Clear fingerprints'),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _Status(controller: controller, wifiController: widget.wifiController, mode: _mode),
              const SizedBox(height: 12),
              SegmentedButton<PositioningMode>(
                segments: [
                  const ButtonSegment(value: PositioningMode.magnetic, label: Text('Magnetic'), icon: Icon(Icons.explore)),
                  if (!Platform.isIOS) const ButtonSegment(value: PositioningMode.wifi, label: Text('WiFi'), icon: Icon(Icons.wifi)),
                  const ButtonSegment(value: PositioningMode.combined, label: Text('Combined'), icon: Icon(Icons.merge_type)),
                ],
                selected: {_mode},
                onSelectionChanged: (selection) => _setMode(selection.first),
              ),
              const SizedBox(height: 12),
              if (!Platform.isIOS) ...[
                _WifiAccessPointPicker(controller: widget.wifiController),
                const SizedBox(height: 12),
              ],
              _MapCapture(controller: controller, wifiController: widget.wifiController, mode: _mode, storeMap: map, onSelect: _selectCapturePoint),
              const SizedBox(height: 12),
              if (_mode == PositioningMode.magnetic && !controller.isCapturing && controller.routePoints.length >= 2)
                Row(
                  children: [
                    Expanded(child: FilledButton.icon(onPressed: _startCapture, icon: const Icon(Icons.directions_walk), label: const Text('Start walking capture'))),
                    const SizedBox(width: 8),
                    IconButton(onPressed: controller.clearRoute, icon: const Icon(Icons.close), tooltip: 'Clear route'),
                  ],
                ),
              if (_mode == PositioningMode.wifi && !widget.wifiController.isCapturing && widget.wifiController.selectedPosition != null)
                Row(
                  children: [
                    Expanded(child: FilledButton.icon(onPressed: _startCapture, icon: const Icon(Icons.wifi), label: const Text('Capture WiFi (10 samples)'))),
                    const SizedBox(width: 8),
                    IconButton(onPressed: widget.wifiController.clearSelection, icon: const Icon(Icons.close), tooltip: 'Clear selected point'),
                  ],
                ),
              if (controller.isCapturing || widget.wifiController.isCapturing)
                FilledButton.icon(
                  onPressed: _mode == PositioningMode.wifi
                      ? widget.wifiController.pointCaptureTargetReached ? widget.wifiController.finishCapture : null
                      : controller.finishWalkingCapture,
                  icon: const Icon(Icons.stop),
                    label: Text(_mode == PositioningMode.wifi
                      ? 'Finish WiFi capture (${widget.wifiController.captureSampleCount}/${WifiFingerprintController.targetPointSampleCount})'
                      : 'Finish capture (${controller.captureSampleCount} magnetic, ${widget.wifiController.captureSampleCount} WiFi samples)'),
                ),
              const SizedBox(height: 8),
              Text(
                controller.isCapturing
                    ? _mode == PositioningMode.wifi ? 'Hold the phone naturally until ${WifiFingerprintController.targetPointSampleCount} WiFi samples are collected.' : 'Walk from the first yellow point to the last yellow point at a normal pace.'
                    : _mode == PositioningMode.wifi ? 'Move to a physical spot, tap it on the SVG, then capture WiFi.' : _mode == PositioningMode.combined ? 'Detection only: the map combines available magnetic and WiFi results.' : 'Tap at least two points on the SVG in walking order, then walk that route.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.controller, required this.wifiController, required this.mode});
  final MagneticFingerprintController controller;
  final WifiFingerprintController wifiController;
  final PositioningMode mode;

  @override
  Widget build(BuildContext context) {
    final sample = controller.latestSample;
    final trajectoryMatch = controller.currentTrajectoryMatch;
    final wifiMatch = wifiController.currentMatch;
    final status = controller.isCapturing || wifiController.isCapturing
        ? 'Capturing ${controller.captureSampleCount} samples...'
      : mode == PositioningMode.wifi
        ? wifiMatch == null ? 'Record WiFi points first' : 'Estimated position • ${wifiMatch.neighborCount}-NN distance ${wifiMatch.distance.toStringAsFixed(1)}'
        : mode == PositioningMode.combined
          ? trajectoryMatch == null && wifiMatch == null ? 'Waiting for magnetic or WiFi match' : 'Combined estimate available'
          : controller.fingerprintCount + controller.trajectoryCount == 0
            ? controller.routePoints.length < 2 ? 'Tap two or more route points' : 'Route ready - start walking'
            : trajectoryMatch == null ? 'Waiting for a magnetic match' : 'Estimated position • DTW distance ${trajectoryMatch.distance.toStringAsFixed(2)}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(status, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('Magnetic routes: ${controller.trajectoryCount}   WiFi points: ${wifiController.fingerprintCount}   WiFi samples: ${wifiController.captureSampleCount}   APs: ${wifiController.visibleAccessPointCount}   Field: ${sample?.magnitude.toStringAsFixed(1) ?? '--'} µT'),
          if (wifiController.lastCompletedSampleCount > 0)
            Text('Last WiFi point: ${wifiController.lastCompletedSampleCount} samples, ${wifiController.lastCompletedUniqueVectorCount} unique RSSI vectors'),
          if (wifiController.latestScanRequestedAt != null)
            Text('Last scan requested: ${wifiController.latestScanRequestedAt!.toLocal()}'),
          if (wifiController.latestScanResultTimestampMicros != null)
            Text('Scan result timestamp: ${wifiController.latestScanResultTimestampMicros}'),
          if (mode == PositioningMode.combined) ...[
            const SizedBox(height: 8),
            Text('Magnetic: ${trajectoryMatch == null ? 'no result' : '${trajectoryMatch.position.dx.toStringAsFixed(1)}, ${trajectoryMatch.position.dy.toStringAsFixed(1)}  (${(trajectoryMatch.confidence * 100).round()}%)'}'),
            Text('WiFi: ${wifiMatch == null ? 'no result' : '${wifiMatch.position.dx.toStringAsFixed(1)}, ${wifiMatch.position.dy.toStringAsFixed(1)}  (${(wifiMatch.confidence * 100).round()}%)'}'),
          ],
          if (controller.errorMessage != null) ...[
            const SizedBox(height: 8),
            Text(controller.errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (wifiController.errorMessage != null) ...[
            const SizedBox(height: 8),
            Text(wifiController.errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ]),
      ),
    );
  }
}

class _WifiAccessPointPicker extends StatelessWidget {
  const _WifiAccessPointPicker({required this.controller});

  final WifiFingerprintController controller;

  @override
  Widget build(BuildContext context) {
    final accessPoints = controller.visibleAccessPoints.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (accessPoints.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Waiting for visible WiFi access points...'),
        ),
      );
    }
    final groups = <String, List<MapEntry<String, double>>>{};
    for (final entry in accessPoints) {
      final ssid = controller.visibleAccessPointNames[entry.key]?.trim() ?? '';
      final groupKey = ssid.isEmpty ? '__hidden__${entry.key}' : ssid;
      groups.putIfAbsent(groupKey, () => []).add(entry);
    }
    return Card(
      child: ExpansionTile(
        initiallyExpanded: controller.fingerprintCount == 0,
        title: Text('WiFi networks (${controller.selectedSsidNames.length} selected)'),
        subtitle: const Text('Choose the networks used for capture and matching'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SegmentedButton<WifiMatchingMode>(
              segments: const [
                ButtonSegment(value: WifiMatchingMode.knn, label: Text('KNN')),
                ButtonSegment(value: WifiMatchingMode.weightedKnn, label: Text('Weighted KNN')),
              ],
              selected: {controller.matchingMode},
              onSelectionChanged: controller.isCapturing
                  ? null
                  : (selection) => controller.setMatchingMode(selection.first),
            ),
          ),
          ...groups.entries.map((group) {
            final groupKey = group.key;
            final hidden = groupKey.startsWith('__hidden__');
            final displayName = hidden ? 'Hidden network' : groupKey;
            final bssids = group.value.map((entry) => entry.key).toList();
            final strongestRssi = group.value.map((entry) => entry.value).reduce(math.max);
            return CheckboxListTile(
              dense: true,
              value: controller.isSsidSelected(groupKey),
              onChanged: controller.isCapturing
                  ? null
                  : (selected) => controller.setNetworkGroupSelected(groupKey, bssids, selected ?? false),
              title: Text(displayName),
              subtitle: Text('${bssids.length} access point${bssids.length == 1 ? '' : 's'}'),
              secondary: Text('${strongestRssi.toStringAsFixed(0)} dBm'),
            );
          }),
        ],
      ),
    );
  }
}

class _MapCapture extends StatelessWidget {
  const _MapCapture({required this.controller, required this.wifiController, required this.mode, required this.storeMap, required this.onSelect});
  final MagneticFingerprintController controller;
  final WifiFingerprintController wifiController;
  final PositioningMode mode;
  final StoreMap storeMap;
  final ValueChanged<Offset> onSelect;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: storeMap.mapWidth / storeMap.mapHeight,
      child: LayoutBuilder(
        builder: (context, constraints) => GestureDetector(
            onTapUp: mode == PositioningMode.combined || controller.isCapturing || wifiController.isCapturing
              ? null
              : (details) => onSelect(Offset(
                    details.localPosition.dx * storeMap.mapWidth / constraints.maxWidth,
                    details.localPosition.dy * storeMap.mapHeight / constraints.maxHeight,
                  )),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(fit: StackFit.expand, children: [
              SvgPicture.asset(storeMap.mapAsset, fit: BoxFit.contain),
              CustomPaint(
                painter: MapPainter(
                  mapSize: Size(storeMap.mapWidth, storeMap.mapHeight),
                  path: const [],
                  edges: storeMap.edges,
                  livePosition: _estimatedPosition(),
                  capturePosition: mode == PositioningMode.wifi ? wifiController.selectedPosition : null,
                  capturePath: mode == PositioningMode.magnetic ? controller.routePoints : const [],
                  anchorPosition: wifiController.activeAnchorPosition,
                  anchorLabel: wifiController.activeAnchorName,
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Offset? _estimatedPosition() {
    if (mode == PositioningMode.magnetic) return controller.estimatedPosition;
    if (mode == PositioningMode.wifi) return wifiController.estimatedPosition;
    final magnetic = controller.estimatedPosition;
    final wifi = wifiController.estimatedPosition;
    final magneticConfidence = controller.currentTrajectoryMatch?.confidence ?? 0;
    final wifiConfidence = wifiController.currentMatch?.confidence ?? 0;
    if (magnetic == null) return wifi;
    if (wifi == null) return magnetic;
    final total = magneticConfidence + wifiConfidence;
    if (total == 0) return Offset((magnetic.dx + wifi.dx) / 2, (magnetic.dy + wifi.dy) / 2);
    return Offset(
      (magnetic.dx * magneticConfidence + wifi.dx * wifiConfidence) / total,
      (magnetic.dy * magneticConfidence + wifi.dy * wifiConfidence) / total,
    );
  }
}