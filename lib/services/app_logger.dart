import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Log level
// ─────────────────────────────────────────────────────────────────────────────

enum AppLogLevel { debug, info, warning, error }

extension AppLogLevelX on AppLogLevel {
  String get label {
    switch (this) {
      case AppLogLevel.debug:   return 'DEBUG';
      case AppLogLevel.info:    return 'INFO';
      case AppLogLevel.warning: return 'WARN';
      case AppLogLevel.error:   return 'ERROR';
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Log entry model
// ─────────────────────────────────────────────────────────────────────────────

class AppLogEntry {
  final DateTime timestamp;
  final AppLogLevel level;
  final String source;
  final String message;

  const AppLogEntry({
    required this.timestamp,
    required this.level,
    required this.source,
    required this.message,
  });

  // ── Serialization ──────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
    'ts': timestamp.millisecondsSinceEpoch,
    'lv': level.index,
    'src': source,
    'msg': message,
  };

  factory AppLogEntry.fromJson(Map<String, dynamic> json) => AppLogEntry(
    timestamp: DateTime.fromMillisecondsSinceEpoch(
        (json['ts'] as num).toInt()),
    level: AppLogLevel.values[(json['lv'] as num).toInt()
        .clamp(0, AppLogLevel.values.length - 1)],
    source: json['src'] as String? ?? '',
    message: json['msg'] as String? ?? '',
  );

  // ── Display ────────────────────────────────────────────────────────────────

  String get timeStr {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String get formatted => '$timeStr [${level.label}] [$source] $message';
}

// ─────────────────────────────────────────────────────────────────────────────
// AppLogger — singleton, persistent, max _kMaxEntries
// ─────────────────────────────────────────────────────────────────────────────

class AppLogger {
  AppLogger._();

  static const int _kMaxEntries = 500;
  static const String _kPrefKey = 'app_logs_v1';

  static final AppLogger _instance = AppLogger._();
  static AppLogger get instance => _instance;

  final ValueNotifier<List<AppLogEntry>> logsNotifier =
  ValueNotifier<List<AppLogEntry>>([]);

  bool _loaded = false;

  // ── Load / save ────────────────────────────────────────────────────────────

  Future<void> loadFromDisk() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPrefKey);
      if (raw == null) return;
      final list = (jsonDecode(raw) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(AppLogEntry.fromJson)
          .toList();
      logsNotifier.value = list;
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded =
      jsonEncode(logsNotifier.value.map((e) => e.toJson()).toList());
      await prefs.setString(_kPrefKey, encoded);
    } catch (_) {}
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  void log(AppLogLevel level, String source, String message) {
    final entry = AppLogEntry(
      timestamp: DateTime.now(),
      level: level,
      source: source,
      message: message,
    );

    final current = List<AppLogEntry>.from(logsNotifier.value)..add(entry);
    if (current.length > _kMaxEntries) {
      current.removeRange(0, current.length - _kMaxEntries);
    }
    logsNotifier.value = current;
    _persist();
    debugPrint('[${level.label}][$source] $message');
  }

  void debug(String source, String message) =>
      log(AppLogLevel.debug, source, message);

  void info(String source, String message) =>
      log(AppLogLevel.info, source, message);

  void warning(String source, String message) =>
      log(AppLogLevel.warning, source, message);

  void error(String source, String message) =>
      log(AppLogLevel.error, source, message);

  void clear() {
    logsNotifier.value = [];
    _persist();
  }

  String exportText() =>
      logsNotifier.value.map((e) => e.formatted).join('\n');
}

// Convenience top-level accessor.
AppLogger get appLogger => AppLogger.instance;
