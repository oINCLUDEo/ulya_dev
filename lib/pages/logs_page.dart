import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_v2ray_plus/flutter_v2ray.dart';

import '../services/app_logger.dart';
import '../main.dart' show DS;

// ─────────────────────────────────────────────────────────────────────────────
// LogsPage — shows entries from AppLogger with level-filter + V2Ray forwarding
// ─────────────────────────────────────────────────────────────────────────────

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  late final FlutterV2ray _v2ray;
  StreamSubscription<VlessStatus>? _statusSub;
  VlessStatus _lastStatus = VlessStatus();

  AppLogLevel? _filterLevel; // null = show all
  bool _autoScroll = true;
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _v2ray = FlutterV2ray();
    _statusSub = _v2ray.onStatusChanged.listen(_onV2RayStatus);
    appLogger.logsNotifier.addListener(_onLogsChanged);
  }

  // ── V2Ray status → AppLogger ───────────────────────────────────────────────

  void _onV2RayStatus(VlessStatus s) {
    final prev = _lastStatus;
    _lastStatus = s;

    if (s.state != prev.state) {
      final stateStr = s.state.toUpperCase();
      final level = stateStr == 'CONNECTED'
          ? AppLogLevel.info
          : stateStr == 'DISCONNECTED'
          ? AppLogLevel.warning
          : AppLogLevel.debug;
      appLogger.log(level, 'V2Ray', '[STATE] $stateStr');
    }

    if (s.state.toUpperCase() == 'CONNECTED' &&
        (s.uploadSpeed > 0 || s.downloadSpeed > 0)) {
      appLogger.log(
        AppLogLevel.debug,
        'V2Ray',
        '[TRAFFIC] ↑ ${_fmtSpeed(s.uploadSpeed)}  ↓ ${_fmtSpeed(s.downloadSpeed)}'
            '  total: ↑ ${_fmtBytes(s.upload)} ↓ ${_fmtBytes(s.download)}',
      );
    }
  }

  void _onLogsChanged() {
    if (mounted) setState(() {});
    if (_autoScroll) _scrollToBottom();
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  List<AppLogEntry> get _filtered {
    final all = appLogger.logsNotifier.value;
    if (_filterLevel == null) return all;
    return all.where((e) => e.level == _filterLevel).toList();
  }

  void _copyLogs() {
    final text = _filtered.map((e) => e.formatted).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Логи скопированы'),
      behavior: SnackBarBehavior.floating,
      backgroundColor: DS.surface2,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DS.radiusXs)),
    ));
  }

  void _clearLogs() {
    appLogger.clear();
    if (mounted) setState(() {});
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    appLogger.logsNotifier.removeListener(_onLogsChanged);
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ── Colors ─────────────────────────────────────────────────────────────────

  Color _levelColor(AppLogLevel level) {
    switch (level) {
      case AppLogLevel.info:    return DS.emerald;
      case AppLogLevel.warning: return DS.amber;
      case AppLogLevel.error:   return DS.rose;
      case AppLogLevel.debug:   return DS.violet.withValues(alpha: 0.8);
    }
  }

  String _fmtSpeed(int bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec}B/s';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(1)}KB/s';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)}MB/s';
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final entries = _filtered;
    return Scaffold(
      backgroundColor: DS.surface0,
      appBar: AppBar(
        backgroundColor: DS.surface1,
        surfaceTintColor: Colors.transparent,
        title: Row(children: [
          const Text('Логи',
              style: TextStyle(
                  color: DS.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          if (entries.isNotEmpty)
            Container(
              padding:
              const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: DS.violet.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${entries.length}',
                style: const TextStyle(
                    fontSize: 11,
                    color: DS.violet,
                    fontWeight: FontWeight.bold),
              ),
            ),
        ]),
        actions: [
          IconButton(
            icon: Icon(
              _autoScroll
                  ? Icons.vertical_align_bottom
                  : Icons.vertical_align_center,
              color: _autoScroll ? DS.violet : DS.textMuted,
            ),
            tooltip: _autoScroll
                ? 'Авто-прокрутка вкл.'
                : 'Авто-прокрутка выкл.',
            onPressed: () {
              setState(() => _autoScroll = !_autoScroll);
              if (_autoScroll) _scrollToBottom();
            },
          ),
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: 'Копировать',
            onPressed: entries.isEmpty ? null : _copyLogs,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Очистить',
            onPressed: entries.isEmpty ? null : _clearLogs,
          ),
        ],
      ),
      body: Column(children: [
        // ── Level filter chips ─────────────────────────────────────────────
        Container(
          color: DS.surface1,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Row(children: [
            _FilterChip(
                label: 'Все',
                selected: _filterLevel == null,
                onTap: () => setState(() => _filterLevel = null)),
            const SizedBox(width: 6),
            _FilterChip(
                label: 'INFO',
                color: DS.emerald,
                selected: _filterLevel == AppLogLevel.info,
                onTap: () => setState(() => _filterLevel =
                _filterLevel == AppLogLevel.info
                    ? null
                    : AppLogLevel.info)),
            const SizedBox(width: 6),
            _FilterChip(
                label: 'WARN',
                color: DS.amber,
                selected: _filterLevel == AppLogLevel.warning,
                onTap: () => setState(() => _filterLevel =
                _filterLevel == AppLogLevel.warning
                    ? null
                    : AppLogLevel.warning)),
            const SizedBox(width: 6),
            _FilterChip(
                label: 'ERROR',
                color: DS.rose,
                selected: _filterLevel == AppLogLevel.error,
                onTap: () => setState(() => _filterLevel =
                _filterLevel == AppLogLevel.error
                    ? null
                    : AppLogLevel.error)),
            const SizedBox(width: 6),
            _FilterChip(
                label: 'DEBUG',
                color: DS.violet,
                selected: _filterLevel == AppLogLevel.debug,
                onTap: () => setState(() => _filterLevel =
                _filterLevel == AppLogLevel.debug
                    ? null
                    : AppLogLevel.debug)),
          ]),
        ),

        // ── Log list ───────────────────────────────────────────────────────
        Expanded(
          child: entries.isEmpty
              ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.terminal,
                    size: 56, color: DS.textMuted),
                const SizedBox(height: 12),
                Text('Логов пока нет',
                    style: TextStyle(
                        color: DS.textSecondary, fontSize: 15)),
                const SizedBox(height: 4),
                Text(
                  'Запустите VPN чтобы увидеть события',
                  style: TextStyle(
                      color: DS.textMuted, fontSize: 12),
                ),
              ],
            ),
          )
              : NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n is ScrollUpdateNotification &&
                  _scrollCtrl.hasClients) {
                final atBottom =
                    _scrollCtrl.position.pixels >=
                        _scrollCtrl.position.maxScrollExtent - 80;
                if (_autoScroll != atBottom) {
                  setState(() => _autoScroll = atBottom);
                }
              }
              return false;
            },
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 8),
              itemCount: entries.length,
              itemBuilder: (_, i) {
                final entry = entries[i];
                return Padding(
                  padding:
                  const EdgeInsets.symmetric(vertical: 1.5),
                  child: RichText(
                    text: TextSpan(
                      style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          height: 1.5),
                      children: [
                        TextSpan(
                          text: entry.timeStr,
                          style:
                          const TextStyle(color: DS.textMuted),
                        ),
                        const TextSpan(text: '  '),
                        TextSpan(
                          text:
                          '[${entry.level.label}]',
                          style: TextStyle(
                              color:
                              _levelColor(entry.level)),
                        ),
                        TextSpan(
                          text: ' [${entry.source}] ',
                          style: const TextStyle(
                              color: DS.textSecondary),
                        ),
                        TextSpan(
                          text: entry.message,
                          style: TextStyle(
                              color: _levelColor(entry.level)
                                  .withValues(alpha: 0.9)),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ]),

      // FAB — scroll to bottom
      floatingActionButton: (!_autoScroll && entries.isNotEmpty)
          ? FloatingActionButton.small(
        onPressed: () {
          setState(() => _autoScroll = true);
          _scrollToBottom();
        },
        backgroundColor: DS.violet,
        child: const Icon(Icons.keyboard_double_arrow_down),
      )
          : null,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small filter chip
// ─────────────────────────────────────────────────────────────────────────────

class _FilterChip extends StatelessWidget {
  final String label;
  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? DS.textSecondary;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? c.withValues(alpha: 0.15) : DS.surface2,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? c.withValues(alpha: 0.5) : DS.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? c : DS.textMuted,
            fontSize: 11,
            fontWeight:
            selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
