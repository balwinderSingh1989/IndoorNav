import 'package:flutter/material.dart';

import '../../services/activity_logger.dart';
import '../../services/analytics_service.dart';

enum _LogsView { analytics, activity }

/// Shows the two files [ActivityLogger] and [AnalyticsService] write to —
/// dwell-time-per-zone analytics and the general activity log — read back
/// from disk. Reached from a button on [HomeScreen]; both services are
/// passed in rather than re-instantiated, so this reads the exact same
/// files the rest of the app is actively writing to.
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key, required this.activityLogger, required this.analytics});

  final ActivityLogger activityLogger;
  final AnalyticsService analytics;

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  _LogsView _view = _LogsView.analytics;
  Future<List<ZoneVisit>>? _visitsFuture;
  Future<List<String>>? _logLinesFuture;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _visitsFuture = widget.analytics.readVisits();
      _logLinesFuture = widget.activityLogger.readLines();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: const Text('Logs & analytics'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'Refresh', onPressed: _refresh),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: SegmentedButton<_LogsView>(
                segments: const [
                  ButtonSegment(
                    value: _LogsView.analytics,
                    label: Text('Analytics'),
                    icon: Icon(Icons.insights_outlined),
                  ),
                  ButtonSegment(
                    value: _LogsView.activity,
                    label: Text('Activity log'),
                    icon: Icon(Icons.receipt_long_outlined),
                  ),
                ],
                selected: {_view},
                showSelectedIcon: false,
                onSelectionChanged: (selection) => setState(() => _view = selection.first),
              ),
            ),
            Expanded(
              child: _view == _LogsView.analytics ? _AnalyticsView(future: _visitsFuture!) : _ActivityLogView(future: _logLinesFuture!),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnalyticsView extends StatelessWidget {
  const _AnalyticsView({required this.future});

  final Future<List<ZoneVisit>> future;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ZoneVisit>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final visits = snapshot.data ?? const [];
        if (visits.isEmpty) {
          return const _EmptyState(
            icon: Icons.insights_outlined,
            message: 'No zone visits recorded yet — walk between zones to start building analytics.',
          );
        }

        final totals = AnalyticsService.aggregateByZone(visits).entries.toList()
          ..sort((a, b) => b.value.total.compareTo(a.value.total));
        final colorScheme = Theme.of(context).colorScheme;
        final textTheme = Theme.of(context).textTheme;

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Text(
              'Total time spent per zone',
              style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              '${visits.length} recorded visit${visits.length == 1 ? '' : 's'}',
              style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < totals.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: i == 0 ? colorScheme.primaryContainer : colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      if (i == 0)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Icon(Icons.star, size: 18, color: colorScheme.onPrimaryContainer),
                        ),
                      Expanded(
                        child: Text(
                          totals[i].value.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: i == 0 ? colorScheme.onPrimaryContainer : null,
                          ),
                        ),
                      ),
                      Text(
                        _formatDuration(totals[i].value.total),
                        style: textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: i == 0 ? colorScheme.onPrimaryContainer : colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  String _formatDuration(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    return '${d.inSeconds}s';
  }
}

class _ActivityLogView extends StatelessWidget {
  const _ActivityLogView({required this.future});

  final Future<List<String>> future;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final lines = snapshot.data ?? const [];
        if (lines.isEmpty) {
          return const _EmptyState(
            icon: Icons.receipt_long_outlined,
            message: 'No activity logged yet.',
          );
        }

        final colorScheme = Theme.of(context).colorScheme;
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          // Most recent first — that's almost always what you want to see
          // first when checking what just happened.
          itemCount: lines.length,
          itemBuilder: (context, index) {
            final line = lines[lines.length - 1 - index];
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                line,
                style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: colorScheme.onSurface),
              ),
            );
          },
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
