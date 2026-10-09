import 'package:flutter/material.dart';

import 'package:indoor_nav_engine/indoor_nav_engine.dart';

class BeaconFingerprintScreen extends StatefulWidget {
  const BeaconFingerprintScreen({super.key, required this.controller});

  final BeaconFingerprintController controller;

  @override
  State<BeaconFingerprintScreen> createState() =>
      _BeaconFingerprintScreenState();
}

class _BeaconFingerprintScreenState extends State<BeaconFingerprintScreen> {
  BeaconFingerprintController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onChanged);
    controller.init();
  }

  @override
  void dispose() {
    controller.removeListener(_onChanged);
    controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final selectedBeacon = controller.selectedBeacon;
    return Scaffold(
      appBar: AppBar(title: const Text('Beacon fingerprints')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Standing zone', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: selectedBeacon?.id,
            isExpanded: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.sensors),
            ),
            hint: const Text('Select the beacon for this zone'),
            items: [
              for (final beacon in controller.beacons)
                DropdownMenuItem(
                  value: beacon.id,
                  child: Text(beacon.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: controller.isCapturing
                ? null
                : (beaconId) => controller.selectBeacon(
                      controller.beacons
                          .where((beacon) => beacon.id == beaconId)
                          .firstOrNull,
                    ),
          ),
          const SizedBox(height: 12),
          Text(
            selectedBeacon == null
                ? 'No configured beacon is available.'
                : 'Capture here while standing in ${selectedBeacon.name}. The saved fingerprint contains all nearby BLE beacons.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          Text('Capture duration: ${controller.captureDuration}s',
              style: Theme.of(context).textTheme.titleSmall),
          Slider(
            value: controller.captureDuration.toDouble(),
            min: 5,
            max: 60,
            divisions: 11,
            label: '${controller.captureDuration}s',
            onChanged: controller.isCapturing
                ? null
                : (value) =>
                    setState(() => controller.captureDuration = value.round()),
          ),
          FilledButton.icon(
            onPressed: controller.isCapturing || selectedBeacon == null
                ? null
                : controller.startCapture,
            icon: controller.isCapturing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.fingerprint),
            label: Text(controller.isCapturing
                ? 'Capturing ${controller.captureProgress}%'
                : 'Capture fingerprint'),
          ),
          if (controller.isCapturing) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: controller.captureProgress / 100),
          ],
          const SizedBox(height: 12),
          Text(controller.statusMessage,
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 28),
          Row(
            children: [
              Text('Live quality',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 8),
              Text('${controller.currentReadings.length} nearby readings',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'All methods run in parallel. A red dot means this method identifies the selected standing zone within its quality threshold.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          for (final algorithm in BeaconDistanceAlgorithm.values) ...[
            _QualityCard(
              quality: controller.liveQuality[algorithm],
              isSelected: controller.currentAlgorithm == algorithm,
              onSelect: () => controller.switchAlgorithm(algorithm),
            ),
            const SizedBox(height: 8),
          ],
          if (controller.liveQuality.isEmpty)
            _EmptyQuality(selectedBeaconName: selectedBeacon?.name),
          const SizedBox(height: 24),
          Text('Saved zones: ${controller.zones.length}',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _QualityCard extends StatelessWidget {
  const _QualityCard(
      {required this.quality,
      required this.isSelected,
      required this.onSelect});

  final FingerprintQuality? quality;
  final bool isSelected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final algorithm = quality?.algorithm;
    final successful = quality?.isSuccessful ?? false;
    final score = quality?.result?.distance;
    final isCorrelation = algorithm == BeaconDistanceAlgorithm.timeSeries;
    return Card(
      color:
          isSelected ? Theme.of(context).colorScheme.secondaryContainer : null,
      child: ListTile(
        onTap: onSelect,
        leading: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: successful ? Colors.red : Colors.grey.shade400,
            shape: BoxShape.circle,
          ),
        ),
        title: Text(algorithm?.displayName ?? 'Waiting for fingerprint'),
        subtitle: Text(
          score == null
              ? 'Capture this selected zone, then wait for live BLE readings.'
              : '${isCorrelation ? 'Correlation' : 'Distance'}: ${score.toStringAsFixed(2)} | Matched beacons: ${quality!.result!.matchedBeaconCount}',
        ),
        trailing: isSelected ? const Icon(Icons.check_circle) : null,
      ),
    );
  }
}

class _EmptyQuality extends StatelessWidget {
  const _EmptyQuality({required this.selectedBeaconName});

  final String? selectedBeaconName;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Text(
        selectedBeaconName == null
            ? 'Choose a beacon to start.'
            : 'Capture $selectedBeaconName once, then the three live quality scores will appear here.',
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
