import 'dart:io';

import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter_v2ray_plus/flutter_v2ray.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/server_node.dart';
import '../services/auth_state.dart';
import '../services/me_service.dart';
import '../services/remnawave_service.dart';
import '../services/selected_server_state.dart';
import '../theme/app_colors.dart';
import '../widgets/purple_header.dart';
import 'auth_bottom_sheet.dart';

class ServersPage extends StatefulWidget {
  final VoidCallback onGoToHome;
  final VoidCallback? onGoToSettings;

  const ServersPage({
    required this.onGoToHome,
    required this.onGoToSettings,
    super.key,
  });

  @override
  State<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends State<ServersPage> {
  List<ServerNode> _nodes = [];
  bool _loading = true;

  /// true when servers are loaded from the public catalog (no subscription URL).
  bool _isPublicCatalog = false;

  bool _bypassExpanded = true;
  bool _unlimitedExpanded = true;
  bool _otherExpanded = true;

  /// ping ms per node uuid:
  /// null = не тестировался
  /// -2 = идёт
  /// -1 = ошибка
  /// >=0 = мс
  final Map<String, int> _pings = {};
  bool _pingAllInProgress = false;

  /// Tracks the last subscription URL seen from [meNotifier] to detect changes.
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

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  /// Reload nodes when the user logs in so that subscription servers replace
  /// the public catalog automatically.
  void _onAuthChanged() {
    _loadNodes();
  }

  /// Reload servers when the subscription URL changes (e.g. after a successful
  /// subscription purchase that updated [meNotifier]).
  void _onMeChanged() {
    final newUrl = meNotifier.value?.subscription?.subscriptionUrl ?? '';
    if (newUrl != _lastKnownSubUrl) {
      _lastKnownSubUrl = newUrl;
      _loadNodes();
    }
  }

  // ──────────────────────────────────────────────────────────────
  // LOAD NODES
  // ──────────────────────────────────────────────────────────────

  Future<void> _loadNodes() async {
    setState(() {
      _loading = true;
      _isPublicCatalog = false;
    });

    final subUrl = await RemnawaveService.getSubscriptionUrl();
    debugPrint('ServersPage: subUrl - ${subUrl}');
    if (subUrl.isEmpty) {
      // No personal subscription — load the public server catalog.
      final nodes = await RemnawaveService.fetchPublicServers();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _isPublicCatalog = true;
        _nodes = nodes;
        final uuids = nodes.map((e) => e.uuid).toSet();
        _pings.removeWhere((k, _) => !uuids.contains(k));
      });
      return;
    }

    final nodes = await RemnawaveService.fetchNodes();

    if (!mounted) return;

    setState(() {
      _nodes = nodes;
      _loading = false;
      _isPublicCatalog = false;

      final uuids = nodes.map((e) => e.uuid).toSet();
      _pings.removeWhere((k, _) => !uuids.contains(k));
    });
  }

  // ──────────────────────────────────────────────────────────────
  // GROUPING
  // ──────────────────────────────────────────────────────────────

  Map<String, List<ServerNode>> _groupedNodes() {
    final map = {
      'bypass': <ServerNode>[],
      'unlimited': <ServerNode>[],
      'other': <ServerNode>[],
    };

    for (final node in _nodes) {
      final desc = (node.description ?? '').toLowerCase();

      if (desc.contains('белые')) {
        map['bypass']!.add(node);
      } else if (desc.contains('безлимит')) {
        map['unlimited']!.add(node);
      } else {
        map['other']!.add(node);
      }
    }

    // сортировка: сначала по ping (если есть), потом по имени
    for (final key in map.keys) {
      map[key]!.sort((a, b) {
        final pa = _pings[a.uuid];
        final pb = _pings[b.uuid];

        if (pa != null && pa >= 0 && pb != null && pb >= 0) {
          return pa.compareTo(pb);
        }
        return a.name.compareTo(b.name);
      });
    }

    return map;
  }

  // ──────────────────────────────────────────────────────────────
  // SECTIONS
  // ──────────────────────────────────────────────────────────────

  List<Widget> _buildSections() {
    final groups = _groupedNodes();
    final List<Widget> slivers = [];
    final selectedUuid = selectedServerNotifier.value?.uuid;

    Future<void> onSelect(ServerNode node) async {
      if (_isPublicCatalog) {
        // Tapping a catalog server prompts authentication.
        // The _onAuthChanged listener handles the reload after successful login.
        await showAuthBottomSheet(context);
        return;
      }
      selectedServerNotifier.value = node;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('selected_node_uuid', node.uuid);
      widget.onGoToHome();
    }

    void addSection({
      required String title,
      required String subtitle,
      required List<ServerNode> nodes,
      required Color color,
      required IconData icon,
      required bool expanded,
      required VoidCallback onToggle,
    }) {
      if (nodes.isEmpty) return;

      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          sliver: SliverToBoxAdapter(
            child: _SectionHeader(
              title: title,
              subtitle: subtitle,
              color: color,
              icon: icon,
              expanded: expanded,
              nodeCount: nodes.length,
              onTap: onToggle,
            ),
          ),
        ),
      );

      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          sliver: SliverToBoxAdapter(
            child: _AnimatedServerGroup(
              expanded: expanded,
              nodes: nodes,
              pings: _pings,
              onPing: _tcpPingNode,
              color: color,
              selectedUuid: selectedUuid,
              onSelect: onSelect,
              isPublicCatalog: _isPublicCatalog,
            ),
          ),
        ),
      );
    }

    addSection(
      title: 'Обход ограничений',
      subtitle: 'Для доступа везде',
      nodes: groups['bypass']!,
      color: const Color(0xFF6C5CE7),
      // Более яркий синий
      icon: Icons.shield_outlined,
      expanded: _bypassExpanded,
      onToggle: () => setState(() => _bypassExpanded = !_bypassExpanded),
    );

    addSection(
      title: 'Безлимитный трафик',
      subtitle: 'Без ограничений по объёму',
      nodes: groups['unlimited']!,
      color: const Color(0xFF00D9FF),
      // Яркий голубой
      icon: Icons.all_inclusive,
      expanded: _unlimitedExpanded,
      onToggle: () => setState(() => _unlimitedExpanded = !_unlimitedExpanded),
    );

    addSection(
      title: 'Все серверы',
      subtitle: 'Остальные доступные узлы',
      nodes: groups['other']!,
      color: const Color(0xFF2ED573),
      // Светлый зелёный
      icon: Icons.public,
      expanded: _otherExpanded,
      onToggle: () => setState(() => _otherExpanded = !_otherExpanded),
    );

    return slivers;
  }

  // ──────────────────────────────────────────────────────────────
  // PING SINGLE
  // ──────────────────────────────────────────────────────────────

  Future<void> _pingNode(ServerNode node) async {
    if (node.link == null) return;

    setState(() => _pings[node.uuid] = -2);

    try {
      // flutter_v2ray_plus: getServerDelay принимает полный JSON конфиг
      final parser = FlutterV2ray.parseFromURL(node.link!);
      final config = parser.getFullConfiguration();
      final v2ray = FlutterV2ray();
      final ms = await v2ray.getServerDelay(config: config);

      if (mounted) setState(() => _pings[node.uuid] = ms);
    } catch (_) {
      if (mounted) setState(() => _pings[node.uuid] = -1);
    }
  }

  // ──────────────────────────────────────────────────────────────
  // PING ALL
  // ──────────────────────────────────────────────────────────────

  Future<void> _pingAll() async {
    if (_nodes.isEmpty || _pingAllInProgress) return;

    setState(() {
      _pingAllInProgress = true;
      for (final n in _nodes) {
        if (n.link != null) _pings[n.uuid] = -2;
      }
    });

    final v2ray = FlutterV2ray();

    await Future.wait(
      _nodes.where((n) => n.link != null).map((n) async {
        try {
          final parser = FlutterV2ray.parseFromURL(n.link!);
          final ms = await v2ray.getServerDelay(
            config: parser.getFullConfiguration(),
          );

          if (mounted) {
            setState(() => _pings[n.uuid] = ms);
          }
        } catch (_) {
          if (mounted) {
            setState(() => _pings[n.uuid] = -1);
          }
        }
      }),
    );

    if (mounted) setState(() => _pingAllInProgress = false);
  }

  Future<int?> tcpPing(String host, int port,
      {Duration timeout = const Duration(seconds: 2)}) async {
    final stopwatch = Stopwatch()..start();

    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: timeout,
      );

      stopwatch.stop();
      socket.destroy();

      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  Future<void> _tcpPingNode(ServerNode node) async {
    if (node.link == null) return;

    setState(() => _pings[node.uuid] = -2);

    try {
      final uri = Uri.parse(node.link!);
      final host = uri.host;
      final port = uri.hasPort ? uri.port : 443;

      final ms = await tcpPing(host, port);

      if (mounted) {
        setState(() => _pings[node.uuid] = ms ?? -1);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _pings[node.uuid] = -1);
      }
    }
  }

  Future<void> tcpPingAll() async {
    const maxConcurrent = 5;

    final queue = _nodes.where((n) => n.link != null).toList();

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final node = queue.removeLast();
        await _tcpPingNode(node);
      }
    }

    await Future.wait(List.generate(maxConcurrent, (_) => worker()));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _loadNodes,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              sliver: SliverToBoxAdapter(
                child: PurpleHeader(
                  title: 'Серверы',
                  subtitle: !_loading && _nodes.isNotEmpty
                      ? _isPublicCatalog
                      ? '${_nodes.length} ${_pluralServers(_nodes.length)} (каталог)'
                      : '${_nodes.length} ${_pluralServers(_nodes.length)} в подписке'
                      : null,
                  showBeta: false, // здесь BETA не нужен
                  trailing: Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: AppColors.surfaceSoft.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: IconButton(
                          icon: _pingAllInProgress
                              ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                              : const Icon(Icons.speed_outlined),
                          onPressed: (_loading || _pingAllInProgress || _isPublicCatalog)
                              ? null
                              : tcpPingAll,
                          tooltip: 'Пинг всех',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        decoration: BoxDecoration(
                          color: AppColors.surfaceSoft.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: IconButton(
                          icon: const Icon(Icons.refresh),
                          onPressed: _loading ? null : _loadNodes,
                          tooltip: 'Обновить',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Banner shown when displaying the public catalog.
            if (!_loading && _isPublicCatalog && _nodes.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                sliver: SliverToBoxAdapter(child: _buildPublicCatalogBanner()),
              ),
            if (_loading)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_nodes.isEmpty)
              SliverFillRemaining(
                child: _isPublicCatalog
                    ? _buildPublicCatalogEmptyState()
                    : _buildEmptyState(),
              )
            else ...[
                ..._buildSections(),
              ],
            const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
          ],
        ),
      ),
    );
  }

  Widget _buildPublicCatalogBanner() {
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: Colors.orange[300]),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Публичный каталог — только предпросмотр. '
                  'Для подключения оформите подписку.',
              style: TextStyle(color: Colors.orange[300], fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  String _pluralServers(int n) {
    final mod10 = n % 10;
    final mod100 = n % 100;
    if (mod100 >= 11 && mod100 <= 19) return 'серверов';
    if (mod10 == 1) return 'сервер';
    if (mod10 >= 2 && mod10 <= 4) return 'сервера';
    return 'серверов';
  }

  Widget _buildPublicCatalogEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            Text(
              'Каталог недоступен',
              style: TextStyle(color: Colors.grey[400], fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              'Не удалось загрузить серверы.\nПроверьте интернет-соединение или '
                  'добавьте URL подписки в Настройках.',
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _loadNodes,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Повторить'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: widget.onGoToSettings,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('Настройки'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF6C5CE7),
                    side: const BorderSide(color: Color(0xFF6C5CE7)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            Text(
              'Серверы не получены',
              style: TextStyle(color: Colors.grey[400], fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              'Проверьте URL подписки или интернет-соединение',
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loadNodes,
              icon: const Icon(Icons.refresh),
              label: const Text('Повторить'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final bool expanded;
  final int nodeCount;
  final VoidCallback onTap;

  const _SectionHeader({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.expanded,
    required this.nodeCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      splashColor: color.withValues(alpha: 0.12),
      highlightColor: Colors.white.withValues(alpha: 0.02),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: AppColors.textNeutralMain,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: AppColors.textNeutralSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$nodeCount',
                    style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      height: 1.0,
                    ),
                  ),
                  const SizedBox(height: 2),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeInOut,
                    child: Icon(Icons.expand_more, color: color, size: 18),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnimatedServerGroup extends StatefulWidget {
  final bool expanded;
  final List<ServerNode> nodes;
  final Map<String, int?> pings;
  final void Function(ServerNode) onPing;
  final Color color;
  final String? selectedUuid;
  final Future<void> Function(ServerNode)? onSelect;
  final bool isPublicCatalog;

  const _AnimatedServerGroup({
    required this.expanded,
    required this.nodes,
    required this.pings,
    required this.onPing,
    required this.color,
    this.selectedUuid,
    this.onSelect,
    this.isPublicCatalog = false,
  });

  @override
  State<_AnimatedServerGroup> createState() => _AnimatedServerGroupState();
}

class _AnimatedServerGroupState extends State<_AnimatedServerGroup>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _sizeAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _sizeAnim = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);

    if (widget.expanded) {
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant _AnimatedServerGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    const double groupRadius = 18;
    return ClipRect(
      child: SizeTransition(
        sizeFactor: _sizeAnim,
        axisAlignment: -1,
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Separate colored accent bar to the left of the card
                Container(
                  width: 4,
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                // Main card
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.graphiteSurface,
                      borderRadius: BorderRadius.circular(groupRadius),
                      border: Border.all(color: AppColors.graphiteElevated),
                    ),
                    child: Column(
                      children: List.generate(widget.nodes.length, (i) {
                        final node = widget.nodes[i];
                        final isSelected = node.uuid == widget.selectedUuid;

                        return Column(
                          children: [
                            _NodeTile(
                              node: node,
                              ping: widget.pings[node.uuid],
                              onPing: () => widget.onPing(node),
                              isSelected: isSelected,
                              onSelect: widget.onSelect != null
                                  ? () => widget.onSelect!(node)
                                  : null,
                              isPublicCatalog: widget.isPublicCatalog,
                            ),
                            if (i != widget.nodes.length - 1)
                              Divider(
                                height: 1,
                                thickness: 0.6,
                                color: AppColors.graphiteElevated,
                              ),
                          ],
                        );
                      }),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

// ── Тайл сервера ──────────────────────────────────────────────────────────────

class _NodeTile extends StatelessWidget {
  final ServerNode node;
  final int? ping;
  final VoidCallback? onPing;
  final bool isSelected;
  final VoidCallback? onSelect;
  final bool isPublicCatalog;

  const _NodeTile({
    required this.node,
    this.ping,
    this.onPing,
    this.isSelected = false,
    this.onSelect,
    this.isPublicCatalog = false,
  });

  @override
  Widget build(BuildContext context) {
    final protocol = node.protocol ?? '';
    final isPinging = ping == -2;

    return Material(
      color: isSelected
          ? const Color(0xFF6C5CE7).withValues(alpha: 0.08)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onSelect,
        borderRadius: BorderRadius.circular(14),
        splashColor: const Color(0xFF6C5CE7).withValues(alpha: 0.1),
        highlightColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: [
              CountryFlag.fromCountryCode(
                node.countryCode,
                theme: ImageTheme(
                  width: 40,
                  height: 32,
                  shape: RoundedRectangle(12),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      node.name,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        color: isSelected
                            ? const Color(0xFF6C5CE7)
                            : AppColors.textNeutralMain,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (protocol.isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: _protocolColor(
                                protocol,
                              ).withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              protocol.toUpperCase(),
                              style: TextStyle(
                                color: _protocolColor(protocol),
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            node.address,
                            style: const TextStyle(
                              color: AppColors.textNeutralSecondary,
                              fontSize: 12,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Trailing: checkmark when selected, lock for public catalog,
              // or ping button for subscription servers.
              if (isSelected)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.check_circle,
                    color: Color(0xFF6C5CE7),
                    size: 20,
                  ),
                )
              else if (isPublicCatalog)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.lock_outline,
                    size: 14,
                    color: Colors.grey,
                  ),
                )
              else
                InkWell(
                  onTap: (isPinging || node.link == null) ? null : onPing,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: _pingColor(ping).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: isPinging
                        ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _pingColor(ping),
                      ),
                    )
                        : Text(
                      _pingLabel(ping),
                      style: TextStyle(
                        color: _pingColor(ping),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  // HELPERS
  // ──────────────────────────────────────────────────────────

  Color _protocolColor(String p) {
    switch (p.toLowerCase()) {
      case 'vmess':
        return const Color(0xFF6C5CE7);
      case 'vless':
        return const Color(0xFF00D9FF);
      case 'trojan':
        return const Color(0xFFFFA502);
      case 'ss':
        return const Color(0xFF2ED573);
      case 'hysteria2':
      case 'hy2':
      case 'hysteria':
        return const Color(0xFFE84393);
      case 'tuic':
        return const Color(0xFFFD79A8);
      default:
        return Colors.grey;
    }
  }

  Color _pingColor(int? p) {
    if (p == null) return Colors.grey;
    if (p == -2) return const Color(0xFFFFA502);
    if (p < 0) return Colors.grey;
    if (p < 100) return const Color(0xFF2ED573);
    if (p < 300) return const Color(0xFFFFA502);
    return const Color(0xFFE74C3C);
  }

  String _pingLabel(int? p) {
    if (p == null || p < 0) return '—';
    return '${p}ms';
  }
}
