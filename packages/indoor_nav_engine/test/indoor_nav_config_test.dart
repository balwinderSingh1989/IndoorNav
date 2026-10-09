import 'package:indoor_nav_engine/indoor_nav_engine.dart';
import 'package:test/test.dart';

void main() {
  test('loads grouped scanner and navigation tuning from JSON', () {
    final config = IndoorNavConfig.fromJson({
      'scanner': {
        'rollingWindowMs': 1500,
        'filterMode': 'kalman',
        'enableComparisonLogging': false,
      },
      'kalman': {
        'measurementError': 0.8,
        'processNoise': 0.06,
        'initialError': 3.0,
      },
      'thresholds': {
        'adjacentSwitchMarginDb': 9.0,
        'initialFixMinMarginDb': 7.0,
      },
      'smoothing': {'visualBlendPerTick': 0.5},
      'initialFix': {'maxWaitMs': 7000},
    });

    expect(config.rollingWindow, const Duration(milliseconds: 1500));
    expect(config.filterMode, 'kalman');
    expect(config.enableComparisonLogging, isFalse);
    expect(config.kalmanMeasurementError, 0.8);
    expect(config.kalmanProcessNoise, 0.06);
    expect(config.kalmanInitialError, 3.0);
    expect(config.adjacentSwitchMarginDb, 9.0);
    expect(config.initialFixMaxWait, const Duration(seconds: 7));
    expect(config.visualBlendPerTick, 0.5);
  });

  test('accepts the legacy flat shape during migration', () {
    final config = IndoorNavConfig.fromJson({
      'kalmanMeasurementError': 0.8,
      'initialFixMaxWaitMs': 7000,
      'visualBlendPerTick': 0.5,
    });

    expect(config.kalmanMeasurementError, 0.8);
    expect(config.initialFixMaxWait, const Duration(seconds: 7));
    expect(config.visualBlendPerTick, 0.5);
  });

  test('serializes runtime tuning into functional sections', () {
    final json = const IndoorNavConfig().toJson();

    expect((json['kalman'] as Map)['measurementError'], 1.0);
    expect((json['kalman'] as Map)['processNoise'], 0.04);
    expect((json['kalman'] as Map)['initialError'], 2.5);
    expect((json['scanner'] as Map)['watchdogNoDeviceThresholdMs'], 10000);
    expect((json['initialFix'] as Map)['leaderStreakForAccept'], 12);
  });
}
