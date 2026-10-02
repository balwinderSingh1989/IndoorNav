/// Tunable parameters for beacon scanning and navigation.
///
/// Values are grouped by responsibility in `navigation_config.json`. Flat keys
/// are still accepted so a remote config can be migrated without a flag day.
class IndoorNavConfig {
  const IndoorNavConfig({
    this.rollingWindow = const Duration(milliseconds: 1000),
    this.filterMode = 'both',
    this.enableComparisonLogging = true,
    this.kalmanMeasurementError = 1.0,
    this.kalmanProcessNoise = 0.04,
    this.kalmanInitialError = 2.5,
    this.staleBeaconTimeout = const Duration(seconds: 5),
    this.staleSweepInterval = const Duration(seconds: 2),
    this.watchdogNoDeviceThreshold = const Duration(seconds: 10),
    this.watchdogCheckInterval = const Duration(seconds: 5),
    this.requiredConsecutiveReadings = 5,
    this.candidatePersistence = const Duration(milliseconds: 800),
    this.switchCooldown = const Duration(milliseconds: 600),
    this.standardSwitchMarginDb = 6.0,
    this.adjacentSwitchMarginDb = 8.0,
    this.freeRoamCompetitiveMarginDb = 2.0,
    this.secondaryOvertakeMarginDb = 1.5,
    this.candidatePeakToleranceDb = 1.5,
    this.candidateWeakeningReadingsRequired = 2,
    this.reachabilityToleranceMeters = 2.0,
    this.freeRoamSwitchConfirmReadings = 5,
    this.freeRoamPersistence = const Duration(milliseconds: 300),
    this.followTickInterval = const Duration(milliseconds: 50),
    this.visualBlendPerTick = 0.35,
    this.maxBeaconCorrectionResetMeters = 8.0,
    this.rssiEmaAlpha = 0.30,
    this.rssiTrendWindowSize = 4,
    this.rssiTrendThresholdDb = 4.0,
    this.initialFixWindowSize = 10,
    this.initialFixMinSamples = 8,
    this.initialFixMinMarginDb = 8.0,
    this.initialFixMaxWait = const Duration(seconds: 6),
    this.initialFixStrongRssiDb = -65.0,
    this.initialFixStrongMinSamples = 5,
    this.initialFixStrongVarianceThresholdDb = 1.0,
    this.initialFixSustainedMarginDb = 4.0,
    this.initialFixLeaderStreakForAccept = 12,
    this.initialFixTimeoutTrendMinMarginDb = 2.0,
    this.candidateCompetitiveMarginDb = 2.0,
    this.lookAheadSecondaryLeadDb = 4.0,
  });

  final Duration rollingWindow;
  final String filterMode;
  final bool enableComparisonLogging;
  final double kalmanMeasurementError;
  final double kalmanProcessNoise;
  final double kalmanInitialError;
  final Duration staleBeaconTimeout;
  final Duration staleSweepInterval;
  final Duration watchdogNoDeviceThreshold;
  final Duration watchdogCheckInterval;
  final int requiredConsecutiveReadings;
  final Duration candidatePersistence;
  final Duration switchCooldown;
  final double standardSwitchMarginDb;
  final double adjacentSwitchMarginDb;
  final double freeRoamCompetitiveMarginDb;
  final double secondaryOvertakeMarginDb;
  final double candidatePeakToleranceDb;
  final int candidateWeakeningReadingsRequired;
  final double reachabilityToleranceMeters;
  final int freeRoamSwitchConfirmReadings;
  final Duration freeRoamPersistence;
  final Duration followTickInterval;
  final double visualBlendPerTick;
  final double maxBeaconCorrectionResetMeters;
  final double rssiEmaAlpha;
  final int rssiTrendWindowSize;
  final double rssiTrendThresholdDb;
  final int initialFixWindowSize;
  final int initialFixMinSamples;
  final double initialFixMinMarginDb;
  final Duration initialFixMaxWait;
  final double initialFixStrongRssiDb;
  final int initialFixStrongMinSamples;
  final double initialFixStrongVarianceThresholdDb;
  final double initialFixSustainedMarginDb;
  final int initialFixLeaderStreakForAccept;
  final double initialFixTimeoutTrendMinMarginDb;
  final double candidateCompetitiveMarginDb;
  final double lookAheadSecondaryLeadDb;

  factory IndoorNavConfig.fromJson(Map<String, dynamic> json) {
    final scanner = _section(json, 'scanner');
    final kalman = _section(json, 'kalman');
    final thresholds = _section(json, 'thresholds');
    final confirmation = _section(json, 'confirmation');
    final smoothing = _section(json, 'smoothing');
    final initialFix = _section(json, 'initialFix');

    return IndoorNavConfig(
      rollingWindow: _duration(scanner, json, 'rollingWindowMs', 1000),
      filterMode: _string(scanner, json, 'filterMode', 'both'),
      enableComparisonLogging:
          _bool(scanner, json, 'enableComparisonLogging', true),
      kalmanMeasurementError: _number(
          kalman, json, 'measurementError', 'kalmanMeasurementError', 1.0),
      kalmanProcessNoise:
          _number(kalman, json, 'processNoise', 'kalmanProcessNoise', 0.04),
      kalmanInitialError:
          _number(kalman, json, 'initialError', 'kalmanInitialError', 2.5),
      staleBeaconTimeout:
          _duration(scanner, json, 'staleBeaconTimeoutMs', 5000),
      staleSweepInterval:
          _duration(scanner, json, 'staleSweepIntervalMs', 2000),
      watchdogNoDeviceThreshold:
          _duration(scanner, json, 'watchdogNoDeviceThresholdMs', 10000),
      watchdogCheckInterval:
          _duration(scanner, json, 'watchdogCheckIntervalMs', 5000),
      requiredConsecutiveReadings:
          _integer(confirmation, json, 'requiredConsecutiveReadings', 5),
      candidatePersistence:
          _duration(confirmation, json, 'candidatePersistenceMs', 800),
      switchCooldown: _duration(confirmation, json, 'switchCooldownMs', 600),
      standardSwitchMarginDb: _number(thresholds, json,
          'standardSwitchMarginDb', 'standardSwitchMarginDb', 6.0),
      adjacentSwitchMarginDb: _number(thresholds, json,
          'adjacentSwitchMarginDb', 'adjacentSwitchMarginDb', 8.0),
      freeRoamCompetitiveMarginDb: _number(thresholds, json,
          'freeRoamCompetitiveMarginDb', 'freeRoamCompetitiveMarginDb', 2.0),
      secondaryOvertakeMarginDb: _number(thresholds, json,
          'secondaryOvertakeMarginDb', 'secondaryOvertakeMarginDb', 1.5),
      candidatePeakToleranceDb: _number(thresholds, json,
          'candidatePeakToleranceDb', 'candidatePeakToleranceDb', 1.5),
      candidateWeakeningReadingsRequired:
          _integer(confirmation, json, 'candidateWeakeningReadingsRequired', 2),
      reachabilityToleranceMeters: _number(thresholds, json,
          'reachabilityToleranceMeters', 'reachabilityToleranceMeters', 2.0),
      freeRoamSwitchConfirmReadings:
          _integer(confirmation, json, 'freeRoamSwitchConfirmReadings', 5),
      freeRoamPersistence:
          _duration(confirmation, json, 'freeRoamPersistenceMs', 300),
      followTickInterval:
          _duration(smoothing, json, 'followTickIntervalMs', 50),
      visualBlendPerTick: _number(
          smoothing, json, 'visualBlendPerTick', 'visualBlendPerTick', 0.35),
      maxBeaconCorrectionResetMeters: _number(
          smoothing,
          json,
          'maxBeaconCorrectionResetMeters',
          'maxBeaconCorrectionResetMeters',
          8.0),
      rssiEmaAlpha:
          _number(smoothing, json, 'rssiEmaAlpha', 'rssiEmaAlpha', 0.30),
      rssiTrendWindowSize: _integer(smoothing, json, 'rssiTrendWindowSize', 4),
      rssiTrendThresholdDb: _number(thresholds, json, 'rssiTrendThresholdDb',
          'rssiTrendThresholdDb', 4.0),
      initialFixWindowSize: _integer(initialFix, json, 'windowSize', 10,
          legacyKey: 'initialFixWindowSize'),
      initialFixMinSamples: _integer(initialFix, json, 'minSamples', 8,
          legacyKey: 'initialFixMinSamples'),
      initialFixMinMarginDb: _number(thresholds, json, 'initialFixMinMarginDb',
          'initialFixMinMarginDb', 8.0),
      initialFixMaxWait: _duration(initialFix, json, 'maxWaitMs', 6000,
          legacyKey: 'initialFixMaxWaitMs'),
      initialFixStrongRssiDb: _number(thresholds, json,
          'initialFixStrongRssiDb', 'initialFixStrongRssiDb', -65.0),
      initialFixStrongMinSamples: _integer(
          initialFix, json, 'strongMinSamples', 5,
          legacyKey: 'initialFixStrongMinSamples'),
      initialFixStrongVarianceThresholdDb: _number(
          thresholds,
          json,
          'initialFixStrongVarianceThresholdDb',
          'initialFixStrongVarianceThresholdDb',
          1.0),
      initialFixSustainedMarginDb: _number(thresholds, json,
          'initialFixSustainedMarginDb', 'initialFixSustainedMarginDb', 4.0),
      initialFixLeaderStreakForAccept: _integer(
          initialFix, json, 'leaderStreakForAccept', 12,
          legacyKey: 'initialFixLeaderStreakForAccept'),
      initialFixTimeoutTrendMinMarginDb: _number(
          thresholds,
          json,
          'initialFixTimeoutTrendMinMarginDb',
          'initialFixTimeoutTrendMinMarginDb',
          2.0),
      candidateCompetitiveMarginDb: _number(thresholds, json,
          'candidateCompetitiveMarginDb', 'candidateCompetitiveMarginDb', 2.0),
      lookAheadSecondaryLeadDb: _number(thresholds, json,
          'lookAheadSecondaryLeadDb', 'lookAheadSecondaryLeadDb', 4.0),
    );
  }

  Map<String, dynamic> toJson() => {
        'scanner': {
          'rollingWindowMs': rollingWindow.inMilliseconds,
          'filterMode': filterMode,
          'enableComparisonLogging': enableComparisonLogging,
          'staleBeaconTimeoutMs': staleBeaconTimeout.inMilliseconds,
          'staleSweepIntervalMs': staleSweepInterval.inMilliseconds,
          'watchdogNoDeviceThresholdMs':
              watchdogNoDeviceThreshold.inMilliseconds,
          'watchdogCheckIntervalMs': watchdogCheckInterval.inMilliseconds,
        },
        'kalman': {
          'measurementError': kalmanMeasurementError,
          'processNoise': kalmanProcessNoise,
          'initialError': kalmanInitialError,
        },
        'thresholds': {
          'standardSwitchMarginDb': standardSwitchMarginDb,
          'adjacentSwitchMarginDb': adjacentSwitchMarginDb,
          'freeRoamCompetitiveMarginDb': freeRoamCompetitiveMarginDb,
          'secondaryOvertakeMarginDb': secondaryOvertakeMarginDb,
          'candidatePeakToleranceDb': candidatePeakToleranceDb,
          'reachabilityToleranceMeters': reachabilityToleranceMeters,
          'rssiTrendThresholdDb': rssiTrendThresholdDb,
          'initialFixMinMarginDb': initialFixMinMarginDb,
          'initialFixStrongRssiDb': initialFixStrongRssiDb,
          'initialFixStrongVarianceThresholdDb':
              initialFixStrongVarianceThresholdDb,
          'initialFixSustainedMarginDb': initialFixSustainedMarginDb,
          'initialFixTimeoutTrendMinMarginDb':
              initialFixTimeoutTrendMinMarginDb,
          'candidateCompetitiveMarginDb': candidateCompetitiveMarginDb,
          'lookAheadSecondaryLeadDb': lookAheadSecondaryLeadDb,
        },
        'confirmation': {
          'requiredConsecutiveReadings': requiredConsecutiveReadings,
          'candidatePersistenceMs': candidatePersistence.inMilliseconds,
          'switchCooldownMs': switchCooldown.inMilliseconds,
          'candidateWeakeningReadingsRequired':
              candidateWeakeningReadingsRequired,
          'freeRoamSwitchConfirmReadings': freeRoamSwitchConfirmReadings,
          'freeRoamPersistenceMs': freeRoamPersistence.inMilliseconds,
        },
        'smoothing': {
          'rssiEmaAlpha': rssiEmaAlpha,
          'rssiTrendWindowSize': rssiTrendWindowSize,
          'followTickIntervalMs': followTickInterval.inMilliseconds,
          'visualBlendPerTick': visualBlendPerTick,
          'maxBeaconCorrectionResetMeters': maxBeaconCorrectionResetMeters,
        },
        'initialFix': {
          'windowSize': initialFixWindowSize,
          'minSamples': initialFixMinSamples,
          'maxWaitMs': initialFixMaxWait.inMilliseconds,
          'strongMinSamples': initialFixStrongMinSamples,
          'leaderStreakForAccept': initialFixLeaderStreakForAccept,
        },
      };

  static Map<String, dynamic> _section(Map<String, dynamic> json, String key) {
    final value = json[key];
    return value is Map<String, dynamic> ? value : const {};
  }

  static dynamic _value(Map<String, dynamic> section, Map<String, dynamic> root,
          String key, String legacyKey) =>
      section.containsKey(key) ? section[key] : root[legacyKey];

  static double _number(Map<String, dynamic> section, Map<String, dynamic> root,
          String key, String legacyKey, double fallback) =>
      (_value(section, root, key, legacyKey) as num? ?? fallback).toDouble();

  static int _integer(Map<String, dynamic> section, Map<String, dynamic> root,
          String key, int fallback, {String? legacyKey}) =>
      (_value(section, root, key, legacyKey ?? key) as num? ?? fallback)
          .toInt();

  static Duration _duration(Map<String, dynamic> section,
          Map<String, dynamic> root, String key, int fallbackMs,
          {String? legacyKey}) =>
      Duration(
          milliseconds: (_value(section, root, key, legacyKey ?? key) as num? ??
                  fallbackMs)
              .toInt());

  static String _string(Map<String, dynamic> section, Map<String, dynamic> root,
          String key, String fallback) =>
      (_value(section, root, key, key) as String?) ?? fallback;

  static bool _bool(Map<String, dynamic> section, Map<String, dynamic> root,
          String key, bool fallback) =>
      (_value(section, root, key, key) as bool?) ?? fallback;
}
