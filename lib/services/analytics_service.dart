import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/beacon.dart';

/// One completed zone visit, as read back from [AnalyticsService.fileName].
class ZoneVisit {
  const ZoneVisit({
    required this.enteredAt,
    required this.zoneId,
    required this.zoneName,
    required this.duration,
  });

  final DateTime enteredAt;
  final String zoneId;
  final String zoneName;
  final Duration duration;
}

/// Tracks how long the user spends in each zone, to answer "where do
/// people spend most of their time" — kept in its own text file, separate
/// from [ActivityLogger]'s general event log (see that class's doc for
/// why). Listens to [NavigationController.zoneEnteredStream] — already
/// debounced there to fire once per *confirmed* zone change, not every
/// noisy RSSI update — and each time a new zone is entered, closes out a
/// "visit" record for whichever zone was just left and appends it to disk.
class AnalyticsService {
  AnalyticsService({this.fileName = 'analytics.txt'});

  final String fileName;
  StreamSubscription<Beacon>? _sub;
  File? _file;

  Beacon? _currentZone;
  DateTime? _enteredAt;

  final Map<String, Duration> _totalTimePerZone = {};

  /// Cumulative time spent per zone id this session (doesn't include
  /// whatever's already on disk from earlier sessions — that would need
  /// reading [fileName] back in, which nothing currently needs).
  Map<String, Duration> get totalTimePerZone => Map.unmodifiable(_totalTimePerZone);

  /// The zone with the most accumulated time this session, or null if no
  /// zone has been fully visited-and-left yet.
  Beacon? mostVisitedZone(List<Beacon> beacons) {
    if (_totalTimePerZone.isEmpty) return null;
    final topId = _totalTimePerZone.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    for (final beacon in beacons) {
      if (beacon.id == topId) return beacon;
    }
    return null;
  }

  void start(Stream<Beacon> zoneEnteredStream) {
    _sub ??= zoneEnteredStream.listen(_onZoneEntered);
  }

  void _onZoneEntered(Beacon zone) {
    _closeCurrentVisit();
    _currentZone = zone;
    _enteredAt = DateTime.now();
  }

  /// Closes out whatever visit is in progress without waiting for the next
  /// zone change — call when navigation/the app is stopping, so the final
  /// visit isn't silently dropped.
  void flush() => _closeCurrentVisit();

  void _closeCurrentVisit() {
    final zone = _currentZone;
    final enteredAt = _enteredAt;
    if (zone == null || enteredAt == null) return;
    _currentZone = null;
    _enteredAt = null;

    final duration = DateTime.now().difference(enteredAt);
    _totalTimePerZone.update(zone.id, (d) => d + duration, ifAbsent: () => duration);
    _appendVisit(zone, enteredAt, duration);
  }

  Future<File> _ensureFile() async {
    final existing = _file;
    if (existing != null) return existing;
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    _file = file;
    return file;
  }

  /// Tab-separated so the file stays trivial to load into a spreadsheet:
  /// entry time, zone id, zone name, dwell time in seconds.
  Future<void> _appendVisit(Beacon zone, DateTime enteredAt, Duration duration) async {
    final line = '${enteredAt.toIso8601String()}\t${zone.id}\t${zone.name}\t${duration.inSeconds}\n';
    try {
      final file = await _ensureFile();
      await file.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (e) {
      debugPrint('AnalyticsService: failed to write to $fileName: $e');
    }
  }

  void dispose() {
    flush();
    _sub?.cancel();
  }

  /// Every completed visit ever recorded (all sessions, not just this
  /// one), oldest first — parsed back out of the tab-separated file
  /// written by [_appendVisit]. Empty if nothing's been recorded yet, or
  /// the read fails.
  Future<List<ZoneVisit>> readVisits() async {
    try {
      final file = await _ensureFile();
      if (!await file.exists()) return const [];
      final visits = <ZoneVisit>[];
      for (final line in await file.readAsLines()) {
        final parts = line.split('\t');
        if (parts.length != 4) continue;
        final enteredAt = DateTime.tryParse(parts[0]);
        final seconds = int.tryParse(parts[3]);
        if (enteredAt == null || seconds == null) continue;
        visits.add(ZoneVisit(
          enteredAt: enteredAt,
          zoneId: parts[1],
          zoneName: parts[2],
          duration: Duration(seconds: seconds),
        ));
      }
      return visits;
    } catch (e) {
      debugPrint('AnalyticsService: failed to read $fileName: $e');
      return const [];
    }
  }

  /// Sums [visits] into total dwell time per zone id, along with the most
  /// recently-seen zone name for that id (in case a zone got renamed
  /// between visits) — the all-time equivalent of [totalTimePerZone],
  /// which only covers the current session.
  static Map<String, ({String name, Duration total})> aggregateByZone(List<ZoneVisit> visits) {
    final totals = <String, ({String name, Duration total})>{};
    for (final visit in visits) {
      final existing = totals[visit.zoneId];
      totals[visit.zoneId] = (
        name: visit.zoneName,
        total: (existing?.total ?? Duration.zero) + visit.duration,
      );
    }
    return totals;
  }
}
