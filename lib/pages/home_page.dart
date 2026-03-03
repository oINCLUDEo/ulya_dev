import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_v2ray_plus/flutter_v2ray.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/server_node.dart';
import '../models/subscription_info.dart';
import '../services/remnawave_service.dart';
import '../theme/app_colors.dart';
import '../utils/speed_calculator.dart';
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

  String get _statusLabel {
    final s = _status.state.toUpperCase();
    if (s == 'CONNECTED') return 'Подключено';
    if (s == 'CONNECTING' || _isConnecting) return 'Подключение…';
    if (s == 'DISCONNECTING') return 'Отключение…';
    return 'Отключено';
  }

  double _normalizeSpeed(int bytesPerSecond) {
    return bytesPerSecond / (1024 * 1024); // → MB/s стабильно
  }

  late final SpeedCalculator _speedCalc;

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

    _speedCalc = SpeedCalculator(smoothing: 0.25);

    _v2ray = FlutterV2ray();
    _init();
  }

  Future<void> _init() async {
    await _v2ray.initializeVless(
      notificationIconResourceType: 'mipmap',
      notificationIconResourceName: 'ic_launcher',
    );

    _statusSub = _v2ray.onStatusChanged.listen((s) {
      if (!mounted) return;

      // обновляем калькулятор ДО setState
      _speedCalc.update(
        totalUploadBytes: s.upload,
        totalDownloadBytes: s.download,
      );

      setState(() {
        _status = s;
      });

      // если отключились — сбрасываем скорость
      if (s.state.toUpperCase() != 'CONNECTED') {
        _speedCalc.reset();
      }
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
                            .withValues(alpha: 0.15)
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
                                tooltip: 'Конфиг',
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
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(protocol.toUpperCase(),
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w700)),
    );
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }

  String _fmtDuration(int sec) {
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final s = sec % 60;
    if (h > 0) {
      return '$hч ${m.toString().padLeft(2, '0')}м';
      }
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
                    color: AppColors.primary.withValues(alpha: 0.35),
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
                            color: Colors.white.withValues(alpha: 0.08),
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
            color: AppColors.surfaceSoft.withValues(alpha: 0.7),
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
    final bool connected = _isConnected;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        color: const Color(0xFF171A21),
        border: Border.all(
          color: connected
              ? const Color(0xFF7C5CFF)
              : const Color(0xFF2A2F3A),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 40,
            offset: const Offset(0, 20),
          ),
          if (connected)
            BoxShadow(
              color: const Color(0xFF7C5CFF).withValues(alpha: 0.25),
              blurRadius: 50,
              spreadRadius: -10,
            ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(26, 28, 26, 26),
        child: Column(
          children: [

            /// STATUS

            Column(
              children: [
                Text(
                  _statusLabel,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: connected
                        ? const Color(0xFFE2E8F0)
                        : const Color(0xFFC9D1D9),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  connected
                      ? 'Сессия: ${_fmtDuration(_status.duration)}'
                      : 'Выберите сервер и подключитесь',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF8A94A6),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 32),

            /// BUTTON
            Center(
              child: PremiumConnectButton(
                isConnected: _isConnected,
                isLoading: _isTransitioning,
                onTap: _toggleConnection,
              ),
            ),

            const SizedBox(height: 34),

            Container(
              height: 1,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    Color(0xFF2A2F3A),
                    Colors.transparent,
                  ],
                ),
              ),
            ),

            const SizedBox(height: 22),

            /// SERVER PICKER

            InkWell(
              onTap: _showServerPicker,
              borderRadius: BorderRadius.circular(18),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 18, vertical: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1F2430),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: const Color(0xFF2E3442),
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      _selectedNode != null
                          ? _countryEmoji(_selectedNode!.countryCode)
                          : '🌐',
                      style: const TextStyle(fontSize: 22),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment:
                        CrossAxisAlignment.start,
                        children: [
                          Text(
                            _selectedNode?.name ?? 'Выберите сервер',
                            style: TextStyle(
                              color: _selectedNode != null
                                  ? const Color(0xFFE2E8F0)
                                  : const Color(0xFF7C5CFF),
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                          if (_selectedNode != null)
                            Text(
                              _selectedNode!.address,
                              style: const TextStyle(
                                color: Color(0xFF8A94A6),
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.arrow_forward_ios_rounded,
                      size: 16,
                      color: Color(0xFF7C5CFF),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Карточка текущего трафика (скорость) ──────────────────────────────────

  Widget _buildTrafficCard() {
    final uploadMB = _normalizeSpeed(_status.uploadSpeed);
    final downloadMB = _normalizeSpeed(_status.downloadSpeed);

    final uploadActive = uploadMB > 0.01;
    final downloadActive = downloadMB > 0.01;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: const Color(0xFF171A21),
        border: Border.all(color: const Color(0xFF2A2F3A)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 40,
            offset: const Offset(0, 20),
          ),
          if (uploadActive || downloadActive)
            BoxShadow(
              color: const Color(0xFF7C5CFF).withValues(alpha: 0.08),
              blurRadius: 50,
              spreadRadius: -10,
            ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
        child: Row(
          children: [
            Expanded(
              child: _StatTile(
                icon: Icons.arrow_upward,
                label: 'Загрузка',
                value: _speedCalc.uploadSpeed,
                sub: _fmtBytes(_status.uploadSpeed),
                color: uploadActive
                    ? const Color(0xFF7C5CFF)
                    : const Color(0xFF5E6C8A),
              ),
            ),
            Container(
              width: 1,
              height: 60,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    Color(0xFF2E3442),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            Expanded(
              child: _StatTile(
                icon: Icons.arrow_downward,
                label: 'Скачивание',
                value: _speedCalc.downloadSpeed,
                sub: _fmtBytes(_status.download),
                color: downloadActive
                    ? const Color(0xFF00E0FF)
                    : const Color(0xFF5E6C8A),
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

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: AppColors.graphiteSurface,
        border: Border.all(
          color: AppColors.graphiteElevated,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.account_circle_outlined,
                        color: AppColors.accentSmoky, size: 20),
                    const SizedBox(width: 8),
                    const Text(
                      'Подписка',
                      style: TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                  ],
                ),
                if (info?.expireDate != null)
                  _ExpiryBadge(expireDate: info!.expireDate!),
              ],
            ),

            const SizedBox(height: 16),

            if (info == null)
              const Center(
                child: Text(
                  'Загрузка данных подписки…',
                  style: TextStyle(
                      color: AppColors.textNeutralSecondary,
                      fontSize: 13),
                ),
              )
            else ...[
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
}

// ── Вспомогательные виджеты ───────────────────────────────────────────────────

class _StatTile extends StatefulWidget {
  final IconData icon;
  final String label;
  final double value;
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
  State<_StatTile> createState() => _StatTileState();
}

class _StatTileState extends State<_StatTile> {
  late double _displayValue;

  @override
  void initState() {
    super.initState();
    _displayValue = widget.value;
  }

  @override
  void didUpdateWidget(covariant _StatTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _displayValue = oldWidget.value;
    }
  }

  String _format(double bytesPerSecond) {
    if (bytesPerSecond < 1024) {
      return "${bytesPerSecond.toStringAsFixed(0)} B/s";
    } else if (bytesPerSecond < 1024 * 1024) {
      return "${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s";
    } else {
      return "${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(2)} MB/s";
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(widget.icon, color: widget.color, size: 15),
            const SizedBox(width: 6),
            Text(
              widget.label,
              style: const TextStyle(
                color: Color(0xFF8A94A6),
                fontSize: 11,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),

        TweenAnimationBuilder<double>(
          tween: Tween<double>(
            begin: _displayValue,
            end: widget.value,
          ),
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          builder: (context, animatedValue, child) {
            return Text(
              _format(animatedValue),
              style: TextStyle(
                color: widget.color,
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            );
          },
        ),

        const SizedBox(height: 3),

        Text(
          widget.sub,
          style: const TextStyle(
            color: Color(0xFF5F6B7A),
            fontSize: 11,
          ),
        ),
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
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
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

class PremiumConnectButton extends StatelessWidget {
  final bool isConnected;
  final bool isLoading;
  final VoidCallback onTap;

  const PremiumConnectButton({
    super.key,
    required this.isConnected,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bool isOff = !isConnected && !isLoading;

    final backgroundColor = isOff
        ? const Color(0xFF5E6C8A) // акцент
        : isConnected
        ? const Color(0xFFC9D1D9) // platinum
        : AppColors.graphiteElevated;

    final foreground = isConnected
        ? AppColors.graphiteBackground
        : AppColors.textNeutralMain;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      height: 60,
      width: 240,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          if (isOff)
            BoxShadow(
              color: const Color(0xFF5E6C8A).withValues(alpha: 0.35),
              blurRadius: 40,
              offset: const Offset(0, 18),
            )
          else if (isConnected)
            BoxShadow(
              color: const Color(0xFFC9D1D9).withValues(alpha: 0.35),
              blurRadius: 45,
              spreadRadius: -6,
            )
          else
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 28,
              offset: const Offset(0, 14),
            ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: isLoading ? null : onTap,
          child: Center(
            child: isLoading
                ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: foreground,
              ),
            )
                : Text(
              isConnected ? 'Отключить' : 'Подключить',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 15,
                letterSpacing: 0.4,
                color: foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
