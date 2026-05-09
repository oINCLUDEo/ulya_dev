import 'dart:convert';
import 'dart:io';

import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/server_node.dart';
import '../services/auth_state.dart';
import '../services/me_service.dart';
import '../services/remnawave_service.dart';
import '../services/selected_server_state.dart';
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

class _ServersPageState extends State<ServersPage> {
  List<ServerNode> _nodes = [];
  bool _loading = true;
  bool _isPublicCatalog = false;

  bool _autoExpanded     = true;
  bool _bypassExpanded   = true;
  bool _unlimitedExpanded = true;
  bool _otherExpanded    = true;

  final Map<String, int> _pings = {};
  bool _pingAllInProgress = false;
  String _lastKnownSubUrl = '';

  @override
  void initState() {
    super.initState();
    selectedServerNotifier.addListener(_onSelectionChanged);
    authStateNotifier.addListener(_onAuthChanged);
    meNotifier.addListener(_onMeChanged);
    _loadNodes();
  }

  @override
  void dispose() {
    selectedServerNotifier.removeListener(_onSelectionChanged);
    authStateNotifier.removeListener(_onAuthChanged);
    meNotifier.removeListener(_onMeChanged);
    super.dispose();
  }

  void _onSelectionChanged() { if (mounted) setState(() {}); }
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
      final uuids = nodes.map((e) => e.uuid).toSet();
      setState(() {
        _loading = false; _isPublicCatalog = true; _nodes = nodes;
        _pings.removeWhere((k, _) => !uuids.contains(k));
      });
      return;
    }
    final nodes = await RemnawaveService.fetchNodes();
    if (!mounted) return;
    final uuids = nodes.map((e) => e.uuid).toSet();
    setState(() {
      _nodes = nodes; _loading = false;
      _pings.removeWhere((k, _) => !uuids.contains(k));
    });
  }

  // ── Grouping ───────────────────────────────────────────────────────────────
  Map<String, List<ServerNode>> _grouped() {
    final map = {
      'auto':      <ServerNode>[],
      'bypass':    <ServerNode>[],
      'unlimited': <ServerNode>[],
      'other':     <ServerNode>[],
    };
    for (final n in _nodes) {
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
        // 1) Available (connected + enabled) nodes first.
        final aOk = a.isAvailable ? 0 : 1;
        final bOk = b.isAvailable ? 0 : 1;
        if (aOk != bOk) return aOk.compareTo(bOk);

        // 2) Known-ping nodes float above not-yet-pinged; lower ping = better.
        final pa = _pings[a.uuid], pb = _pings[b.uuid];
        final aHasPing = pa != null && pa >= 0;
        final bHasPing = pb != null && pb >= 0;
        if (aHasPing && bHasPing) return pa.compareTo(pb);
        if (aHasPing) return -1;
        if (bHasPing) return 1;

        // 3) Alphabetical tiebreaker.
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
  Future<int?> _tcpPingRaw(String host, int port) async {
    final sw = Stopwatch()..start();
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      sw.stop(); s.destroy(); return sw.elapsedMilliseconds;
    } catch (_) { return null; }
  }

  Future<void> _tcpPingNode(ServerNode node) async {
    // Virtual/balanced hosts have no single address to ping.
    if (node.protocol == 'auto') return;
    if (node.link == null) return;
    final host = node.address;
    if (host.isEmpty) return;
    final port = node.serverPort > 0 ? node.serverPort : 443;
    setState(() => _pings[node.uuid] = -2);
    final ms = await _tcpPingRaw(host, port);
    if (mounted) setState(() => _pings[node.uuid] = ms ?? -1);
  }

  Future<void> _tcpPingAll() async {
    if (_nodes.isEmpty || _pingAllInProgress) return;
    setState(() {
      _pingAllInProgress = true;
      for (final n in _nodes) {
        if (n.link != null) _pings[n.uuid] = -2;
      }
    });
    final queue = _nodes.where((n) => n.link != null).toList();
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        await _tcpPingNode(queue.removeLast());
      }
    }
    await Future.wait(List.generate(5, (_) => worker()));
    if (mounted) setState(() => _pingAllInProgress = false);
  }

  // ── Sections ───────────────────────────────────────────────────────────────
  List<Widget> _buildSections() {
    final groups = _grouped();
    final selectedUuid = selectedServerNotifier.value?.uuid;
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
      slivers.add(SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
        sliver: SliverToBoxAdapter(child: _SectionHeader(
          title: title, subtitle: subtitle, color: color, icon: icon,
          expanded: expanded, nodeCount: nodes.length, onTap: onToggle,
        )),
      ));
      slivers.add(SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        sliver: SliverToBoxAdapter(child: _ServerGroup(
          expanded: expanded, nodes: nodes, pings: _pings,
          onPing: _tcpPingNode, color: color,
          selectedUuid: selectedUuid, onSelect: onSelect,
          isPublicCatalog: _isPublicCatalog,
        )),
      ));
    }

    addSection(title: 'Авто-выбор', subtitle: 'Умная балансировка — рекомендуется',
        nodes: groups['auto']!, color: DS.indigoLight,
        icon: Icons.bolt_rounded, expanded: _autoExpanded,
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

    addSection(title: 'Обход ограничений', subtitle: 'Для доступа к заблокированным сайтам',
        nodes: groups['bypass']!, color: DS.violet,
        icon: Icons.shield_rounded, expanded: _bypassExpanded,
        onToggle: () => setState(() => _bypassExpanded = !_bypassExpanded));

    addSection(title: 'Безлимитный трафик', subtitle: 'Без ограничений по объёму',
        nodes: groups['unlimited']!, color: DS.cyan,
        icon: Icons.all_inclusive_rounded, expanded: _unlimitedExpanded,
        onToggle: () => setState(() => _unlimitedExpanded = !_unlimitedExpanded));

    addSection(title: 'Все серверы', subtitle: 'Остальные доступные узлы',
        nodes: groups['other']!, color: DS.emerald,
        icon: Icons.public_rounded, expanded: _otherExpanded,
        onToggle: () => setState(() => _otherExpanded = !_otherExpanded));

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
            if (!_loading && _isPublicCatalog && _nodes.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                sliver: SliverToBoxAdapter(child: VpnInfoBanner(
                  color: DS.amber,
                  text: 'Публичный каталог — только предпросмотр. Для подключения оформите подписку.',
                )),
              ),
            if (_loading)
              const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator(color: DS.violet)))
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
            color: DS.textPrimary, fontSize: 32,
            fontWeight: FontWeight.w800, letterSpacing: -0.5, height: 1)),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(subtitle, style: const TextStyle(color: DS.textSecondary, fontSize: 15)),
        ],
      ])),
      if (!_isPublicCatalog) ...[
        VpnIconBtn(
          loading: _pingAllInProgress,
          icon: Icons.speed_rounded,
          onTap: (_loading || _pingAllInProgress) ? null : _tcpPingAll,
        ),
        const SizedBox(width: 8),
      ],
      VpnIconBtn(loading: _loading, icon: Icons.refresh_rounded,
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
                borderRadius: BorderRadius.circular(11),
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
                child: Icon(Icons.keyboard_arrow_down_rounded, color: color, size: 16),
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

  const _ServerGroup({
    required this.expanded, required this.nodes, required this.pings,
    required this.onPing, required this.color, this.selectedUuid,
    this.onSelect, this.isPublicCatalog = false,
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

class _NodeTile extends StatelessWidget {
  final ServerNode node;
  final int? ping;
  final VoidCallback? onPing;
  final bool isSelected;
  final VoidCallback? onSelect;
  final bool isPublicCatalog;
  final Color accentColor;

  const _NodeTile({
    required this.node, this.ping, this.onPing,
    this.isSelected = false, this.onSelect,
    this.isPublicCatalog = false, required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: isSelected ? accentColor.withValues(alpha: 0.09) : Colors.transparent,
        borderRadius: BorderRadius.circular(DS.radius),
      ),
      child: Material(color: Colors.transparent,
        child: InkWell(
          onTap: onSelect,
          onLongPress: node.link != null ? () => _showConfigDialog(context, node) : null,
          borderRadius: BorderRadius.circular(DS.radius),
          splashColor: accentColor.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(children: [
              // Flag / virtual host icon
              if (node.protocol == 'auto' || node.countryCode.isEmpty)
                Container(
                  width: 36, height: 28,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF1E1B4B), Color(0xFF1A1760)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: DS.indigoLight.withValues(alpha: 0.35)),
                  ),
                  child: const Icon(Icons.bolt_rounded,
                      size: 18, color: DS.indigoLight),
                )
              else
                CountryFlag.fromCountryCode(
                  node.countryCode,
                  theme: ImageTheme(width: 36, height: 28, shape: RoundedRectangle(8)),
                ),
              const SizedBox(width: 12),
              // Info
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(node.name, style: TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 14,
                    color: isSelected ? accentColor : DS.textPrimary),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                if ((node.protocol ?? '').isNotEmpty)
                  Row(children: [
                    _ProtoBadge(protocol: node.protocol!),
                  ]),
              ])),
              const SizedBox(width: 8),
              // Trailing
              if (isSelected)
                Icon(Icons.check_circle_rounded, color: accentColor, size: 20)
              else if (isPublicCatalog)
                Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(color: DS.surface2, borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: DS.border)),
                    child: const Icon(Icons.lock_outline_rounded, size: 14, color: DS.textMuted))
              else
                GestureDetector(
                  onTap: (ping == -2 || node.link == null) ? null : onPing,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: _pingColor(ping).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _pingColor(ping).withValues(alpha: 0.25)),
                    ),
                    child: ping == -2
                        ? SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: _pingColor(ping)))
                        : Text(_pingLabel(ping), style: TextStyle(
                        color: _pingColor(ping), fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
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

  Color _pingColor(int? p) {
    if (p == null) return DS.textMuted;
    if (p == -2) return DS.amber;
    if (p < 0) return DS.textMuted;
    if (p < 100) return DS.emerald;
    if (p < 300) return DS.amber;
    return DS.rose;
  }

  String _pingLabel(int? p) => (p == null || p < 0) ? '—' : '${p}ms';
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
          color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(5)),
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
            child: const Icon(Icons.cloud_off_rounded, size: 32, color: DS.textMuted)),
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
          _OutlinedBtn(label: 'Повторить', icon: Icons.refresh_rounded, onTap: onRetry),
          if (onSettings != null) ...[
            const SizedBox(width: 10),
            _OutlinedBtn(label: 'Настройки', icon: Icons.settings_rounded, onTap: onSettings!),
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
