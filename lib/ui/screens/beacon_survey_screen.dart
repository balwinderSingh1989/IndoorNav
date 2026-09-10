import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../models/beacon.dart';
import '../../models/store_map.dart';
import '../../services/ble_scanner_service.dart';

class BeaconSurveyScreen extends StatefulWidget {
  const BeaconSurveyScreen({super.key, required this.storeMap, required this.bleScanner});

  final StoreMap storeMap;
  final BleScannerService bleScanner;

  @override
  State<BeaconSurveyScreen> createState() => _BeaconSurveyScreenState();
}

class _BeaconSurveyScreenState extends State<BeaconSurveyScreen> {
  late Beacon _selectedBeacon;
  late final Map<String, Offset> _surveyedPositions;
  late final List<TextEditingController> _distanceControllers;
  late final Map<int, List<Offset>> _surveyedWaypoints;
  int? _selectedEdgeIndex;
  bool _waypointMode = false;
  List<BeaconScanInfo> _nearbyBeacons = const [];
  StreamSubscription<List<BeaconScanInfo>>? _scanInfoSub;

  @override
  void initState() {
    super.initState();
    _selectedBeacon = widget.storeMap.beacons.first;
    _surveyedPositions = {
      for (final beacon in widget.storeMap.beacons) beacon.id: beacon.position,
    };
    _distanceControllers = [
      for (final edge in widget.storeMap.edges)
        TextEditingController(text: edge.distanceMeters.toString()),
    ];
    _surveyedWaypoints = {
      for (var i = 0; i < widget.storeMap.edges.length; i++)
        i: List<Offset>.from(widget.storeMap.edges[i].waypoints),
    };
    _nearbyBeacons = widget.bleScanner.latestScanInfo;
    _scanInfoSub = widget.bleScanner.scanInfoStream.listen((infos) {
      if (mounted) setState(() => _nearbyBeacons = infos);
    });
  }

  @override
  void dispose() {
    for (final controller in _distanceControllers) {
      controller.dispose();
    }
    _scanInfoSub?.cancel();
    super.dispose();
  }

  Offset _screenPosition(Offset mapPosition, Size size) => Offset(
        mapPosition.dx * size.width / widget.storeMap.mapWidth,
        mapPosition.dy * size.height / widget.storeMap.mapHeight,
      );

  Offset _mapPosition(Offset screenPosition, Size size) => Offset(
        (screenPosition.dx * widget.storeMap.mapWidth / size.width).clamp(0.0, widget.storeMap.mapWidth),
        (screenPosition.dy * widget.storeMap.mapHeight / size.height).clamp(0.0, widget.storeMap.mapHeight),
      );

  void _recordTap(TapUpDetails details, Size size) {
    setState(() {
      final point = _mapPosition(details.localPosition, size);
      if (_waypointMode && _selectedEdgeIndex != null) {
        _surveyedWaypoints[_selectedEdgeIndex!]!.add(point);
      } else {
        _surveyedPositions[_selectedBeacon.id] = point;
      }
    });
  }

  void _clearWaypoints() {
    final index = _selectedEdgeIndex;
    if (index == null) return;
    setState(() => _surveyedWaypoints[index]!.clear());
  }

  void _undoWaypoint() {
    final index = _selectedEdgeIndex;
    if (index == null || _surveyedWaypoints[index]!.isEmpty) return;
    setState(() => _surveyedWaypoints[index]!.removeLast());
  }

  Future<void> _copyExport() async {
    final payload = {
      'beacons': widget.storeMap.beacons.map((beacon) {
        final position = _surveyedPositions[beacon.id] ?? beacon.position;
        return {
          'id': beacon.id,
          'bleId': beacon.bleId,
          'major': beacon.major,
          'minor': beacon.minor,
          'name': beacon.name,
          'x': double.parse(position.dx.toStringAsFixed(2)),
          'y': double.parse(position.dy.toStringAsFixed(2)),
        };
      }).toList(),
      'edges': [
        for (var i = 0; i < widget.storeMap.edges.length; i++)
          {
            'from': widget.storeMap.edges[i].from,
            'to': widget.storeMap.edges[i].to,
            'distanceMeters': double.tryParse(_distanceControllers[i].text.trim()) ?? widget.storeMap.edges[i].distanceMeters,
            if (_surveyedWaypoints[i]!.isNotEmpty)
              'waypoints': [
                for (final point in _surveyedWaypoints[i]!)
                  {'x': double.parse(point.dx.toStringAsFixed(2)), 'y': double.parse(point.dy.toStringAsFixed(2))},
              ],
          },
      ],
    };
    await Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent('  ').convert(payload)));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Survey JSON copied')));
  }

  String? _validationMessage() {
    for (final entry in _surveyedPositions.entries) {
      final position = entry.value;
      if (position.dx < 0 || position.dx > widget.storeMap.mapWidth || position.dy < 0 || position.dy > widget.storeMap.mapHeight) {
        return '${entry.key} is outside the SVG bounds';
      }
    }
    for (var i = 0; i < widget.storeMap.edges.length; i++) {
      final value = double.tryParse(_distanceControllers[i].text.trim());
      if (value == null || value <= 0) return 'Edge ${widget.storeMap.edges[i].from} -> ${widget.storeMap.edges[i].to} needs a positive distance';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final validation = _validationMessage();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Beacon survey setup'),
        actions: [
          IconButton(
            onPressed: validation == null ? _copyExport : null,
            icon: const Icon(Icons.copy_outlined),
            tooltip: 'Copy survey JSON',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Tap the actual mounted location for the selected beacon. Coordinates are converted back to SVG units automatically.', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 12),
          DropdownButtonFormField<Beacon>(
            initialValue: _selectedBeacon,
            decoration: const InputDecoration(labelText: 'Beacon to survey', border: OutlineInputBorder()),
            items: [
              for (final beacon in widget.storeMap.beacons)
                DropdownMenuItem(value: beacon, child: Text('${beacon.id} · ${beacon.name}')),
            ],
            onChanged: (beacon) => beacon == null ? null : setState(() => _selectedBeacon = beacon),
          ),
          const SizedBox(height: 12),
          AspectRatio(
            aspectRatio: widget.storeMap.mapWidth / widget.storeMap.mapHeight,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                final selectedEdge = _selectedEdgeIndex == null ? null : widget.storeMap.edges[_selectedEdgeIndex!];
                final selectedWaypoints = _selectedEdgeIndex == null ? const <Offset>[] : _surveyedWaypoints[_selectedEdgeIndex!]!;
                return GestureDetector(
                  onTapUp: (details) => _recordTap(details, size),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SvgPicture.asset(widget.storeMap.mapAsset, fit: BoxFit.contain),
                      ),
                      for (final beacon in widget.storeMap.beacons)
                        Positioned(
                          left: _screenPosition(_surveyedPositions[beacon.id]!, size).dx - 10,
                          top: _screenPosition(_surveyedPositions[beacon.id]!, size).dy - 10,
                          child: IgnorePointer(
                            child: Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                color: beacon.id == _selectedBeacon.id ? Colors.red : Colors.blue,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2),
                              ),
                              child: Center(child: Text(beacon.id.replaceFirst('b', ''), style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold))),
                            ),
                          ),
                        ),
                      if (selectedEdge != null) ...[
                        for (final point in [
                          _surveyedPositions[selectedEdge.from]!,
                          ...selectedWaypoints,
                          _surveyedPositions[selectedEdge.to]!,
                        ])
                          Positioned(
                            left: _screenPosition(point, size).dx - 5,
                            top: _screenPosition(point, size).dy - 5,
                            child: IgnorePointer(
                              child: Container(
                                width: 10,
                                height: 10,
                                decoration: const BoxDecoration(color: Colors.orange, shape: BoxShape.circle),
                              ),
                            ),
                          ),
                        if (selectedWaypoints.length > 1)
                          CustomPaint(
                            painter: _SurveyPolylinePainter(
                              points: [
                                _surveyedPositions[selectedEdge.from]!,
                                ...selectedWaypoints,
                                _surveyedPositions[selectedEdge.to]!,
                              ],
                              mapSize: Size(widget.storeMap.mapWidth, widget.storeMap.mapHeight),
                            ),
                          ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Text('Selected ${_selectedBeacon.id}: (${_surveyedPositions[_selectedBeacon.id]!.dx.toStringAsFixed(1)}, ${_surveyedPositions[_selectedBeacon.id]!.dy.toStringAsFixed(1)})'),
          const SizedBox(height: 16),
          Text('Measured corridor distances', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (var i = 0; i < widget.storeMap.edges.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: _distanceControllers[i],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: '${widget.storeMap.edges[i].from} -> ${widget.storeMap.edges[i].to}',
                  suffixText: 'm',
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          const SizedBox(height: 16),
          Text('Waypoint editing', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Select an edge, enable waypoint mode, then tap corridor bends on the map in order.'),
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            initialValue: _selectedEdgeIndex,
            decoration: const InputDecoration(labelText: 'Edge to shape', border: OutlineInputBorder()),
            items: [
              for (var i = 0; i < widget.storeMap.edges.length; i++)
                DropdownMenuItem(value: i, child: Text('${widget.storeMap.edges[i].from} -> ${widget.storeMap.edges[i].to}')),
            ],
            onChanged: (index) => setState(() => _selectedEdgeIndex = index),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Waypoint mode'),
            subtitle: Text(_selectedEdgeIndex == null
                ? 'Select an edge first'
                : '${_surveyedWaypoints[_selectedEdgeIndex!]!.length} waypoint(s) recorded'),
            value: _waypointMode,
            onChanged: _selectedEdgeIndex == null ? null : (enabled) => setState(() => _waypointMode = enabled),
          ),
          Row(
            children: [
              OutlinedButton.icon(onPressed: _waypointMode ? _undoWaypoint : null, icon: const Icon(Icons.undo), label: const Text('Undo')),
              const SizedBox(width: 8),
              OutlinedButton.icon(onPressed: _waypointMode ? _clearWaypoints : null, icon: const Icon(Icons.clear), label: const Text('Clear')),
            ],
          ),
          if (_selectedEdgeIndex != null)
            Text('Waypoints: ${_surveyedWaypoints[_selectedEdgeIndex!]!.map((point) => '(${point.dx.toStringAsFixed(1)}, ${point.dy.toStringAsFixed(1)})').join(' -> ')}'),
          const SizedBox(height: 16),
          Text('Nearby beacons', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Use the strongest RSSI and identity fields to identify the physical unit you are standing near.'),
          const SizedBox(height: 8),
          if (_nearbyBeacons.isEmpty)
            const Text('No recognized beacons yet. Keep Bluetooth enabled and wait for a scan.')
          else
            ..._nearbyBeacons.map((info) {
              final configured = widget.storeMap.beaconByBleId(info.key);
              return Card(
                child: ListTile(
                  leading: CircleAvatar(child: Text(info.rssi.round().toString())),
                  title: Text(configured == null ? 'Unconfigured beacon' : '${configured.id} · ${configured.name}'),
                  subtitle: Text('RSSI ${info.rssi.toStringAsFixed(1)} dBm\n'
                      'Identity: ${info.key}\n'
                      'Scanner ID: ${info.scannerId}\n'
                      'Advertised name: ${info.name.isEmpty ? '(none)' : info.name}'),
                  isThreeLine: true,
                  trailing: configured?.id == _selectedBeacon.id
                      ? const Icon(Icons.check_circle, color: Colors.green)
                      : null,
                ),
              );
            }),
          if (validation != null)
            Text(validation, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: validation == null ? _copyExport : null,
            icon: const Icon(Icons.copy),
            label: const Text('Copy survey JSON'),
          ),
        ],
      ),
    );
  }
}

class _SurveyPolylinePainter extends CustomPainter {
  const _SurveyPolylinePainter({required this.points, required this.mapSize});

  final List<Offset> points;
  final Size mapSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final paint = Paint()
      ..color = Colors.orange
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Offset scale(Offset point) => Offset(
          point.dx * size.width / mapSize.width,
          point.dy * size.height / mapSize.height,
        );
    final path = Path()..moveTo(scale(points.first).dx, scale(points.first).dy);
    for (final point in points.skip(1)) {
      final scaled = scale(point);
      path.lineTo(scaled.dx, scaled.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SurveyPolylinePainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.mapSize != mapSize;
}
