import 'package:flutter/material.dart';
import 'package:flutter_v2ray_plus/flutter_v2ray.dart';

import '../models/server_node.dart';
import '../services/remnawave_service.dart';

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

  // ping ms per node uuid: null = не тестировался, -2 = идёт, -1 = ошибка, >=0 = мс
  final Map<String, int> _pings = {};
  bool _pingAllInProgress = false;

  @override
  void initState() {
    super.initState();
    _loadNodes();
  }

  Future<void> _loadNodes() async {
    setState(() {
      _loading = true;
      _noSubscription = false;
    });

    final subUrl = await RemnawaveService.getSubscriptionUrl();
    if (subUrl.isEmpty) {
      if (mounted) {
        setState(() {
          _loading = false;
          _noSubscription = true;
          _nodes = [];
        });
      }
      return;
    }

    final nodes = await RemnawaveService.fetchNodes();
    if (mounted) {
      setState(() {
        _nodes = nodes;
        _loading = false;
        _noSubscription = false;
        final uuids = nodes.map((n) => n.uuid).toSet();
        _pings.removeWhere((k, _) => !uuids.contains(k));
      });
    }
  }

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
              config: parser.getFullConfiguration());
          if (mounted) setState(() => _pings[n.uuid] = ms);
        } catch (_) {
          if (mounted) setState(() => _pings[n.uuid] = -1);
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
                  children: [
                    Text(
                      'Серверы',
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.white),
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: _pingAllInProgress
                              ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2),
                          )
                              : const Icon(Icons.speed_outlined),
                          onPressed:
                          (_loading || _pingAllInProgress)
                              ? null
                              : _pingAll,
                          tooltip: 'Пинг всех',
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh),
                          onPressed: _loading ? null : _loadNodes,
                          tooltip: 'Обновить',
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
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverToBoxAdapter(
                      child: Text(
                        '${_nodes.length} ${_pluralServers(_nodes.length)} в подписке',
                        style:
                        TextStyle(color: Colors.grey[400], fontSize: 13),
                      ),
                    ),
                  ),
                  const SliverPadding(padding: EdgeInsets.only(top: 8)),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                            (ctx, i) => _NodeTile(
                          node: _nodes[i],
                          ping: _pings[_nodes[i].uuid],
                          onPing: () => _pingNode(_nodes[i]),
                        ),
                        childCount: _nodes.length,
                      ),
                    ),
                  ),
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
                color: const Color(0xFF6C5CE7).withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.vpn_key_outlined,
                  size: 48, color: Color(0xFF6C5CE7)),
            ),
            const SizedBox(height: 20),
            const Text('Нет подписки',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text(
              'Введите URL подписки в Настройках.\n'
                  'Получите его в Telegram-боте после оформления.',
              style: TextStyle(
                  color: Colors.grey[400], fontSize: 14, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: widget.onGoToSettings,
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Открыть Настройки'),
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF6C5CE7)),
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
            Icon(Icons.cloud_off, size: 64, color: Colors.grey[600]),
            const SizedBox(height: 16),
            Text('Серверы не получены',
                style:
                TextStyle(color: Colors.grey[400], fontSize: 16)),
            const SizedBox(height: 8),
            Text(
              'Проверьте URL подписки или интернет-соединение',
              style:
              TextStyle(color: Colors.grey[600], fontSize: 13),
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

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding:
        const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color:
                _protocolColor(protocol).withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(_countryEmoji(node.countryCode),
                    style: const TextStyle(fontSize: 22)),
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
                        fontWeight: FontWeight.w600, fontSize: 15),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (protocol.isNotEmpty) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: _protocolColor(protocol)
                                .withOpacity(0.2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            protocol.toUpperCase(),
                            style: TextStyle(
                                color: _protocolColor(protocol),
                                fontSize: 10,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          node.address,
                          style: TextStyle(
                              color: Colors.grey[500], fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: (isPinging || node.link == null) ? null : onPing,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: _pingColor(ping).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: isPinging
                    ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _pingColor(ping)),
                )
                    : Text(
                  _pingLabel(ping),
                  style: TextStyle(
                      color: _pingColor(ping),
                      fontSize: 11,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _protocolColor(String p) {
    switch (p.toLowerCase()) {
      case 'vmess':     return const Color(0xFF6C5CE7);
      case 'vless':     return const Color(0xFF00D9FF);
      case 'trojan':    return const Color(0xFFFFA502);
      case 'ss':        return const Color(0xFF2ED573);
      case 'hysteria2':
      case 'hy2':
      case 'hysteria':  return const Color(0xFFE84393);
      case 'tuic':      return const Color(0xFFFD79A8);
      default:          return Colors.grey;
    }
  }

  Color _pingColor(int? p) {
    if (p == null)  return Colors.grey;
    if (p == -2)    return const Color(0xFFFFA502);
    if (p < 0)      return Colors.grey;
    if (p < 100)    return const Color(0xFF2ED573);
    if (p < 300)    return const Color(0xFFFFA502);
    return const Color(0xFFE74C3C);
  }

  String _pingLabel(int? p) {
    if (p == null || p < 0) return '—';
    return '${p}ms';
  }

  String _countryEmoji(String code) {
    if (code.length != 2) return '🌐';
    final u = code.toUpperCase();
    final f = u.codeUnitAt(0), s = u.codeUnitAt(1);
    if (f < 0x41 || f > 0x5A || s < 0x41 || s > 0x5A) return '🌐';
    const base = 0x1F1E6 - 0x41;
    return String.fromCharCode(base + f) + String.fromCharCode(base + s);
  }
}