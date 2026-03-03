import 'package:flutter/material.dart';
import 'package:flutter_v2ray_plus/flutter_v2ray.dart';

import '../models/server_node.dart';
import '../services/remnawave_service.dart';
import '../theme/app_colors.dart';

class ServersPage extends StatefulWidget {
  final VoidCallback? onGoToSettings;

  const ServersPage({super.key, this.onGoToSettings});

  @override
  State<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends State<ServersPage> {
  List<ServerNode> _nodes = [];
  bool _loading = true;
  bool _noSubscription = false;

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

  @override
  void initState() {
    super.initState();
    _loadNodes();
  }

  // ──────────────────────────────────────────────────────────────
  // LOAD NODES
  // ──────────────────────────────────────────────────────────────

  Future<void> _loadNodes() async {
    setState(() {
      _loading = true;
      _noSubscription = false;
    });

    final subUrl = await RemnawaveService.getSubscriptionUrl();

    if (subUrl.isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _noSubscription = true;
        _nodes = [];
      });
      return;
    }

    final nodes = await RemnawaveService.fetchNodes();

    if (!mounted) return;

    setState(() {
      _nodes = nodes;
      _loading = false;
      _noSubscription = false;

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
              onPing: _pingNode,
              color: color,
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
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.3),
                            blurRadius: 24,
                            spreadRadius: -8,
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Серверы',
                            style: Theme.of(context).textTheme.headlineMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w900,
                                  color: Colors.white,
                                  letterSpacing: 0.4,
                                ),
                          ),
                          if (!_loading &&
                              !_noSubscription &&
                              _nodes.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              '${_nodes.length} ${_pluralServers(_nodes.length)} в подписке',
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Row(
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
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.speed_outlined),
                            onPressed: (_loading || _pingAllInProgress)
                                ? null
                                : _pingAll,
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
                  ],
                ),
              ),
            ),
            if (_loading)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_noSubscription)
              SliverFillRemaining(child: _buildNoSubscriptionState())
            else if (_nodes.isEmpty)
              SliverFillRemaining(child: _buildEmptyState())
            else ...[
              ..._buildSections(),
            ],
            const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
          ],
        ),
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

  Widget _buildNoSubscriptionState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF6C5CE7).withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.vpn_key_outlined,
                size: 48,
                color: Color(0xFF6C5CE7),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Нет подписки',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Введите URL подписки в Настройках.\nПолучите его в Telegram-боте после оформления.',
              style: TextStyle(
                color: Colors.grey[400],
                fontSize: 14,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: widget.onGoToSettings,
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Открыть Настройки'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF6C5CE7),
              ),
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

  const _AnimatedServerGroup({
    required this.expanded,
    required this.nodes,
    required this.pings,
    required this.onPing,
    required this.color,
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

                        return Column(
                          children: [
                            _NodeTile(
                              node: node,
                              ping: widget.pings[node.uuid],
                              onPing: () => widget.onPing(node),
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

  const _NodeTile({required this.node, this.ping, this.onPing});

  @override
  Widget build(BuildContext context) {
    final protocol = node.protocol ?? '';
    final isPinging = ping == -2;

    return InkWell(
      onTap: () {},
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.graphiteElevated,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Center(
                child: Text(
                  _countryEmoji(node.countryCode),
                  style: const TextStyle(fontSize: 22),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    node.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: AppColors.textNeutralMain,
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

  String _countryEmoji(String code) {
    if (code.length != 2) return '🌐';
    final u = code.toUpperCase();
    final f = u.codeUnitAt(0);
    final s = u.codeUnitAt(1);
    if (f < 0x41 || f > 0x5A || s < 0x41 || s > 0x5A) {
      return '🌐';
    }
    const base = 0x1F1E6 - 0x41;
    return String.fromCharCode(base + f) + String.fromCharCode(base + s);
  }
}
