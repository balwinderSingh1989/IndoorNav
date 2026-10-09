import '../models/beacon_fingerprint.dart';

/// A fingerprint candidate aggregated across the available algorithms.
class FingerprintFusionCandidate {
  const FingerprintFusionCandidate({
    required this.zoneId,
    required this.confidence,
    required this.marginToRunnerUp,
    required this.algorithmVotes,
  });

  final String zoneId;
  final double confidence;
  final double marginToRunnerUp;
  final int algorithmVotes;
}

/// Adds temporal hysteresis to fingerprint zone candidates.
///
/// This is deliberately independent from NavigationController. It can be used
/// for Survey diagnostics first, then later become a candidate source for a
/// navigation fusion layer without changing route/PDR logic.
class FingerprintFusionSelector {
  FingerprintFusionSelector({
    this.minimumConfidence = 0.60,
    this.minimumMargin = 0.08,
    this.minimumAlgorithmVotes = 2,
    this.requiredStableUpdates = 3,
    this.requiredPersistence = const Duration(milliseconds: 300),
    this.switchCooldown = const Duration(milliseconds: 800),
  });

  final double minimumConfidence;
  final double minimumMargin;
  final int minimumAlgorithmVotes;
  final int requiredStableUpdates;
  final Duration requiredPersistence;
  final Duration switchCooldown;

  String? confirmedZoneId;
  FingerprintFusionCandidate? pendingCandidate;
  int _pendingUpdates = 0;
  DateTime? _pendingSince;
  DateTime? _lastConfirmedAt;

  /// Returns the confirmed zone when this update commits a change.
  String? update(FingerprintFusionCandidate? candidate, {DateTime? now}) {
    final timestamp = now ?? DateTime.now();
    if (candidate == null ||
        candidate.confidence < minimumConfidence ||
        candidate.marginToRunnerUp < minimumMargin ||
        candidate.algorithmVotes < minimumAlgorithmVotes) {
      _clearPending();
      return null;
    }

    if (candidate.zoneId == confirmedZoneId) {
      _clearPending();
      return null;
    }

    if (pendingCandidate?.zoneId == candidate.zoneId) {
      _pendingUpdates++;
    } else {
      pendingCandidate = candidate;
      _pendingUpdates = 1;
      _pendingSince = timestamp;
    }

    final pendingAge = _pendingSince == null
        ? Duration.zero
        : timestamp.difference(_pendingSince!);
    final inCooldown = _lastConfirmedAt != null &&
        timestamp.difference(_lastConfirmedAt!) < switchCooldown;
    if (_pendingUpdates < requiredStableUpdates ||
        pendingAge < requiredPersistence ||
        inCooldown) {
      return null;
    }

    confirmedZoneId = candidate.zoneId;
    _lastConfirmedAt = timestamp;
    _clearPending();
    return confirmedZoneId;
  }

  void reset() {
    confirmedZoneId = null;
    pendingCandidate = null;
    _pendingUpdates = 0;
    _pendingSince = null;
    _lastConfirmedAt = null;
  }

  void _clearPending() {
    pendingCandidate = null;
    _pendingUpdates = 0;
    _pendingSince = null;
  }
}

/// Aggregates passing algorithm results into one candidate and computes a
/// runner-up margin. Lower-level score normalization remains in the service.
FingerprintFusionCandidate? aggregateFingerprintCandidates({
  required Map<BeaconDistanceAlgorithm, DistanceResult?> results,
  required Map<BeaconDistanceAlgorithm, double?> confidences,
  required Map<BeaconDistanceAlgorithm, bool> passesThreshold,
}) {
  final byZone = <String, List<double>>{};
  for (final entry in results.entries) {
    final result = entry.value;
    final confidence = confidences[entry.key];
    if (result == null || confidence == null || !passesThreshold[entry.key]!) {
      continue;
    }
    byZone.putIfAbsent(result.zoneName, () => []).add(confidence);
  }
  if (byZone.isEmpty) return null;

  final ranked = byZone.entries.toList()
    ..sort((first, second) {
      final firstScore = _average(first.value);
      final secondScore = _average(second.value);
      return secondScore.compareTo(firstScore);
    });
  final winner = ranked.first;
  final winnerConfidence = _average(winner.value);
  final runnerUpConfidence =
      ranked.length > 1 ? _average(ranked[1].value) : 0.0;
  return FingerprintFusionCandidate(
    zoneId: winner.key,
    confidence: winnerConfidence,
    marginToRunnerUp: winnerConfidence - runnerUpConfidence,
    algorithmVotes: winner.value.length,
  );
}

double _average(List<double> values) =>
    values.reduce((first, second) => first + second) / values.length;
