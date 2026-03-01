import 'package:flutter/material.dart';

import '../models/server_node.dart';
import '../services/remnawave_service.dart';

class ServersPage extends StatefulWidget {
  /// Called when the user taps the "Open Settings" button so the parent
  /// shell can switch to the Settings tab without hard-coding an index.
  final VoidCallback? onGoToSettings;

  const ServersPage({super.key, this.onGoToSettings});

  @override
  State<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends State<ServersPage> {
  List<ServerNode> _nodes = [];
  bool _loading = true;
  bool _noSubscription = false;

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
      });
    }
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
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: _loading ? null : _loadNodes,
                      tooltip: 'Обновить',
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
                    style: TextStyle(color: Colors.grey[400], fontSize: 13),
                  ),
                ),
              ),
              const SliverPadding(padding: EdgeInsets.only(top: 8)),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) => _NodeTile(node: _nodes[i]),
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
              'Чтобы увидеть доступные серверы, введите URL вашей подписки. '
              'Получите его в Telegram-боте после оформления подписки.',
              style: TextStyle(
                color: Colors.grey[400],
                fontSize: 14,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () {
                if (widget.onGoToSettings != null) {
                  widget.onGoToSettings!();
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Перейдите в Настройки → Подписка'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
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
            Icon(Icons.cloud_off, size: 64, color: Colors.grey[600]),
            const SizedBox(height: 16),
            Text(
              'Серверы не получены',
              style: TextStyle(color: Colors.grey[400], fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              'Проверьте URL подписки или подключение к интернету',
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

class _NodeTile extends StatelessWidget {
  final ServerNode node;

  const _NodeTile({required this.node});

  @override
  Widget build(BuildContext context) {
    final protocol = node.protocol ?? '';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: _protocolColor(protocol).withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
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
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    node.address,
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (protocol.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _protocolColor(protocol).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
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
          ],
        ),
      ),
    );
  }

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

  String _countryEmoji(String countryCode) {
    if (countryCode.length != 2) return '🌐';
    final base = 0x1F1E6 - 0x41;
    final first = countryCode[0].toUpperCase().codeUnitAt(0);
    final second = countryCode[1].toUpperCase().codeUnitAt(0);
    return String.fromCharCode(base + first) + String.fromCharCode(base + second);
  }
}

