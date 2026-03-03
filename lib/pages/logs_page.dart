import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_v2ray_plus/flutter_v2ray.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  late final FlutterV2ray _v2ray;
  StreamSubscription<VlessStatus>? _statusSub;

  // Накопленная история строк
  final List<_LogEntry> _logs = [];
  VlessStatus _lastStatus = VlessStatus();

  final ScrollController _scrollCtrl = ScrollController();
  bool _autoScroll = true;

  static const int _maxLines = 1000;

  @override
  void initState() {
    super.initState();
    _v2ray = FlutterV2ray();

    _statusSub = _v2ray.onStatusChanged.listen(_onStatus);
  }

  void _onStatus(VlessStatus s) {
    if (!mounted) return;

    final List<_LogEntry> newEntries = [];
    final prev = _lastStatus;
    final now = DateTime.now();

    // Переход состояния → строка
    if (s.state != prev.state) {
      final stateStr = s.state.toUpperCase();
      _LogLevel level;
      if (stateStr == 'CONNECTED') {
        level = _LogLevel.info;
      } else if (stateStr == 'DISCONNECTED') {
        level = _LogLevel.warn;
      } else {
        level = _LogLevel.debug;
      }
      newEntries.add(_LogEntry(
        time: now,
        level: level,
        message: '[STATE] $stateStr',
      ));
    }

    // Скорости (только если подключено и есть трафик)
    if (s.state.toUpperCase() == 'CONNECTED' &&
        (s.uploadSpeed > 0 || s.downloadSpeed > 0)) {
      newEntries.add(_LogEntry(
        time: now,
        level: _LogLevel.trace,
        message:
        '[TRAFFIC] ↑ ${_fmtSpeed(s.uploadSpeed)}  ↓ ${_fmtSpeed(s.downloadSpeed)}'
            '  total: ↑ ${_fmtBytes(s.upload)} ↓ ${_fmtBytes(s.download)}',
      ));
    }

    _lastStatus = s;

    if (newEntries.isEmpty) return;

    setState(() {
      _logs.addAll(newEntries);
      // Обрезаем чтобы не разрасталось
      if (_logs.length > _maxLines) {
        _logs.removeRange(0, _logs.length - _maxLines);
      }
    });

    if (_autoScroll) _scrollToBottom();
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

  void _copyLogs() {
    final text = _logs.map((e) => e.formatted).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Логи скопированы'),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF2D2D44),
      shape:
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  void _clearLogs() {
    setState(() => _logs.clear());
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ── Форматирование ────────────────────────────────────────────────────────

  String _fmtSpeed(int bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec}B/s';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(1)}KB/s';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)}MB/s';
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }

  Color _levelColor(_LogLevel level) {
    switch (level) {
      case _LogLevel.info:    return const Color(0xFF2ED573);
      case _LogLevel.warn:    return const Color(0xFFFFA502);
      case _LogLevel.error:   return const Color(0xFFE74C3C);
      case _LogLevel.debug:   return const Color(0xFF00D9FF);
      case _LogLevel.trace:   return Colors.white38;
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Text('Логи'),
          const SizedBox(width: 8),
          if (_logs.isNotEmpty)
            Container(
              padding:
              const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF6C5CE7).withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${_logs.length}',
                style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF6C5CE7),
                    fontWeight: FontWeight.bold),
              ),
            ),
        ]),
        backgroundColor: Colors.transparent,
        actions: [
          // Авто-прокрутка toggle
          IconButton(
            icon: Icon(
              _autoScroll
                  ? Icons.vertical_align_bottom
                  : Icons.vertical_align_center,
              color: _autoScroll
                  ? const Color(0xFF00D9FF)
                  : Colors.white38,
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
            tooltip: 'Копировать всё',
            onPressed: _logs.isEmpty ? null : _copyLogs,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Очистить',
            onPressed: _logs.isEmpty ? null : _clearLogs,
          ),
        ],
      ),
      body: _logs.isEmpty
          ? Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal, size: 56, color: Colors.grey[700]),
            const SizedBox(height: 12),
            Text('Логов пока нет',
                style: TextStyle(
                    color: Colors.grey[500], fontSize: 15)),
            const SizedBox(height: 4),
            Text(
              'Подключитесь к VPN чтобы увидеть события',
              style: TextStyle(
                  color: Colors.grey[700], fontSize: 12),
            ),
          ],
        ),
      )
          : NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n is ScrollUpdateNotification &&
              _scrollCtrl.hasClients) {
            final atBottom = _scrollCtrl.position.pixels >=
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
          itemCount: _logs.length,
          itemBuilder: (_, i) {
            final entry = _logs[i];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 1.5),
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.5),
                  children: [
                    TextSpan(
                      text: entry.timeStr,
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                    const TextSpan(text: '  '),
                    TextSpan(
                      text: entry.message,
                      style:
                      TextStyle(color: _levelColor(entry.level)),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),

      // FAB — прокрутить вниз
      floatingActionButton: (!_autoScroll && _logs.isNotEmpty)
          ? FloatingActionButton.small(
        onPressed: () {
          setState(() => _autoScroll = true);
          _scrollToBottom();
        },
        backgroundColor: const Color(0xFF6C5CE7),
        child: const Icon(Icons.keyboard_double_arrow_down),
      )
          : null,
    );
  }
}

// ── Модели ─────────────────────────────────────────────────────────────────────

enum _LogLevel { info, warn, error, debug, trace }

class _LogEntry {
  final DateTime time;
  final _LogLevel level;
  final String message;

  _LogEntry({required this.time, required this.level, required this.message});

  String get timeStr {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String get formatted => '$timeStr  $message';
}