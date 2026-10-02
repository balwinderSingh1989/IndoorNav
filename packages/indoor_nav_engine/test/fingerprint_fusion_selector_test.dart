import 'package:indoor_nav_engine/indoor_nav_engine.dart';
import 'package:test/test.dart';

void main() {
  test('does not commit a single noisy winner', () {
    final selector = FingerprintFusionSelector(
      requiredStableUpdates: 2,
      requiredPersistence: Duration.zero,
    );
    final candidate = _candidate('chatgpt', confidence: 0.9, margin: 0.2);

    expect(selector.update(candidate), isNull);
    expect(selector.confirmedZoneId, isNull);
  });

  test('commits only after stable updates and persistence', () {
    final selector = FingerprintFusionSelector(
      requiredStableUpdates: 3,
      requiredPersistence: const Duration(milliseconds: 300),
      switchCooldown: Duration.zero,
    );
    final candidate = _candidate('chatgpt', confidence: 0.9, margin: 0.2);
    final start = DateTime(2026, 1, 1);

    expect(selector.update(candidate, now: start), isNull);
    expect(
      selector.update(candidate, now: start.add(const Duration(milliseconds: 150))),
      isNull,
    );
    expect(
      selector.update(candidate, now: start.add(const Duration(milliseconds: 350))),
      'chatgpt',
    );
  });

  test('rejects close winners without a runner-up margin', () {
    final selector = FingerprintFusionSelector(requiredStableUpdates: 1);

    expect(
      selector.update(_candidate('seating-2', confidence: 0.9, margin: 0.03)),
      isNull,
    );
  });
}

FingerprintFusionCandidate _candidate(
  String zoneId, {
  required double confidence,
  required double margin,
}) => FingerprintFusionCandidate(
      zoneId: zoneId,
      confidence: confidence,
      marginToRunnerUp: margin,
      algorithmVotes: 2,
    );
