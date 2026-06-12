import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/server_node.dart';
import '../services/auth_state.dart';
import '../services/favorites_state.dart';
import '../services/me_service.dart';
import '../services/network_monitor.dart';
import '../services/ping_state.dart';
import '../services/remnawave_service.dart';
import '../services/selected_server_state.dart';
import '../utils/server_icon.dart';
import '../utils/signal_quality.dart';
import '../widgets/skeleton.dart';
import 'auth_bottom_sheet.dart';
import 'home_page.dart' show VpnIconBtn, VpnInfoBanner;
import '../main.dart' show DS;

class ServersPage extends StatefulWidget {
  final VoidCallback onGoToHome;
  final VoidCallback? onGoToSettings;
  final VoidCallback? onGoToPremium;

  const ServersPage({
    required this.onGoToHome,
    required this.onGoToSettings,
    this.onGoToPremium,
    super.key,
  });

  @override
  State<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends State<ServersPage>
    with WidgetsBindingObserver {
  List<ServerNode> _nodes = [];
  bool _loading = true;
  bool _isPublicCatalog = false;

  /// Background re-sweep schedule. Keeps signal bars of NON-selected servers
  /// fresh — without it a node probed once at startup (possibly on a network
  /// where it was unreachable) kept its stale/-1 reading until the user
  /// manually re-probed or re-selected it.
  ///
  /// Burst-then-settle: the first reading right after launch is often noisy
  /// (cold radio, network still settling), so we re-probe a couple of seconds
  /// later, then back off, then keep a slow heartbeat.
  static const List<Duration> _sweepBurst = [
    Duration(seconds: 3),
    Duration(seconds: 10),
    Duration(seconds: 30),
  ];
  static const Duration _sweepPeriod = Duration(seconds: 60);
  Timer? _sweepTimer;
  int _sweepBurstIdx = 0;

  bool _autoExpanded     = true;
  bool _bypassExpanded   = true;
  bool _unlimitedExpanded = true;
  bool _otherExpanded    = true;

  // Pings live in the shared PingState service — see PingState.notifier /
  // PingState.get(uuid). No local cache.
  /// UI flag: a USER-triggered sweep is running (drives the header button
  /// spinner/disable). Background silent sweeps must not touch it.
  bool _pingAllInProgress = false;

  // ── Search ────────────────────────────────────────────────────────────────
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  /// Re-entrancy guard for any sweep, silent or not.
  bool _sweepRunning = false;
  String _lastKnownSubUrl = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    selectedServerNotifier.addListener(_onSelectionChanged);
    authStateNotifier.addListener(_onAuthChanged);
    meNotifier.addListener(_onMeChanged);
    favoritesNotifier.addListener(_onFavoritesChanged);
    PingState.notifier.addListener(_onPingStateChanged);
    NetworkMonitor.changeTick.addListener(_onNetworkChanged);
    _loadNodes();
  }

  /// Default network switched (Wi-Fi ↔ LTE) — every cached reading is for
  /// the OLD network. Re-probe immediately and restart the burst schedule.
  void _onNetworkChanged() {
    if (!mounted) return;
    _tcpPingAll(silent: true);
    _restartSweepSchedule();
  }

  /// (Re)starts the burst-then-settle sweep schedule. Called after the node
  /// list loads (initial sweep just ran) and on app resume (network changed).
  void _restartSweepSchedule() {
    _sweepTimer?.cancel();
    _sweepBurstIdx = 0;
    _scheduleNextSweep();
  }

  void _scheduleNextSweep() {
    if (_sweepBurstIdx < _sweepBurst.length) {
      _sweepTimer = Timer(_sweepBurst[_sweepBurstIdx], () async {
        _sweepBurstIdx++;
        await _tcpPingAll(silent: true);
        if (mounted) _scheduleNextSweep();
      });
    } else {
      _sweepTimer =
          Timer.periodic(_sweepPeriod, (_) => _tcpPingAll(silent: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sweepTimer?.cancel();
    selectedServerNotifier.removeListener(_onSelectionChanged);
    authStateNotifier.removeListener(_onAuthChanged);
    meNotifier.removeListener(_onMeChanged);
    favoritesNotifier.removeListener(_onFavoritesChanged);
    PingState.notifier.removeListener(_onPingStateChanged);
    NetworkMonitor.changeTick.removeListener(_onNetworkChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Nodes matching the current search query (name, category, country).
  List<ServerNode> _visibleNodes() {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _nodes;
    return _nodes.where((n) {
      return n.name.toLowerCase().contains(q) ||
          (n.description ?? '').toLowerCase().contains(q) ||
          countryNameForCode(n.countryCode).toLowerCase().contains(q);
    }).toList();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The network almost certainly changed while we were backgrounded
    // (Wi-Fi ↔ LTE) — old readings are meaningless, re-probe everything and
    // restart the burst so the fresh network gets the quick follow-ups too.
    if (state == AppLifecycleState.resumed) {
      _tcpPingAll(silent: true);
      _restartSweepSchedule();
    }
  }

  void _onSelectionChanged() { if (mounted) setState(() {}); }
  void _onFavoritesChanged() { if (mounted) setState(() {}); }
  void _onPingStateChanged() { if (mounted) setState(() {}); }
  void _onAuthChanged() => _loadNodes();
  void _onMeChanged() {
    final url = meNotifier.value?.subscription?.subscriptionUrl ?? '';
    if (url != _lastKnownSubUrl) { _lastKnownSubUrl = url; _loadNodes(); }
  }

  // ── Data ───────────────────────────────────────────────────────────────────
  Future<void> _loadNodes() async {
    setState(() { _loading = true; _isPublicCatalog = false; });
    final subUrl = await RemnawaveService.getSubscriptionUrl();
    if (subUrl.isEmpty) {
      final nodes = await RemnawaveService.fetchPublicServers();
      if (!mounted) return;
      PingState.retain(nodes.map((e) => e.uuid).toSet());
      setState(() {
        _loading = false; _isPublicCatalog = true; _nodes = nodes;
      });
      // Pre-warm the signal indicator: kick off a background sweep so the
      // bars are populated by the time the user has finished scrolling.
      if (nodes.isNotEmpty) {
        _tcpPingAll();
        _restartSweepSchedule();
      }
      return;
    }
    final nodes = await RemnawaveService.fetchNodes();
    if (!mounted) return;
    PingState.retain(nodes.map((e) => e.uuid).toSet());
    setState(() {
      _nodes = nodes; _loading = false;
    });
    if (nodes.isNotEmpty) {
      _tcpPingAll();
      _restartSweepSchedule();
    }
  }

  // ── Grouping ───────────────────────────────────────────────────────────────
  Map<String, List<ServerNode>> _grouped() {
    final map = {
      'auto':      <ServerNode>[],
      'bypass':    <ServerNode>[],
      'unlimited': <ServerNode>[],
      'other':     <ServerNode>[],
    };
    for (final n in _visibleNodes()) {
      if (n.protocol == 'auto') {
        map['auto']!.add(n);
        continue;
      }
      // Category is determined ONLY by the serverDescription field (description).
      // Remnawave sets this field explicitly, e.g. "Белые списки".
      final hay = (n.description ?? '').toLowerCase();
      if (_isBypass(hay)) {
        map['bypass']!.add(n);
      } else if (_isUnlimited(hay)) {
        map['unlimited']!.add(n);
      } else {
        map['other']!.add(n);
      }
    }
    for (final k in map.keys) {
      map[k]!.sort((a, b) {
        // 1) Available (connected + enabled) nodes first. This depends on
        //    server health flags from the catalog, NOT on the live ping
        //    measurements — those would make the list jump around as
        //    readings come in, which is exactly what the user reported.
        final aOk = a.isAvailable ? 0 : 1;
        final bOk = b.isAvailable ? 0 : 1;
        if (aOk != bOk) return aOk.compareTo(bOk);

        // 2) Alphabetical by display name — stable, predictable order.
        return a.name.compareTo(b.name);
      });
    }
    return map;
  }

  // ── Category keywords ─────────────────────────────────────────────────────
  static bool _isBypass(String hay) =>
      hay.contains('белые') ||   // "Белые списки"
      hay.contains('обход') ||   // "Обход LTE", "Обход ограничений"
      hay.contains('bypass') ||
      hay.contains('лте') ||     // LTE / мобильные обходные
      hay.contains('lte') ||
      // YT·TG·Игры = сервер с белыми списками (Россия)
      (hay.contains('yt') && hay.contains('tg'));

  static bool _isUnlimited(String hay) =>
      hay.contains('безлимит') ||
      hay.contains('unlimited');

  // ── Ping ───────────────────────────────────────────────────────────────────
  /// One-shot TCP RTT (no warm-up). Used internally only.
  Future<int?> _tcpPingRaw(String host, int port) async {
    final sw = Stopwatch()..start();
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      sw.stop(); s.destroy(); return sw.elapsedMilliseconds;
    } catch (_) { return null; }
  }

  /// Warm-up connect + min of two follow-up measurements. See
  /// _accurateTcpRtt in home_page.dart for the rationale — same approach.
  Future<int?> _tcpPingAccurate(String host, int port) async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      s.destroy();
    } catch (_) {
      return null;
    }
    final m1 = await _tcpPingRaw(host, port);
    if (m1 == null) return null;
    final m2 = await _tcpPingRaw(host, port);
    if (m2 == null) return m1;
    return m1 < m2 ? m1 : m2;
  }

  Future<void> _tcpPingNode(ServerNode node) async {
    // Virtual/balanced hosts have no single address to ping.
    if (node.protocol == 'auto') return;
    if (node.link == null) return;
    final host = node.address;
    if (host.isEmpty) return;
    final port = node.serverPort > 0 ? node.serverPort : 443;
    // Silent refresh: when we already have a valid cached reading for this
    // node, don't flip the badge into the "scanning" state — replace it in
    // place once the new value arrives. Only the first-ever probe (or one
    // that follows a previous failure) shows the scan animation.
    final cached = PingState.get(node.uuid);
    final hasValid = cached != null && cached >= 0;
    if (!hasValid) PingState.markInFlight(node.uuid);
    final ms = await _tcpPingAccurate(host, port);
    if (mounted) PingState.set(node.uuid, ms ?? -1);
  }

  /// Probes every node. [silent] skips the mass "scanning" markers AND the
  /// header-button progress state, so a background refresh replaces readings
  /// in place without any UI churn; the user-triggered sweep keeps both.
  Future<void> _tcpPingAll({bool silent = false}) async {
    if (_nodes.isEmpty || _sweepRunning) return;
    _sweepRunning = true;
    if (!silent) {
      setState(() => _pingAllInProgress = true);
      for (final n in _nodes) {
        if (n.link != null) PingState.markInFlight(n.uuid);
      }
    }
    final queue = _nodes.where((n) => n.link != null).toList();
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        await _tcpPingNode(queue.removeLast());
      }
    }
    await Future.wait(List.generate(5, (_) => worker()));
    _sweepRunning = false;
    if (!silent && mounted) setState(() => _pingAllInProgress = false);
  }

  // ── Sections ───────────────────────────────────────────────────────────────
  List<Widget> _buildSections() {
    final groups = _grouped();
    final selectedUuid = selectedServerNotifier.value?.uuid;
    final favorites = favoritesNotifier.value;
    final slivers = <Widget>[];
    final searching = _query.trim().isNotEmpty;

    // Lowest successful ping among real connectable servers — gets the
    // "Лучший" badge so the choice is obvious at a glance.
    String? bestUuid;
    var bestPing = 1 << 30;
    for (final n in _nodes) {
      if (n.protocol == 'auto' || n.link == null || n.isDisabled) continue;
      final p = PingState.get(n.uuid);
      if (p != null && p > 0 && p < bestPing) {
        bestPing = p;
        bestUuid = n.uuid;
      }
    }

    Future<void> onSelect(ServerNode node) async {
      if (_isPublicCatalog) {
        authStateNotifier.value.isLoggedIn
            ? widget.onGoToPremium?.call()
            : await showAuthBottomSheet(context);
        return;
      }
      if (node.isDisabled || node.link == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Сервер временно недоступен'),
          ),
        );
        return;
      }
      HapticFeedback.selectionClick();
      selectedServerNotifier.value = node;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('selected_node_uuid', node.uuid);
      widget.onGoToHome();
    }

    void addSection({
      required String title, required String subtitle,
      required List<ServerNode> nodes, required Color color,
      required IconData icon, required bool expanded, required VoidCallback onToggle,
    }) {
      if (nodes.isEmpty) return;
      // While searching every matching section is force-expanded — collapsed
      // matches would look like an empty result.
      final isExpanded = expanded || searching;
      slivers.add(SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
        sliver: SliverToBoxAdapter(child: _SectionHeader(
          title: title, subtitle: subtitle, color: color, icon: icon,
          expanded: isExpanded, nodeCount: nodes.length, onTap: onToggle,
        )),
      ));
      slivers.add(SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        sliver: SliverToBoxAdapter(child: _ServerGroup(
          expanded: isExpanded, nodes: nodes,
          pings: PingState.notifier.value,
          onPing: _tcpPingNode, color: color,
          selectedUuid: selectedUuid, onSelect: onSelect,
          isPublicCatalog: _isPublicCatalog,
          favorites: favorites,
          bestUuid: bestUuid,
        )),
      ));
    }

    // Избранное — всегда первым, если не пустое
    final favoriteNodes =
        _visibleNodes().where((n) => favorites.contains(n.uuid)).toList();
    if (favoriteNodes.isNotEmpty && !_isPublicCatalog) {
      slivers.add(SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
        sliver: SliverToBoxAdapter(child: _SectionHeader(
          title: 'Избранное', subtitle: 'Закреплённые серверы',
          color: DS.amber, icon: PhosphorIconsFill.star,
          expanded: true, nodeCount: favoriteNodes.length,
          onTap: () {},
        )),
      ));
      slivers.add(SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        sliver: SliverToBoxAdapter(child: _ServerGroup(
          expanded: true, nodes: favoriteNodes,
          pings: PingState.notifier.value,
          onPing: _tcpPingNode, color: DS.amber,
          selectedUuid: selectedUuid, onSelect: onSelect,
          isPublicCatalog: false,
          favorites: favorites,
          bestUuid: bestUuid,
        )),
      ));
    }

    addSection(title: 'Авто-выбор', subtitle: 'Умная балансировка — рекомендуется',
        nodes: groups['auto']!, color: DS.indigoLight,
        icon: PhosphorIconsFill.lightning, expanded: _autoExpanded,
        onToggle: () => setState(() => _autoExpanded = !_autoExpanded));

    // Visual break: auto-select (smart) ↔ manual server list
    final hasManual = ['bypass', 'unlimited', 'other']
        .any((k) => groups[k]!.isNotEmpty);
    if (groups['auto']!.isNotEmpty && hasManual) {
      slivers.add(const SliverPadding(
        padding: EdgeInsets.fromLTRB(16, 18, 16, 0),
        sliver: SliverToBoxAdapter(child: _ManualDivider()),
      ));
    }

    addSection(title: 'Белые списки', subtitle: 'YouTube, Telegram и базовые сервисы — даже при жёстких блокировках',
        nodes: groups['bypass']!, color: DS.violet,
        icon: PhosphorIconsFill.listChecks, expanded: _bypassExpanded,
        onToggle: () => setState(() => _bypassExpanded = !_bypassExpanded));

    addSection(title: 'Безлимитный трафик', subtitle: 'Без ограничений по объёму',
        nodes: groups['unlimited']!, color: DS.cyan,
        icon: Icons.all_inclusive_rounded, expanded: _unlimitedExpanded,
        onToggle: () => setState(() => _unlimitedExpanded = !_unlimitedExpanded));

    addSection(title: 'Все серверы', subtitle: 'Остальные доступные узлы',
        nodes: groups['other']!, color: DS.emerald,
        icon: PhosphorIconsFill.globeHemisphereWest, expanded: _otherExpanded,
        onToggle: () => setState(() => _otherExpanded = !_otherExpanded));

    if (slivers.isEmpty && searching) {
      slivers.add(SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 60, 16, 0),
        sliver: SliverToBoxAdapter(
          child: Column(children: [
            const Icon(PhosphorIconsRegular.magnifyingGlass,
                size: 40, color: DS.textMuted),
            const SizedBox(height: 12),
            Text('Ничего не найдено по «${_query.trim()}»',
                textAlign: TextAlign.center,
                style: const TextStyle(color: DS.textSecondary, fontSize: 14)),
          ]),
        ),
      ));
    }

    return slivers;
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: DS.surface0,
      body: RefreshIndicator(
        color: DS.violet,
        backgroundColor: DS.surface2,
        onRefresh: _loadNodes,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, top + 20, 20, 0),
                child: _buildHeader(),
              ),
            ),
            if (!_loading && _nodes.length > 5)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _query = v),
                    style: const TextStyle(color: DS.textPrimary, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Поиск: сервер, страна, категория',
                      isDense: true,
                      prefixIcon: const Icon(PhosphorIconsRegular.magnifyingGlass,
                          size: 18, color: DS.textMuted),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(PhosphorIconsBold.x,
                                  size: 16, color: DS.textMuted),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _query = '');
                              },
                            ),
                    ),
                  ),
                ),
              ),
            if (!_loading && _isPublicCatalog && _nodes.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                sliver: SliverToBoxAdapter(child: VpnInfoBanner(
                  color: DS.amber,
                  text: 'Публичный каталог — только предпросмотр. Для подключения оформите подписку.',
                )),
              ),
            if (_loading)
              // Skeleton of the future layout (sections + rows) — reads as
              // "almost there" instead of a void with a spinner.
              const SliverPadding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: SkeletonTheme(
                    child: Column(children: [
                      ServerSectionSkeleton(rows: 1),
                      ServerSectionSkeleton(rows: 3),
                      ServerSectionSkeleton(rows: 2),
                    ]),
                  ),
                ),
              )
            else if (_nodes.isEmpty)
              SliverFillRemaining(child: _EmptyState(
                onRetry: _loadNodes,
                onSettings: widget.onGoToSettings,
                isPublic: _isPublicCatalog,
              ))
            else
              ..._buildSections(),
            const SliverPadding(padding: EdgeInsets.only(bottom: 110)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final count = _nodes.length;
    final subtitle = !_loading && count > 0
        ? _isPublicCatalog
        ? '$count ${_pluralServers(count)} (каталог)'
        : '$count ${_pluralServers(count)} в подписке'
        : null;

    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Серверы', style: TextStyle(
            color: DS.textPrimary, fontSize: 28,
            fontWeight: FontWeight.w700, letterSpacing: -0.5, height: 1)),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(subtitle, style: const TextStyle(color: DS.textSecondary, fontSize: 15)),
        ],
      ])),
      if (!_isPublicCatalog) ...[
        VpnIconBtn(
          loading: _pingAllInProgress,
          icon: PhosphorIconsBold.gauge,
          // Rotating a speedometer looks like a glitch — show a spinner
          // overlay instead of spinning the glyph while the sweep runs.
          spinWhenLoading: false,
          onTap: (_loading || _pingAllInProgress) ? null : _tcpPingAll,
        ),
        const SizedBox(width: 8),
      ],
      VpnIconBtn(loading: _loading, icon: PhosphorIconsBold.arrowsClockwise,
          onTap: _loading ? null : _loadNodes),
    ]);
  }

  String _pluralServers(int n) {
    final m10 = n % 10, m100 = n % 100;
    if (m100 >= 11 && m100 <= 19) return 'серверов';
    if (m10 == 1) return 'сервер';
    if (m10 >= 2 && m10 <= 4) return 'сервера';
    return 'серверов';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section header
// ─────────────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final bool expanded;
  final int nodeCount;
  final VoidCallback onTap;

  const _SectionHeader({
    required this.title, required this.subtitle, required this.icon,
    required this.color, required this.expanded,
    required this.nodeCount, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Container(width: 42, height: 42,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(DS.radiusSm),
              ),
              child: Icon(icon, color: color, size: 20)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(
                color: DS.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
            Text(subtitle, style: const TextStyle(color: DS.textSecondary, fontSize: 12)),
          ])),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withValues(alpha: 0.22)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('$nodeCount', style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 240),
                child: Icon(PhosphorIconsBold.caretDown, color: color, size: 16),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Animated server group card
// ─────────────────────────────────────────────────────────────────────────────

class _ServerGroup extends StatefulWidget {
  final bool expanded;
  final List<ServerNode> nodes;
  final Map<String, int?> pings;
  final void Function(ServerNode) onPing;
  final Color color;
  final String? selectedUuid;
  final Future<void> Function(ServerNode)? onSelect;
  final bool isPublicCatalog;
  final Set<String> favorites;
  /// Uuid of the server with the lowest live ping — gets a "Лучший" badge.
  final String? bestUuid;

  const _ServerGroup({
    required this.expanded, required this.nodes, required this.pings,
    required this.onPing, required this.color, this.selectedUuid,
    this.onSelect, this.isPublicCatalog = false,
    this.favorites = const {},
    this.bestUuid,
  });

  @override
  State<_ServerGroup> createState() => _ServerGroupState();
}

class _ServerGroupState extends State<_ServerGroup>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 280));
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
    if (widget.expanded) _ctrl.value = 1;
  }

  @override
  void didUpdateWidget(covariant _ServerGroup old) {
    super.didUpdateWidget(old);
    widget.expanded ? _ctrl.forward() : _ctrl.reverse();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: SizeTransition(
        sizeFactor: _anim,
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Container(
            decoration: BoxDecoration(
              color: DS.surface1,
              borderRadius: BorderRadius.circular(DS.radius),
              border: Border.all(color: DS.border),
            ),
            child: Column(
              children: List.generate(widget.nodes.length, (i) {
                final node = widget.nodes[i];
                return Column(children: [
                  _NodeTile(
                    node: node,
                    ping: widget.pings[node.uuid],
                    onPing: () => widget.onPing(node),
                    isSelected: node.uuid == widget.selectedUuid,
                    onSelect: widget.onSelect != null
                        ? () => widget.onSelect!(node) : null,
                    isPublicCatalog: widget.isPublicCatalog,
                    accentColor: widget.color,
                    isFavorite: widget.favorites.contains(node.uuid),
                    isBest: node.uuid == widget.bestUuid,
                  ),
                  if (i != widget.nodes.length - 1)
                    const Divider(height: 1, indent: 16, endIndent: 16,
                        color: DS.border),
                ]);
              }),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Node tile
// ─────────────────────────────────────────────────────────────────────────────

class _NodeTile extends StatefulWidget {
  final ServerNode node;
  final int? ping;
  final VoidCallback? onPing;
  final bool isSelected;
  final VoidCallback? onSelect;
  final bool isPublicCatalog;
  final Color accentColor;
  final bool isFavorite;
  final bool isBest;

  const _NodeTile({
    required this.node, this.ping, this.onPing,
    this.isSelected = false, this.onSelect,
    this.isPublicCatalog = false, required this.accentColor,
    this.isFavorite = false,
    this.isBest = false,
  });

  @override
  State<_NodeTile> createState() => _NodeTileState();
}

class _NodeTileState extends State<_NodeTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _swipeCtrl;
  late final Animation<double> _revealAnim;
  static const _revealWidth = 72.0;
  static const _threshold = 0.40;
  bool _hapticFired = false;

  @override
  void initState() {
    super.initState();
    _swipeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 320));
    _revealAnim = CurvedAnimation(parent: _swipeCtrl, curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    _swipeCtrl.dispose();
    super.dispose();
  }

  void _handleDragUpdate(DragUpdateDetails d) {
    if (widget.isPublicCatalog) return;
    final drag = -d.primaryDelta!; // positive = swiping left
    if (drag > 0) {
      // Rubber-band: fast start, exponential resistance near max
      final remaining = 1.0 - _swipeCtrl.value;
      final factor = math.pow(remaining, 0.6).toDouble();
      _swipeCtrl.value =
          (_swipeCtrl.value + drag / _revealWidth * factor * 2.2).clamp(0.0, 1.0);
    } else {
      // Release back: linear, slightly faster
      _swipeCtrl.value =
          (_swipeCtrl.value + drag / (_revealWidth * 0.7)).clamp(0.0, 1.0);
    }
    // Haptic tick when crossing threshold
    if (!_hapticFired && _swipeCtrl.value >= _threshold) {
      _hapticFired = true;
      HapticFeedback.selectionClick();
    } else if (_swipeCtrl.value < _threshold) {
      _hapticFired = false;
    }
  }

  void _handleDragEnd(DragEndDetails d) {
    if (widget.isPublicCatalog) return;
    if (_swipeCtrl.value >= _threshold) {
      HapticFeedback.mediumImpact();
      toggleFavorite(widget.node.uuid);
    }
    _swipeCtrl.animateBack(0.0);
    _hapticFired = false;
  }

  void _closeStar() => _swipeCtrl.animateBack(0.0);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: _handleDragUpdate,
      onHorizontalDragEnd: _handleDragEnd,
      child: AnimatedBuilder(
        animation: _revealAnim,
        builder: (_, child) {
          final offset = _revealAnim.value * _revealWidth;
          return Stack(clipBehavior: Clip.hardEdge, children: [
            // Star reveal — right side, exposed when tile slides left
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: Opacity(
                  opacity: _revealAnim.value,
                  child: Container(
                    width: _revealWidth,
                    alignment: Alignment.center,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: Icon(
                        widget.isFavorite
                            ? PhosphorIconsFill.star
                            : PhosphorIconsRegular.star,
                        key: ValueKey(widget.isFavorite),
                        color: DS.amber,
                        size: 26,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Tile itself, shifted left to expose star
            Transform.translate(
              offset: Offset(-offset, 0),
              child: child,
            ),
          ]);
        },
        child: _buildTileContent(),
      ),
    );
  }

  Widget _buildTileContent() {
    final node = widget.node;
    final isSelected = widget.isSelected;
    final accentColor = widget.accentColor;
    final ping = widget.ping;
    // Last probe failed (and we're not mid-scan) — mute the row so dead
    // servers are obvious at a glance, not just from the badge.
    final isOffline = ping != null && ping < 0 && ping != -2;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: isSelected ? accentColor.withValues(alpha: 0.09) : Colors.transparent,
        borderRadius: BorderRadius.circular(DS.radius),
      ),
      child: Material(color: Colors.transparent,
        child: InkWell(
          onTap: () {
            if (_swipeCtrl.value > 0) {
              _closeStar();
            } else {
              widget.onSelect?.call();
            }
          },
          onLongPress: node.link != null ? () => _showConfigDialog(context, node) : null,
          borderRadius: BorderRadius.circular(DS.radius),
          splashColor: accentColor.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(children: [
              // Flag / virtual host icon — falls back to bolt for invalid
              // country codes (handled by buildServerIcon).
              buildServerIcon(node, width: 36, height: 28, radius: 6),
              const SizedBox(width: 12),
              // Info
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  if (widget.isFavorite) ...[
                    const Icon(PhosphorIconsFill.star, size: 11, color: DS.amber),
                    const SizedBox(width: 4),
                  ],
                  Flexible(child: Text(node.name, style: TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14,
                      color: isSelected
                          ? accentColor
                          : isOffline ? DS.textMuted : DS.textPrimary),
                      overflow: TextOverflow.ellipsis)),
                  if (widget.isBest && !isOffline) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: DS.gold.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                            color: DS.gold.withValues(alpha: 0.40)),
                      ),
                      child: const Text('ЛУЧШИЙ',
                          style: TextStyle(
                            color: DS.gold,
                            fontSize: 8.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                          )),
                    ),
                  ],
                ]),
                const SizedBox(height: 3),
                if ((node.protocol ?? '').isNotEmpty)
                  Row(children: [
                    _ProtoBadge(protocol: node.protocol!),
                  ]),
              ])),
              const SizedBox(width: 8),
              // Trailing
              if (isSelected)
                Icon(PhosphorIconsFill.checkCircle, color: accentColor, size: 20)
              else if (widget.isPublicCatalog)
                Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(color: DS.surface2, borderRadius: BorderRadius.circular(DS.radiusXs),
                        border: Border.all(color: DS.border)),
                    child: const Icon(PhosphorIconsRegular.lock, size: 14, color: DS.textMuted))
              else if (node.protocol == 'auto')
                // Auto-routed host: no single address to probe, so just paint
                // a healthy indigo bars badge — visually consistent with
                // every other server, plus a tooltip clarifying it's "Авто".
                const _AutoQualityBars()
              else
                _QualityBars(
                  ping: ping,
                  isAvailable: node.isAvailable,
                  noLink: node.link == null,
                  // Probe is triggered by the widget itself — single-tap
                  // re-pings when there's no value yet (no number to peek
                  // at); long-press always re-pings. Tapping a known value
                  // toggles the badge into "ms text" mode for a few seconds.
                  onProbe: () {
                    if (node.link == null) return;
                    HapticFeedback.selectionClick();
                    widget.onPing?.call();
                  },
                ),
            ]),
          ),
        ),
      ),
    );
  }

  /// Long-press debug view: shows the raw Xray JSON for this server.
  void _showConfigDialog(BuildContext context, ServerNode node) {
    final raw = node.link ?? '(no link)';

    // Pretty-print if JSON, otherwise show as-is.
    String pretty;
    try {
      final parsed = jsonDecode(raw);
      pretty = const JsonEncoder.withIndent('  ').convert(parsed);
    } catch (_) {
      pretty = raw;
    }

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DS.surface1,
        title: Text(node.name,
            style: const TextStyle(fontSize: 14, color: DS.textPrimary)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              pretty,
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 10, color: DS.textSecondary),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: pretty));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Конфиг скопирован')),
              );
            },
            child: const Text('Копировать'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

}

// ─── Auto-routed node indicator ──────────────────────────────────────────────
// Pinged-bar lookalike showing four full indigo bars — same dimensions as
// _QualityBars so auto and manual rows line up perfectly in the trailing slot.
// No interaction (auto hosts have no single address to probe), just a tooltip
// hinting it's a balanced/auto host.
class _AutoQualityBars extends StatelessWidget {
  const _AutoQualityBars();

  @override
  Widget build(BuildContext context) {
    const heights = [5.0, 7.5, 10.0, 12.5];
    return Tooltip(
      message: 'Авто-балансировка',
      preferBelow: false,
      child: Container(
        width: 34, height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: DS.indigoLight.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(DS.radiusXs),
          border: Border.all(color: DS.indigoLight.withValues(alpha: 0.28)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < 4; i++) ...[
              Container(
                width: 2.5,
                height: heights[i],
                decoration: BoxDecoration(
                  color: DS.indigoLight,
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
              if (i < 3) const SizedBox(width: 2),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _QualityBars — 4-bar Wi-Fi style indicator for the servers list.
//
// Quality buckets:
//   noLink / !isAvailable → 0 bars, rose (server unreachable)
//   ping == -2            → animated amber scan (measuring)
//   ping ∈ (-∞, 0)        → 1 rose bar (probe failed)
//   ping == null          → all bars dim violet (never measured; tap to probe)
//   ping <  80            → 4 emerald
//   ping < 180            → 3 emerald
//   ping < 320            → 2 amber
//   ping ≥ 320            → 1 rose
//
// Interaction:
//   tap        → run / re-run probe.
//   long-press → snackbar with the raw "Пинг: N мс" (parent supplies handler).
//   tooltip    → same number on hover/long-touch.
// ─────────────────────────────────────────────────────────────────────────────
class _QualityBars extends StatefulWidget {
  final int? ping;
  final bool isAvailable;
  final bool noLink;
  /// Run a fresh TCP probe for this server. Triggered by long-press, and by
  /// tap when the badge has no value to peek at yet.
  final VoidCallback onProbe;

  const _QualityBars({
    required this.ping,
    required this.isAvailable,
    required this.noLink,
    required this.onProbe,
  });

  @override
  State<_QualityBars> createState() => _QualityBarsState();
}

class _QualityBarsState extends State<_QualityBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scanCtrl;
  // Tap-to-peek: while true, the badge renders the raw "120 мс" text instead
  // of the bars. Auto-reverts after [_peekDuration].
  bool _showMs = false;
  Timer? _peekTimer;
  static const Duration _peekDuration = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _scanCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.ping == -2) _scanCtrl.repeat();
  }

  @override
  void didUpdateWidget(covariant _QualityBars old) {
    super.didUpdateWidget(old);
    final wasScanning = old.ping == -2;
    final isScanning = widget.ping == -2;
    if (isScanning && !wasScanning) {
      _scanCtrl.repeat();
      // A new probe is in flight — bail out of "show ms" mode so the user
      // can see the scan animation, otherwise it'd stay on the stale value.
      if (_showMs) {
        _peekTimer?.cancel();
        _showMs = false;
      }
    } else if (!isScanning && wasScanning) {
      _scanCtrl..stop()..reset();
    }
  }

  @override
  void dispose() {
    _scanCtrl.dispose();
    _peekTimer?.cancel();
    super.dispose();
  }

  /// Single-tap handler. If there's a real ping number to show → flip the
  /// badge into "ms text" mode for [_peekDuration]. Otherwise — re-probe.
  void _onTap() {
    final p = widget.ping;
    final hasValue = p != null && p >= 0;
    if (!hasValue) {
      widget.onProbe();
      return;
    }
    HapticFeedback.selectionClick();
    _peekTimer?.cancel();
    setState(() => _showMs = !_showMs);
    if (_showMs) {
      _peekTimer = Timer(_peekDuration, () {
        if (mounted) setState(() => _showMs = false);
      });
    }
  }

  // Quality bucketing is shared with the home connection card via
  // lib/utils/signal_quality.dart — both screens MUST resolve the same
  // (bars, colour) for the same ping value.
  ({int active, Color color, String tooltip, bool loading, bool offline})
      _state() {
    final p = widget.ping;
    if (widget.noLink || !widget.isAvailable) {
      return (active: 0, color: DS.rose, tooltip: 'Сервер недоступен',
          loading: false, offline: true);
    }
    if (p == -2) {
      return (active: 0, color: DS.amber, tooltip: 'Проверяем…',
          loading: true, offline: false);
    }
    if (p == null) {
      return (active: 0, color: DS.violet, tooltip: 'Нажмите, чтобы проверить',
          loading: false, offline: false);
    }
    if (p < 0) {
      // Probe failed — render an explicit "offline" badge instead of a
      // single red bar, which read as "weak signal" rather than "dead".
      return (active: 0, color: DS.rose,
          tooltip: 'Нет связи. Нажмите, чтобы повторить.',
          loading: false, offline: true);
    }
    final q = signalQualityFromPing(p);
    return (active: q.activeBars, color: q.color, tooltip: '$p мс',
        loading: false, offline: false);
  }

  static const _heights = [5.0, 7.5, 10.0, 12.5];

  Widget _scanBars() {
    return AnimatedBuilder(
      animation: _scanCtrl,
      builder: (_, child) {
        final t = _scanCtrl.value * 4;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < 4; i++) ...[
              Container(
                width: 2.5,
                height: _heights[i],
                decoration: BoxDecoration(
                  color: DS.amber.withValues(alpha: _scanAlpha(i, t)),
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
              if (i < 3) const SizedBox(width: 2),
            ],
          ],
        );
      },
    );
  }

  double _scanAlpha(int i, double t) {
    final d = (i - t).abs();
    final wrapped = math.min(d, 4 - d);
    final n = (1 - wrapped / 2).clamp(0.0, 1.0);
    return 0.18 + 0.67 * n;
  }

  Widget _staticBars(int active, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < 4; i++) ...[
          AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            width: 2.5,
            height: _heights[i],
            decoration: BoxDecoration(
              color: i < active ? color : DS.textMuted.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
          if (i < 3) const SizedBox(width: 2),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _state();
    final p = widget.ping;
    final showMsText = _showMs && p != null && p >= 0 && !s.loading;
    return Tooltip(
      message: showMsText ? 'Удерживайте, чтобы обновить' : s.tooltip,
      preferBelow: false,
      child: GestureDetector(
        onTap: _onTap,
        onLongPress: widget.onProbe,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          // Slightly wider when the number is on screen so "120 мс" doesn't
          // get cut. Bar mode keeps its compact 34px footprint.
          width: showMsText ? 48 : 34,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: s.color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(DS.radiusXs),
            border: Border.all(color: s.color.withValues(alpha: 0.28)),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(scale: anim, child: child),
            ),
            child: showMsText
                ? Text('$p мс',
                    key: const ValueKey('ms'),
                    style: TextStyle(
                      color: s.color,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ))
                : s.offline
                    ? const Icon(PhosphorIconsBold.wifiSlash,
                        key: ValueKey('offline'), size: 13, color: DS.rose)
                    : KeyedSubtree(
                        key: const ValueKey('bars'),
                        child: s.loading
                            ? _scanBars()
                            : _staticBars(s.active, s.color),
                      ),
          ),
        ),
      ),
    );
  }
}

class _ProtoBadge extends StatelessWidget {
  final String protocol;
  const _ProtoBadge({required this.protocol});

  Color _color() {
    switch (protocol.toLowerCase()) {
      case 'auto':    return DS.indigoLight;
      case 'vmess':   return DS.violet;
      case 'vless':   return DS.cyan;
      case 'trojan':  return DS.amber;
      case 'ss':      return DS.emerald;
      case 'hysteria2': case 'hy2': case 'hysteria': return DS.rose;
      case 'tuic':    return DS.orchid;
      default:        return DS.textMuted;
    }
  }

  String get _label {
    if (protocol.toLowerCase() == 'auto') return 'AUTO';
    return protocol.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final c = _color();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
          color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(DS.radiusXs)),
      child: Text(_label, style: TextStyle(
          color: c, fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Divider between auto-select block and manual server sections
// ─────────────────────────────────────────────────────────────────────────────

class _ManualDivider extends StatelessWidget {
  const _ManualDivider();

  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: Container(height: 1, color: DS.border)),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Text(
        'РУЧНОЙ ВЫБОР',
        style: TextStyle(
          color: DS.textMuted.withValues(alpha: 0.70),
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.4,
        ),
      ),
    ),
    Expanded(child: Container(height: 1, color: DS.border)),
  ]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Empty state
// ─────────────────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onRetry;
  final VoidCallback? onSettings;
  final bool isPublic;
  const _EmptyState({required this.onRetry, this.onSettings, required this.isPublic});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 72, height: 72,
            decoration: BoxDecoration(
                color: DS.surface2, shape: BoxShape.circle,
                border: Border.all(color: DS.border)),
            child: const Icon(PhosphorIconsRegular.cloudSlash, size: 32, color: DS.textMuted)),
        const SizedBox(height: 18),
        Text(isPublic ? 'Каталог недоступен' : 'Серверы не получены',
            style: const TextStyle(color: DS.textPrimary, fontSize: 17, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(isPublic
            ? 'Не удалось загрузить серверы. Проверьте соединение.'
            : 'Проверьте URL подписки или интернет-соединение.',
            style: const TextStyle(color: DS.textSecondary, fontSize: 13),
            textAlign: TextAlign.center),
        const SizedBox(height: 22),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _OutlinedBtn(label: 'Повторить', icon: PhosphorIconsBold.arrowsClockwise, onTap: onRetry),
          if (onSettings != null) ...[
            const SizedBox(width: 10),
            _OutlinedBtn(label: 'Настройки', icon: PhosphorIconsBold.gearSix, onTap: onSettings!),
          ],
        ]),
      ]),
    ),
  );
}

class _OutlinedBtn extends StatelessWidget {
  final String label; final IconData icon; final VoidCallback onTap;
  const _OutlinedBtn({required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: DS.surface2,
        borderRadius: BorderRadius.circular(DS.radiusSm),
        border: Border.all(color: DS.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: DS.violet),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(
            color: DS.violet, fontSize: 13, fontWeight: FontWeight.w600)),
      ]),
    ),
  );
}
