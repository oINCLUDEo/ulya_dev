import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_v2ray_plus/flutter_v2ray.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/server_node.dart';
import '../models/subscription_info.dart';
import '../services/remnawave_service.dart';
import '../theme/app_colors.dart';
import 'config_editor_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // ── flutter_v2ray_plus ───────────────────────────────────────────────────
  late final FlutterV2ray _v2ray;
  VlessStatus _status = VlessStatus();
  StreamSubscription<VlessStatus>? _statusSub;

  // ── Серверы ──────────────────────────────────────────────────────────────
  List<ServerNode> _nodes = [];
  ServerNode? _selectedNode;
  bool _isLoadingNodes = false;
  SubscriptionInfo? _subscriptionInfo;

  // ── Анимация ─────────────────────────────────────────────────────────────
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  bool _initialized = false;
  bool _isConnecting = false;

  // ── Helpers ───────────────────────────────────────────────────────────────
  bool get _isConnected =>
      _status.state.toUpperCase() == 'CONNECTED';
  bool get _isTransitioning =>
      _status.state.toUpperCase() == 'CONNECTING' ||
          _status.state.toUpperCase() == 'DISCONNECTING' ||
          _isConnecting;

  Color get _statusColor {
    if (_isConnected) return const Color(0xFF2ED573);
    if (_isTransitioning) return const Color(0xFFFFA502);
    return Colors.grey;
  }

  String get _statusLabel {
    final s = _status.state.toUpperCase();
    if (s == 'CONNECTED') return 'Подключено';
    if (s == 'CONNECTING' || _isConnecting) return 'Подключение…';
    if (s == 'DISCONNECTING') return 'Отключение…';
    return 'Отключено';
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _pulseCtrl = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    _v2ray = FlutterV2ray();
    _init();
  }

  Future<void> _init() async {
    await _v2ray.initializeVless(
      notificationIconResourceType: 'mipmap',
      notificationIconResourceName: 'ic_launcher',
    );
    _statusSub = _v2ray.onStatusChanged.listen((s) {
      if (mounted) setState(() => _status = s);
    });
    if (mounted) setState(() => _initialized = true);
    _loadNodes();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadNodes();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusSub?.cancel();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ── Загрузка серверов ─────────────────────────────────────────────────────

  Future<void> _loadNodes() async {
    if (!mounted) return;
    setState(() => _isLoadingNodes = true);
    final nodes = await RemnawaveService.fetchNodes();
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final savedUuid = prefs.getString('selected_node_uuid');
    setState(() {
      _nodes = nodes;
      _subscriptionInfo = RemnawaveService.lastSubscriptionInfo;
      _isLoadingNodes = false;
      if (_selectedNode != null) {
        _selectedNode = nodes.cast<ServerNode?>().firstWhere(
              (n) => n?.uuid == _selectedNode!.uuid,
          orElse: () => null,
        );
      }
      if (_selectedNode == null && savedUuid != null) {
        _selectedNode = nodes.cast<ServerNode?>().firstWhere(
              (n) => n?.uuid == savedUuid,
          orElse: () => null,
        );
      }
    });
  }

  // ── Подключение ───────────────────────────────────────────────────────────

  Future<void> _toggleConnection() async {
    if (_isTransitioning) return;

    if (_isConnected) {
      await _v2ray.stopVless();
      return;
    }

    final node = _selectedNode;
    if (node == null || node.link == null) {
      _snack('Сначала выберите сервер');
      return;
    }

    if (!await _v2ray.requestPermission()) {
      _snack('Нет разрешения VPN');
      return;
    }

    setState(() => _isConnecting = true);
    try {
      final parser = FlutterV2ray.parseFromURL(node.link!);
      await _v2ray.startVless(
        remark: node.name,
        config: parser.getFullConfiguration(),
        notificationDisconnectButtonName: 'Отключить',
        proxyOnly: false,
      );
    } catch (e) {
      _snack('Ошибка подключения: $e');
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  // ── Конфиг выбранного сервера ─────────────────────────────────────────────

  void _openConfigEditor(ServerNode node) {
    if (node.link == null) {
      _snack('Нет ссылки для этого сервера');
      return;
    }
    try {
      final parser = FlutterV2ray.parseFromURL(node.link!);
      final json = const JsonEncoder.withIndent('  ')
          .convert(jsonDecode(parser.getFullConfiguration()));
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ConfigEditorPage(
            configJson: json,
            configName: node.name,
          ),
        ),
      );
    } catch (e) {
      _snack('Не удалось разобрать конфиг: $e');
    }
  }

  // ── Пикер серверов ────────────────────────────────────────────────────────

  void _showServerPicker() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.6,
            maxChildSize: 0.92,
            minChildSize: 0.3,
            builder: (_, scrollCtrl) => Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[600],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Выбрать сервер',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold),
                      ),
                      _isLoadingNodes
                          ? const SizedBox(
                          width: 20,
                          height: 20,
                          child:
                          CircularProgressIndicator(strokeWidth: 2))
                          : IconButton(
                        icon: const Icon(Icons.refresh, size: 20),
                        onPressed: () async {
                          setSheet(() {});
                          await _loadNodes();
                          setSheet(() {});
                        },
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _nodes.isEmpty
                      ? Center(
                    child: _isLoadingNodes
                        ? const CircularProgressIndicator()
                        : Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.cloud_off,
                              size: 48,
                              color: Colors.grey[600]),
                          const SizedBox(height: 12),
                          Text(
                            'Серверы не получены.\nПроверьте URL подписки в Настройках.',
                            style: TextStyle(
                                color: Colors.grey[400],
                                fontSize: 14),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                      : ListView.builder(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    itemCount: _nodes.length,
                    itemBuilder: (_, i) {
                      final node = _nodes[i];
                      final isSel =
                          _selectedNode?.uuid == node.uuid;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 6),
                        color: isSel
                            ? const Color(0xFF6C5CE7)
                            .withOpacity(0.15)
                            : null,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: isSel
                              ? const BorderSide(
                              color: Color(0xFF6C5CE7),
                              width: 1.5)
                              : BorderSide.none,
                        ),
                        child: ListTile(
                          onTap: () async {
                            setState(() => _selectedNode = node);
                            final prefs =
                                await SharedPreferences.getInstance();
                            await prefs.setString(
                                'selected_node_uuid', node.uuid);
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                          leading: Text(
                            _countryEmoji(node.countryCode),
                            style: const TextStyle(fontSize: 24),
                          ),
                          title: Text(
                            node.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14),
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            node.address,
                            style: TextStyle(
                                color: Colors.grey[500],
                                fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isSel)
                                const Icon(Icons.check_circle,
                                    color: Color(0xFF6C5CE7))
                              else
                                _protocolBadge(
                                    node.protocol ?? ''),
                              IconButton(
                                icon: const Icon(
                                    Icons.code_outlined,
                                    size: 18,
                                    color: Colors.white38),
                                tooltip: 'Конф��г',
                                visualDensity: VisualDensity.compact,
                                onPressed: () {
                                  Navigator.pop(ctx);
                                  _openConfigEditor(node);
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF2D2D44),
      shape:
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  String _countryEmoji(String code) {
    if (code.length != 2) return '🌐';
    final u = code.toUpperCase();
    final f = u.codeUnitAt(0), s = u.codeUnitAt(1);
    if (f < 0x41 || f > 0x5A || s < 0x41 || s > 0x5A) return '🌐';
    const base = 0x1F1E6 - 0x41;
    return String.fromCharCode(base + f) + String.fromCharCode(base + s);
  }

  Widget _protocolBadge(String protocol) {
    if (protocol.isEmpty) return const SizedBox.shrink();
    Color color;
    switch (protocol.toLowerCase()) {
      case 'vless':  color = const Color(0xFF00D9FF); break;
      case 'vmess':  color = const Color(0xFF6C5CE7); break;
      case 'trojan': color = const Color(0xFFFFA502); break;
      case 'ss':     color = const Color(0xFF2ED573); break;
      default:       color = Colors.grey;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(protocol.toUpperCase(),
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w700)),
    );
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024)
      return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }

  String _fmtSpeed(int bps) => '${_fmtBytes(bps)}/с';

  String _fmtDuration(int sec) {
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final s = sec % 60;
    if (h > 0)
      return '${h}ч ${m.toString().padLeft(2, '0')}м';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadNodes,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
            children: [
              _buildHeader(),
              const SizedBox(height: 16),
              _buildConnectionCard(),
              const SizedBox(height: 12),
              _buildTrafficCard(),
              const SizedBox(height: 12),
              _buildSubscriptionCard(),
            ],
          ),
        ),
      ),
    );
  }

  // ── Заголовок ─────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    final theme = Theme.of(context);

    final subtitle = _isConnected
        ? 'Соединение защищено'
        : 'Свобода начинается с приватности';

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Мягкое темное свечение
            Container(
              decoration: BoxDecoration(
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withOpacity(0.35),
                    blurRadius: 24,
                    spreadRadius: -8,
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Ulya VPN',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: AppColors.textMain,
                          letterSpacing: 0.4,
                        ),
                      ),
                      const SizedBox(width: 8),

                      // Тёмная BETA плашка (без розовости)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          gradient: AppColors.gradientAccent,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.08),
                          ),
                        ),
                        child: const Text(
                          'BETA',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),

                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Text(
                      subtitle,
                      key: ValueKey(subtitle),
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),

        Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceSoft.withOpacity(0.7),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white10),
          ),
          child: IconButton(
            icon: _isLoadingNodes
                ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
                : const Icon(Icons.refresh_rounded),
            onPressed: _isLoadingNodes ? null : _loadNodes,
            tooltip: 'Обновить серверы',
          ),
        ),
      ],
    );
  }
  // ── Карточка подключения ──────────────────────────────────────────────────

  Widget _buildConnectionCard() {
    return Card(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: _isConnected
              ? LinearGradient(
            colors: [
              const Color(0xFF2ED573).withOpacity(0.15),
              const Color(0xFF6C5CE7).withOpacity(0.08),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          )
              : null,
        ),
        child: Column(
          children: [
            // Иконка + статус
            GestureDetector(
              onTap: _toggleConnection,
              child: Row(
                children: [
                  AnimatedBuilder(
                    animation: _pulseAnim,
                    builder: (_, __) => Transform.scale(
                      scale: _isTransitioning ? _pulseAnim.value : 1.0,
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _statusColor.withOpacity(0.18),
                        ),
                        child: _isTransitioning
                            ? SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            valueColor: AlwaysStoppedAnimation(
                                _statusColor),
                          ),
                        )
                            : Icon(
                          _isConnected
                              ? Icons.shield
                              : Icons.shield_outlined,
                          color: _statusColor,
                          size: 32,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _statusLabel,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: _statusColor,
                          ),
                        ),
                        if (_isConnected)
                          Text(
                            'Сессия: ${_fmtDuration(_status.duration)}',
                            style: TextStyle(
                                color: Colors.grey[400], fontSize: 13),
                          ),
                      ],
                    ),
                  ),
                  Icon(
                    _isConnected
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline,
                    color: _statusColor,
                    size: 40,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),
            const Divider(height: 1, color: Colors.white10),
            const SizedBox(height: 12),

            // Выбор сервера
            InkWell(
              onTap: _showServerPicker,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                ),
                child: Row(
                  children: [
                    Text(
                      _selectedNode != null
                          ? _countryEmoji(_selectedNode!.countryCode)
                          : '🌐',
                      style: const TextStyle(fontSize: 22),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _selectedNode?.name ?? 'Выберите сервер',
                            style: TextStyle(
                              color: _selectedNode != null
                                  ? Colors.white
                                  : const Color(0xFF6C5CE7),
                              fontWeight: _selectedNode != null
                                  ? FontWeight.w600
                                  : FontWeight.bold,
                              fontSize: 14,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (_selectedNode != null)
                            Text(
                              _selectedNode!.address,
                              style: TextStyle(
                                  color: Colors.grey[500], fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    if (_selectedNode != null)
                      IconButton(
                        icon: const Icon(Icons.code_outlined,
                            size: 20, color: Colors.white38),
                        tooltip: 'Посмотреть конфиг',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _openConfigEditor(_selectedNode!),
                      ),
                    const Icon(Icons.expand_more_rounded,
                        color: Colors.white38),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // Кнопка подключения
            FilledButton.icon(
              onPressed: _isTransitioning ? null : _toggleConnection,
              icon: _isTransitioning
                  ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
                  : Icon(
                  _isConnected ? Icons.stop : Icons.play_arrow),
              label: Text(
                _isConnected
                    ? 'Отключить'
                    : _isTransitioning
                    ? 'Подождите…'
                    : 'Подключить',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: _isConnected
                    ? const Color(0xFFE74C3C)
                    : const Color(0xFF6C5CE7),
                minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Карточка текущего трафика (скорость) ──────────────────────────────────

  Widget _buildTrafficCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: _StatTile(
                icon: Icons.arrow_upward,
                label: 'Загрузка',
                value: _fmtSpeed(_status.uploadSpeed),
                sub: _fmtBytes(_status.upload),
                color: const Color(0xFF6C5CE7),
              ),
            ),
            Container(width: 1, height: 48, color: Colors.white10),
            Expanded(
              child: _StatTile(
                icon: Icons.arrow_downward,
                label: 'Скачивание',
                value: _fmtSpeed(_status.downloadSpeed),
                sub: _fmtBytes(_status.download),
                color: const Color(0xFF00D9FF),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Карточка подписки (трафик + дата) ─────────────────────────────────────

  Widget _buildSubscriptionCard() {
    final info = _subscriptionInfo;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Заголовок
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.account_circle_outlined,
                        color: const Color(0xFF6C5CE7), size: 20),
                    const SizedBox(width: 8),
                    const Text(
                      'Подписка',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                  ],
                ),
                if (info?.expireDate != null)
                  _ExpiryBadge(expireDate: info!.expireDate!),
              ],
            ),

            const SizedBox(height: 14),

            if (info == null) ...[
              // Подписка ещё не загружена
              Center(
                child: Text(
                  _subscriptionInfo == null && !_isLoadingNodes
                      ? 'Задайте URL подписки в Настройках'
                      : 'Загрузка данных подписки…',
                  style:
                  TextStyle(color: Colors.grey[500], fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
            ] else ...[
              // ── Трафик ─────────────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Использовано',
                          style: TextStyle(
                              color: Colors.grey[500], fontSize: 11)),
                      const SizedBox(height: 2),
                      Text(
                        info.formattedUsed,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('Всего',
                          style: TextStyle(
                              color: Colors.grey[500], fontSize: 11)),
                      const SizedBox(height: 2),
                      Text(
                        info.formattedTotal,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 10),

              // Прогресс-бар
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: info.usedFraction,
                  minHeight: 8,
                  backgroundColor: Colors.white12,
                  valueColor: AlwaysStoppedAnimation(
                    _progressColor(info.usedFraction),
                  ),
                ),
              ),

              const SizedBox(height: 8),

              // Оставшийся трафик
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Осталось: ${_remainingTraffic(info)}',
                    style: TextStyle(
                        color: Colors.grey[400], fontSize: 12),
                  ),
                  Text(
                    '${(info.usedFraction * 100).toStringAsFixed(1)}%',
                    style: TextStyle(
                        color: _progressColor(info.usedFraction),
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),

              // Детали (upload / download отдельно)
              const SizedBox(height: 8),
              const Divider(height: 1, color: Colors.white10),
              const SizedBox(height: 8),
              Row(
                children: [
                  _SubTrafficChip(
                    icon: Icons.arrow_upward,
                    label: '↑ ${_fmtSubBytes(info.uploadBytes)}',
                    color: const Color(0xFF6C5CE7),
                  ),
                  const SizedBox(width: 12),
                  _SubTrafficChip(
                    icon: Icons.arrow_downward,
                    label: '↓ ${_fmtSubBytes(info.downloadBytes)}',
                    color: const Color(0xFF00D9FF),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Color _progressColor(double fraction) {
    if (fraction < 0.6) return const Color(0xFF2ED573);
    if (fraction < 0.85) return const Color(0xFFFFA502);
    return const Color(0xFFE74C3C);
  }

  String _remainingTraffic(SubscriptionInfo info) {
    if (info.totalBytes <= 0) return '∞';
    final rem = info.totalBytes - info.usedBytes;
    if (rem <= 0) return '0 ГБ';
    return SubscriptionInfo(
      uploadBytes: 0,
      downloadBytes: rem,
      totalBytes: info.totalBytes,
    ).formattedUsed; // re-use formatter
  }

  String _fmtSubBytes(int bytes) {
    final gb = bytes / (1024 * 1024 * 1024);
    if (gb >= 0.1) return '${gb.toStringAsFixed(2)} ГБ';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(0)} МБ';
  }
}

// ── Вспомогательные виджеты ───────────────────────────────────────────────────

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String sub;
  final Color color;

  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.sub,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 13),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(color: Colors.grey[400], fontSize: 11)),
          ],
        ),
        const SizedBox(height: 4),
        Text(value,
            style: TextStyle(
                color: color,
                fontSize: 16,
                fontWeight: FontWeight.bold)),
        Text(sub,
            style: TextStyle(color: Colors.grey[600], fontSize: 11)),
      ],
    );
  }
}

class _ExpiryBadge extends StatelessWidget {
  final DateTime expireDate;
  const _ExpiryBadge({required this.expireDate});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final diff = expireDate.difference(now);
    final expired = diff.isNegative;
    final soon = !expired && diff.inDays < 7;

    final color = expired
        ? const Color(0xFFE74C3C)
        : soon
        ? const Color(0xFFFFA502)
        : const Color(0xFF2ED573);

    final label = expired
        ? 'Истекла'
        : diff.inDays > 0
        ? '${diff.inDays}д осталось'
        : '< 1д';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(expired ? Icons.timer_off : Icons.timer_outlined,
              color: color, size: 12),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _SubTrafficChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _SubTrafficChip(
      {required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(
                color: Colors.grey[400],
                fontSize: 12)),
      ],
    );
  }
}