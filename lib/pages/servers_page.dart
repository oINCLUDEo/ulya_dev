import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/me_response.dart';
import '../models/server_node.dart';
import '../services/auth_state.dart';
import '../services/favorites_state.dart';
import '../services/launch_action_service.dart';
import '../services/me_service.dart';
import '../services/network_monitor.dart';
import '../services/ping_state.dart';
import '../services/remnawave_service.dart';
import '../services/selected_server_state.dart';
import '../services/subscription_api_service.dart';
import '../utils/server_icon.dart';
import '../widgets/quality_bars.dart';
import '../widgets/skeleton.dart';
import 'auth_bottom_sheet.dart';
import 'home_page.dart' show VpnIconBtn, VpnInfoBanner;
import 'support_page.dart';
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
    super.dispose();
  }

  List<ServerNode> _visibleNodes() => _nodes;

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
    if (url != _lastKnownSubUrl) {
      _lastKnownSubUrl = url;
      _loadNodes();
    } else if (mounted) {
      // Status may have changed (active ↔ expired/limited/disabled) without the
      // URL changing — rebuild so the status screen appears/disappears.
      setState(() {});
    }
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
  /// Thin wrapper — the actual measurement lives in [PingState.probeNode] so
  /// every screen that probes a server (this page, the Home server picker)
  /// runs the exact same algorithm and writes to the same cache.
  Future<void> _tcpPingNode(ServerNode node) => PingState.probeNode(node);

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
      // HomePage owns the actual VPN connection and stays alive in the
      // bottom-nav IndexedStack, so it can pick this up immediately — the
      // same pending-action bridge the QS tile uses for its "toggle" action.
      LaunchActionService.pending.value = 'connect_selected';
      widget.onGoToHome();
    }

    void addSection({
      required String title, required String subtitle,
      required List<ServerNode> nodes, required Color color,
      required IconData icon, required bool expanded, required VoidCallback onToggle,
    }) {
      if (nodes.isEmpty) return;
      final isExpanded = expanded;
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

    return slivers;
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    // Blocked subscription states (expired / limited / disabled) come back from
    // Remnawave as "note" entries that would otherwise render as fake server
    // tiles. Detect the state from the structured /me status and show a proper
    // status screen instead.
    final sub = meNotifier.value?.subscription;
    final loggedIn = authStateNotifier.value.isLoggedIn;
    // Remnawave's admin notes are only ever used to *detect* a condition we
    // don't have a structured signal for (device limit, empty host list) —
    // never to source the copy or the call-to-action. Every full-screen block
    // is drawn from our own design system so it stays native (no external
    // links) and on-brand regardless of what an admin types into the panel.
    final notes = (!_isPublicCatalog && loggedIn)
        ? RemnawaveService.lastNotes
        : const <String>[];
    final blocked = (!_isPublicCatalog && loggedIn)
        ? _SubBlock.resolve(notes: notes, status: sub?.status)
        : null;
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
            // A full-screen block only takes over when there's nothing else to
            // show — e.g. during reserve-squad grace the subscription can
            // carry a "device limit reached" note AND a real, connectable
            // server at the same time. Hiding the server behind the block
            // screen would defeat the entire point of grace access.
            else if (blocked != null && _nodes.isEmpty)
              SliverFillRemaining(child: _SubStatusView(
                block: blocked,
                sub: sub,
                onPremium: widget.onGoToPremium,
                onRefresh: _loadNodes,
              ))
            else if (_nodes.isEmpty)
              SliverFillRemaining(child: _EmptyState(
                onRetry: _loadNodes,
                onSettings: widget.onGoToSettings,
                isPublic: _isPublicCatalog,
              ))
            else ...[
              if (notes.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  sliver: SliverToBoxAdapter(child: VpnInfoBanner(
                    color: DS.amber,
                    text: notes.join('\n'),
                  )),
                ),
              ..._buildSections(),
            ],
            const SliverPadding(padding: EdgeInsets.only(bottom: 110)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final count = _nodes.length;
    final sub = meNotifier.value?.subscription;
    final loggedIn = authStateNotifier.value.isLoggedIn;
    final blocked = !_isPublicCatalog &&
        loggedIn &&
        ((RemnawaveService.lastNotes.isNotEmpty && count == 0) ||
            (sub != null && _SubBlock.fromStatus(sub.status) != null));
    final subtitle = (!_loading && count > 0 && !blocked)
        ? _isPublicCatalog
        ? '$count ${_pluralServers(count)} (каталог)'
        : '$count ${_pluralServers(count)} в подписке'
        : null;

    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Сервера', style: TextStyle(
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

  const _ServerGroup({
    required this.expanded, required this.nodes, required this.pings,
    required this.onPing, required this.color, this.selectedUuid,
    this.onSelect, this.isPublicCatalog = false,
    this.favorites = const {},
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

  const _NodeTile({
    required this.node, this.ping, this.onPing,
    this.isSelected = false, this.onSelect,
    this.isPublicCatalog = false, required this.accentColor,
    this.isFavorite = false,
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
                ]),
                const SizedBox(height: 3),
                if ((node.protocol ?? '').isNotEmpty)
                  Row(children: [
                    _ProtoBadge(protocol: node.protocol!),
                    if (purposeBadgesForDescription(node.description).isNotEmpty) ...[
                      const SizedBox(width: 6),
                      buildPurposeBadges(node.description),
                    ],
                  ]),
              ])),
              const SizedBox(width: 8),
              // Trailing
              if (isSelected)
                // Selected-but-idle only gets a checkmark; a live tunnel to
                // this exact node (tracked globally via vpnConnectedNotifier,
                // set by HomePage — the only place that owns the VPN
                // connection) gets the stronger "Подключено" badge instead.
                ValueListenableBuilder<bool>(
                  valueListenable: vpnConnectedNotifier,
                  builder: (_, connected, _) => connected
                      ? _ConnectedBadge(color: accentColor)
                      : Icon(PhosphorIconsFill.checkCircle,
                          color: accentColor, size: 20),
                )
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
                const AutoQualityBars()
              else
                QualityBars(
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

// ─── "Connected" badge — live tunnel indicator for the selected row ─────────
class _ConnectedBadge extends StatelessWidget {
  final Color color;
  const _ConnectedBadge({required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: DS.emerald.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: DS.emerald.withValues(alpha: 0.4)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 6, height: 6,
        decoration: const BoxDecoration(color: DS.emerald, shape: BoxShape.circle),
      ),
      const SizedBox(width: 5),
      const Text('Подключено',
          style: TextStyle(
              color: DS.emerald, fontSize: 10, fontWeight: FontWeight.w700)),
    ]),
  );
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
// Subscription status block (expired / limited / disabled)
// ─────────────────────────────────────────────────────────────────────────────

enum _SubBlock {
  hwidLimit,
  expired,
  limited,
  disabled,
  hostsUnavailable;

  static _SubBlock? fromStatus(String s) {
    switch (s.toLowerCase()) {
      case 'expired':
        return _SubBlock.expired;
      case 'limited':
        return _SubBlock.limited;
      case 'disabled':
      case 'blocked':
      case 'banned':
        return _SubBlock.disabled;
      default:
        return null;
    }
  }

  /// Resolves which full-screen block (if any) to show.
  ///
  /// Admin notes are used only to *detect* conditions with no dedicated
  /// subscription status (device limit reached, an empty host list) — the
  /// structured [status] always wins when it maps to a known block, and the
  /// note text itself never reaches the UI. Copy and the call-to-action are
  /// entirely ours, so they stay native (no external links) and on-brand no
  /// matter what an admin types into the Remnawave panel.
  static _SubBlock? resolve({required List<String> notes, required String? status}) {
    final hasHwidNote = notes.any((n) {
      final s = n.toLowerCase();
      return s.contains('устройств') || s.contains('device') || s.contains('hwid');
    });
    if (hasHwidNote) return _SubBlock.hwidLimit;
    final fromStatus = status != null ? _SubBlock.fromStatus(status) : null;
    if (fromStatus != null) return fromStatus;
    if (notes.isNotEmpty) return _SubBlock.hostsUnavailable;
    return null;
  }
}

/// Full-screen status shown on the Servers page when there's nothing
/// connectable to display — subscription expired/limited/disabled, the
/// device (HWID) limit was hit, or Remnawave has no hosts to offer right
/// now. One consistent template (icon, copy, single native CTA) for every
/// case, so the screen always feels like part of the same product instead
/// of echoing whatever an admin typed into the panel.
class _SubStatusView extends StatelessWidget {
  final _SubBlock block;
  final MeSubscription? sub;
  final VoidCallback? onPremium;
  final Future<void> Function() onRefresh;

  const _SubStatusView({
    required this.block,
    required this.sub,
    required this.onRefresh,
    this.onPremium,
  });

  void _openSupport(BuildContext context) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => const SupportPage()));
  }

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    final Color color;
    final String title;
    final List<String> lines;
    final String ctaLabel;
    final VoidCallback? onCta;

    switch (block) {
      case _SubBlock.hwidLimit:
        icon = PhosphorIconsFill.devices;
        color = DS.violet;
        title = 'Достигнут лимит устройств';
        lines = const [
          'На аккаунте уже максимум подключённых устройств.',
          'Отключите одно из старых — и это сразу освободит место.',
        ];
        ctaLabel = 'Управлять устройствами';
        onCta = () async {
          await showDeviceManager(context);
          await onRefresh();
        };
      case _SubBlock.expired:
        icon = PhosphorIconsFill.hourglassMedium;
        color = DS.amber;
        title = 'Подписка истекла';
        lines = [
          'Срок действия закончился ${sub?.formattedExpiry ?? ''}.',
          'Продлите подписку, чтобы снова подключаться к серверам.',
        ];
        ctaLabel = 'Продлить подписку';
        onCta = onPremium;
      case _SubBlock.limited:
        final total = (sub?.trafficLimitGb ?? 0) > 0 ? '${sub!.trafficLimitGb} ГБ' : '∞';
        icon = PhosphorIconsFill.gauge;
        color = DS.violet;
        title = 'Лимит трафика исчерпан';
        lines = [
          'Использовано ${(sub?.trafficUsedGb ?? 0).toStringAsFixed(1)} из $total.',
          'Смените тариф или продлите — и доступ вернётся.',
        ];
        ctaLabel = 'Сменить тариф';
        onCta = onPremium;
      case _SubBlock.disabled:
        icon = PhosphorIconsFill.prohibit;
        color = DS.rose;
        title = 'Подписка приостановлена';
        lines = const [
          'Доступ временно ограничен.',
          'Напишите в поддержку — мы поможем разобраться.',
        ];
        ctaLabel = 'Написать в поддержку';
        onCta = () => _openSupport(context);
      case _SubBlock.hostsUnavailable:
        icon = PhosphorIconsFill.cloudSlash;
        color = DS.cyan;
        title = 'Серверы временно недоступны';
        lines = const [
          'Мы уже разбираемся и скоро всё заработает.',
          'Загляните чуть позже — или напишите нам, если срочно.',
        ];
        ctaLabel = 'Написать в поддержку';
        onCta = () => _openSupport(context);
    }

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.12),
                border: Border.all(color: color.withValues(alpha: 0.3), width: 1.5),
                boxShadow: [
                  BoxShadow(color: color.withValues(alpha: 0.18), blurRadius: 36),
                ],
              ),
              child: Icon(icon, color: color, size: 44),
            ),
            const SizedBox(height: 26),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: DS.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 12),
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  l,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: DS.textSecondary,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: GestureDetector(
                onTap: onCta,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(DS.radiusSm),
                    boxShadow: [
                      BoxShadow(color: color.withValues(alpha: 0.3), blurRadius: 18, offset: const Offset(0, 6)),
                    ],
                  ),
                  child: Text(
                    ctaLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: onRefresh,
              child: const Text('Обновить',
                  style: TextStyle(color: DS.textMuted, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// In-app device manager (resolve HWID limit without leaving the app)
// ─────────────────────────────────────────────────────────────────────────────

Future<void> showDeviceManager(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _DeviceManagerSheet(),
  );
}

class _DeviceManagerSheet extends StatefulWidget {
  const _DeviceManagerSheet();

  @override
  State<_DeviceManagerSheet> createState() => _DeviceManagerSheetState();
}

class _DeviceManagerSheetState extends State<_DeviceManagerSheet> {
  DevicesResult? _data;
  bool _loading = true;
  bool _failed = false;
  String? _currentHwid;
  final Set<String> _deleting = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _failed = false; });
    final hwid = await RemnawaveService.getOrCreateHwid();
    final r = await SubscriptionApiService.listDevices();
    if (!mounted) return;
    setState(() {
      _currentHwid = hwid;
      _data = r;
      _loading = false;
      _failed = r == null;
    });
  }

  Future<void> _delete(String hwid) async {
    setState(() => _deleting.add(hwid));
    HapticFeedback.selectionClick();
    final ok = await SubscriptionApiService.deleteDevice(hwid: hwid);
    if (!mounted) return;
    if (ok) {
      await _load();
      if (mounted) HapticFeedback.mediumImpact();
    }
    if (mounted) setState(() => _deleting.remove(hwid));
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final bottom = MediaQuery.of(context).padding.bottom;
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
      decoration: const BoxDecoration(
        color: DS.surface2,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        border: Border(top: BorderSide(color: DS.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(width: 40, height: 4, decoration: BoxDecoration(
              color: DS.border, borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(children: [
              const Icon(PhosphorIconsFill.devices, color: DS.violet, size: 22),
              const SizedBox(width: 10),
              const Expanded(child: Text('Мои устройства',
                  style: TextStyle(color: DS.textPrimary, fontSize: 18, fontWeight: FontWeight.w800))),
              if (data != null)
                Text('${data.count}/${data.deviceLimit}',
                    style: const TextStyle(color: DS.textSecondary, fontSize: 14, fontWeight: FontWeight.w600)),
            ]),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Удалите лишние устройства, чтобы снова подключаться.',
                  style: TextStyle(color: DS.textSecondary, fontSize: 13, height: 1.4)),
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(40),
              child: CircularProgressIndicator(color: DS.violet),
            )
          else if (_failed || data == null)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Column(children: [
                const Text('Не удалось загрузить устройства',
                    style: TextStyle(color: DS.textSecondary, fontSize: 14)),
                const SizedBox(height: 14),
                TextButton(onPressed: _load, child: const Text('Повторить')),
              ]),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + bottom),
                itemCount: data.devices.length,
                separatorBuilder: (_, i) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _DeviceRow(
                  device: data.devices[i],
                  isCurrent: data.devices[i].hwid == _currentHwid,
                  deleting: _deleting.contains(data.devices[i].hwid),
                  onDelete: () => _delete(data.devices[i].hwid),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final DeviceItem device;
  final bool isCurrent;
  final bool deleting;
  final VoidCallback onDelete;
  const _DeviceRow({
    required this.device,
    required this.isCurrent,
    required this.deleting,
    required this.onDelete,
  });

  IconData get _platformIcon {
    final p = device.platformName.toLowerCase();
    if (p.contains('iphone') || p.contains('ipad') || p.contains('ios') || p.contains('mac')) {
      return PhosphorIconsFill.appleLogo;
    }
    if (p.contains('android')) return PhosphorIconsFill.androidLogo;
    if (p.contains('windows')) return PhosphorIconsFill.windowsLogo;
    if (p.contains('linux')) return PhosphorIconsFill.linuxLogo;
    return PhosphorIconsFill.deviceMobile;
  }

  @override
  Widget build(BuildContext context) {
    final title = [device.clientName, device.deviceModel ?? device.platformName]
        .where((s) => s.isNotEmpty)
        .join(' · ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radiusSm),
        border: Border.all(color: isCurrent ? DS.violet.withValues(alpha: 0.5) : DS.border),
      ),
      child: Row(children: [
        Icon(_platformIcon, color: DS.textSecondary, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title.isEmpty ? 'Устройство' : title,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: DS.textPrimary, fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(isCurrent ? 'Это устройство' : device.platformName,
                  style: TextStyle(
                      color: isCurrent ? DS.violet : DS.textMuted, fontSize: 12)),
            ],
          ),
        ),
        if (isCurrent)
          const Padding(
            padding: EdgeInsets.only(left: 8),
            child: Icon(PhosphorIconsFill.checkCircle, color: DS.violet, size: 20),
          )
        else if (deleting)
          const SizedBox(width: 22, height: 22,
              child: CircularProgressIndicator(strokeWidth: 2, color: DS.rose))
        else
          IconButton(
            onPressed: onDelete,
            icon: const Icon(PhosphorIconsBold.trash, color: DS.rose, size: 18),
          ),
      ]),
    );
  }
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
