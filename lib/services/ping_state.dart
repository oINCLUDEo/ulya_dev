import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Process-wide cache of measured TCP round-trip times for server nodes,
/// keyed by ServerNode.uuid.
///
/// Both HomePage and ServersPage read+write here so the quality indicator
/// stays in sync no matter which screen triggered the probe. When the user
/// taps "Test all" on the servers list the home connection card picks up
/// the new value for the currently selected node within the same frame —
/// no second measurement needed.
///
/// Semantics of the stored value:
///   * positive int        — successful RTT in milliseconds
///   * negative int (-1)   — last probe failed (host unreachable / timeout)
///   * negative int (-2)   — measurement in flight (transient — set by the
///                            sweep so the UI can show a "scanning" state)
///   * `null` (map value)  — uuid was probed before but value is unknown;
///                            generally treated the same as "missing key"
///   * missing key         — never probed
class PingState {
  PingState._();

  /// Listenable global cache. Pages observe this so they rebuild whenever
  /// anyone publishes a new ping.
  static final ValueNotifier<Map<String, int?>> notifier =
      ValueNotifier<Map<String, int?>>(<String, int?>{});

  static const String _kPrefKey = 'ping_state_v1';
  static Timer? _persistTimer;
  static bool _loaded = false;

  /// Hydrate from SharedPreferences. Call once at app startup (from `main()`
  /// before `runApp`) — subsequent calls are no-ops. Cache survives app
  /// restarts so the user opens the app and sees their last-known signal
  /// bars immediately, no spinner.
  static Future<void> loadFromDisk() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPrefKey);
      if (raw == null) return;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final map = <String, int?>{};
      for (final entry in json.entries) {
        final v = entry.value;
        if (v == null) {
          map[entry.key] = null;
        } else if (v is num) {
          // Reject the transient in-flight marker just in case it sneaked
          // into the snapshot — it doesn't make sense across restarts.
          final i = v.toInt();
          if (i != -2) map[entry.key] = i;
        }
      }
      notifier.value = map;
    } catch (_) {/* corrupt blob — start fresh */}
  }

  /// Debounced write to disk so we don't hammer SharedPreferences during a
  /// burst (the servers sweep can publish a value every few hundred ms).
  static void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 500), _persist);
  }

  static Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Strip in-flight markers (-2) — they're transient.
      final clean = <String, dynamic>{
        for (final e in notifier.value.entries)
          if (e.value != -2) e.key: e.value,
      };
      await prefs.setString(_kPrefKey, jsonEncode(clean));
    } catch (_) {/* swallow — cache is best-effort */}
  }

  /// Returns the cached RTT for [uuid] or null when nothing has been stored.
  /// Distinguishes "no entry" from "entry whose value is null" with [has].
  static int? get(String uuid) => notifier.value[uuid];

  /// True when [uuid] has any cached entry, including a failure or in-flight
  /// marker.
  static bool has(String uuid) => notifier.value.containsKey(uuid);

  /// Publish a new measurement for [uuid]. Triggers a rebuild for every page
  /// observing [notifier] and schedules a debounced write to disk.
  static void set(String uuid, int? ms) {
    if (notifier.value[uuid] == ms && notifier.value.containsKey(uuid)) return;
    notifier.value = {...notifier.value, uuid: ms};
    _schedulePersist();
  }

  /// Mark [uuid] as currently being probed. Read as `-2` by the UI so it can
  /// render a scanning animation in place of stale bars.
  static void markInFlight(String uuid) => set(uuid, -2);

  /// Remove every entry whose uuid is not in [keep]. Useful right after the
  /// node list is refreshed so the cache doesn't accumulate stale uuids.
  static void retain(Set<String> keep) {
    final current = notifier.value;
    final stale = current.keys.where((k) => !keep.contains(k)).toList();
    if (stale.isEmpty) return;
    final next = Map<String, int?>.from(current)
      ..removeWhere((k, _) => !keep.contains(k));
    notifier.value = next;
    _schedulePersist();
  }

  /// Drop everything — used on logout / catalog switch.
  static void clear() {
    if (notifier.value.isEmpty) return;
    notifier.value = <String, int?>{};
    _schedulePersist();
  }
}
