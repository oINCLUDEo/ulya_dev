import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Notification type / severity
// ─────────────────────────────────────────────────────────────────────────────

/// Lifecycle behavior of a notification.
enum InAppNotifType {
  /// Shown once; dismissed permanently.
  oneTime,

  /// Shown until explicitly removed (e.g. by backend).
  persistent,

  /// Short temporary banner (auto-dismiss).
  informational,
}

/// Visual severity / accent colour.
enum InAppNotifSeverity { info, warning, error, success }

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────

class InAppNotification {
  final String id;
  final String title;
  final String body;
  final InAppNotifType type;
  final InAppNotifSeverity severity;

  /// For informational notifications — auto-dismiss after this duration.
  final Duration autoDismiss;

  const InAppNotification({
    required this.id,
    required this.title,
    required this.body,
    this.type = InAppNotifType.informational,
    this.severity = InAppNotifSeverity.info,
    this.autoDismiss = const Duration(seconds: 5),
  });

  factory InAppNotification.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? 'informational';
    final sevStr  = json['severity'] as String? ?? 'info';
    return InAppNotification(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      type: _typeFromStr(typeStr),
      severity: _sevFromStr(sevStr),
      autoDismiss: Duration(
          seconds: (json['auto_dismiss_seconds'] as num?)?.toInt() ?? 5),
    );
  }

  static InAppNotifType _typeFromStr(String s) {
    switch (s) {
      case 'one_time': return InAppNotifType.oneTime;
      case 'persistent': return InAppNotifType.persistent;
      default: return InAppNotifType.informational;
    }
  }

  static InAppNotifSeverity _sevFromStr(String s) {
    switch (s) {
      case 'warning': return InAppNotifSeverity.warning;
      case 'error':   return InAppNotifSeverity.error;
      case 'success': return InAppNotifSeverity.success;
      default:        return InAppNotifSeverity.info;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────

/// In-app notification service.
///
/// Maintains a list of active notifications in [activeNotifications].
/// Consumers (typically the root widget) listen to this notifier and
/// render banners accordingly.
class NotificationService {
  NotificationService._();

  static final NotificationService _instance = NotificationService._();
  static NotificationService get instance => _instance;

  static const String _kDismissedKey = 'dismissed_notifs_v1';

  /// Currently visible notifications.
  final ValueNotifier<List<InAppNotification>> activeNotifications =
  ValueNotifier<List<InAppNotification>>([]);

  Set<String> _dismissed = {};

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kDismissedKey);
    if (raw != null) {
      try {
        _dismissed = Set<String>.from(jsonDecode(raw) as List);
      } catch (_) {}
    }
  }

  // ── Post a notification ────────────────────────────────────────────────────

  /// Post a notification. Respects one-time dismissal state.
  void post(InAppNotification notif) {
    if (notif.type == InAppNotifType.oneTime && _dismissed.contains(notif.id)) {
      return;
    }
    // Avoid duplicates.
    final current = activeNotifications.value;
    if (current.any((n) => n.id == notif.id)) return;
    activeNotifications.value = [...current, notif];
  }

  /// Convenience: post an informational (auto-dismiss) banner.
  void postInfo({required String id, required String title, required String body,
    Duration autoDismiss = const Duration(seconds: 5)}) {
    post(InAppNotification(
      id: id, title: title, body: body,
      type: InAppNotifType.informational,
      severity: InAppNotifSeverity.info,
      autoDismiss: autoDismiss,
    ));
  }

  /// Convenience: post a success banner.
  void postSuccess({required String id, required String title, required String body,
    Duration autoDismiss = const Duration(seconds: 5)}) {
    post(InAppNotification(
      id: id, title: title, body: body,
      type: InAppNotifType.informational,
      severity: InAppNotifSeverity.success,
      autoDismiss: autoDismiss,
    ));
  }

  /// Convenience: post a warning banner.
  void postWarning({required String id, required String title, required String body}) {
    post(InAppNotification(
      id: id, title: title, body: body,
      type: InAppNotifType.persistent,
      severity: InAppNotifSeverity.warning,
    ));
  }

  // ── Dismiss ────────────────────────────────────────────────────────────────

  void dismiss(String id) {
    final notif = activeNotifications.value.firstWhere(
          (n) => n.id == id,
      orElse: () => const InAppNotification(id: '', title: '', body: ''),
    );
    if (notif.type == InAppNotifType.oneTime) {
      _dismissed.add(id);
      _persistDismissed();
    }
    activeNotifications.value =
        activeNotifications.value.where((n) => n.id != id).toList();
  }

  void dismissAll() {
    final oneTimeIds = activeNotifications.value
        .where((n) => n.type == InAppNotifType.oneTime)
        .map((n) => n.id);
    _dismissed.addAll(oneTimeIds);
    _persistDismissed();
    activeNotifications.value = [];
  }

  Future<void> _persistDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kDismissedKey, jsonEncode(_dismissed.toList()));
    } catch (_) {}
  }
}

NotificationService get notificationService => NotificationService.instance;
