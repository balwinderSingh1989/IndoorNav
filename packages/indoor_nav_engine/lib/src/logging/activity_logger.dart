import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Append-only diagnostic log — general app events (errors, destination
/// changes, zone changes) as timestamped lines in a local text file. Kept
/// deliberately separate from [AnalyticsService]'s file: this is "what did
/// the app do" (debugging), that's "where does the user spend time" (user
/// behavior data) — different audiences, different lifecycles (you might
/// want to clear/rotate the debug log far more often than the analytics
/// history).
class ActivityLogger {
  ActivityLogger({this.fileName = 'app_log.txt'});

  final String fileName;
  File? _file;

  Future<File> _ensureFile() async {
    final existing = _file;
    if (existing != null) return existing;
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    _file = file;
    return file;
  }

  /// Appends a timestamped line. Fire-and-forget and failure-tolerant on
  /// purpose — logging must never throw into (or block) the app code it's
  /// observing.
  Future<void> log(String message) async {
    final line = '${DateTime.now().toIso8601String()}  $message\n';
    debugPrint('[log] $message');
    try {
      final file = await _ensureFile();
      await file.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (e) {
      debugPrint('ActivityLogger: failed to write to $fileName: $e');
    }
  }

  /// Every logged line, oldest first, or an empty list if nothing's been
  /// logged yet (or the read fails).
  Future<List<String>> readLines() async {
    try {
      final file = await _ensureFile();
      if (!await file.exists()) return const [];
      final lines = await file.readAsLines();
      return lines.where((l) => l.trim().isNotEmpty).toList();
    } catch (e) {
      debugPrint('ActivityLogger: failed to read $fileName: $e');
      return const [];
    }
  }
}
