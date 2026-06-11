import 'package:flutter/foundation.dart';

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

  /// Returns the cached RTT for [uuid] or null when nothing has been stored.
  /// Distinguishes "no entry" from "entry whose value is null" with [has].
  static int? get(String uuid) => notifier.value[uuid];

  /// True when [uuid] has any cached entry, including a failure or in-flight
  /// marker.
  static bool has(String uuid) => notifier.value.containsKey(uuid);

  /// Publish a new measurement for [uuid]. Triggers a rebuild for every page
  /// observing [notifier].
  static void set(String uuid, int? ms) {
    if (notifier.value[uuid] == ms && notifier.value.containsKey(uuid)) return;
    notifier.value = {...notifier.value, uuid: ms};
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
  }

  /// Drop everything — used on logout / catalog switch.
  static void clear() {
    if (notifier.value.isEmpty) return;
    notifier.value = <String, int?>{};
  }
}
