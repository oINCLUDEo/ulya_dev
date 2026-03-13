import 'dart:async';
import 'dart:convert';

import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter_v2ray_plus/flutter_v2ray.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/me_response.dart';
import '../models/server_node.dart';
import '../models/subscription_info.dart';
import '../services/auth_service.dart';
import '../services/auth_state.dart';
import '../services/me_service.dart';
import '../services/remnawave_service.dart';
import '../services/selected_server_state.dart';
import '../utils/speed_calculator.dart';
import '../widgets/telegram_login_button.dart';
import 'auth_bottom_sheet.dart';
import 'config_editor_page.dart';
import '../main.dart' show DS;

class HomePage extends StatefulWidget {
  final VoidCallback? onGoToPremium;

  const HomePage({super.key, this.onGoToPremium});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // ── V2ray ──────────────────────────────────────────────────────────────────
  late final FlutterV2ray _v2ray;
  VlessStatus _status = VlessStatus();
  StreamSubscription<VlessStatus>? _statusSub;

  // ── Nodes ──────────────────────────────────────────────────────────────────
  List<ServerNode> _nodes = [];
  ServerNode? _selectedNode;
  bool _isLoadingNodes = false;
  bool _isPublicCatalog = false;
  SubscriptionInfo? _subscriptionInfo;
  String _lastKnownSubUrl = '';

  // ── State ──────────────────────────────────────────────────────────────────
  late final SpeedCalculator _speedCalc;
  bool _initialized = false;
  bool _isConnecting = false;

  // ── Computed ───────────────────────────────────────────────────────────────
  bool get _isConnected => _status.state.toUpperCase() == 'CONNECTED';
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

  // ── Lifecycle ──────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    selectedServerNotifier.addListener(_onSelectedServerChanged);
    authStateNotifier.addListener(_onAuthChanged);
    meNotifier.addListener(_onMeChanged);
    _speedCalc = SpeedCalculator(smoothing: 0.25);
    _v2ray = FlutterV2ray();
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshAll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    selectedServerNotifier.removeListener(_onSelectedServerChanged);
    authStateNotifier.removeListener(_onAuthChanged);
    meNotifier.removeListener(_onMeChanged);
    _statusSub?.cancel();
    super.dispose();
  }

  void _onSelectedServerChanged() {
    if (!mounted) return;
    final node = selectedServerNotifier.value;
    if (node?.uuid != _selectedNode?.uuid) setState(() => _selectedNode = node);
  }

  void _onAuthChanged() => _loadNodes();

  void _onMeChanged() {
    final url = meNotifier.value?.subscription?.subscriptionUrl ?? '';
    if (url != _lastKnownSubUrl) { _lastKnownSubUrl = url; _loadNodes(); }
  }

  // ── Init ───────────────────────────────────────────────────────────────────
  Future<void> _init() async {
    await _v2ray.initializeVless(
      notificationIconResourceType: 'mipmap',
      notificationIconResourceName: 'ic_launcher',
    );
    _statusSub = _v2ray.onStatusChanged.listen((s) {
      if (!mounted) return;
      _speedCalc.update(totalUploadBytes: s.upload, totalDownloadBytes: s.download);
      setState(() => _status = s);
      if (s.state.toUpperCase() != 'CONNECTED') _speedCalc.reset();
    });
    if (mounted) setState(() => _initialized = true);
    _loadNodes();
  }

  // ── Data ───────────────────────────────────────────────────────────────────
  Future<void> _refreshAll() async {
    await MeService.refresh();
    await _loadNodes();
  }

  Future<void> _loadNodes() async {
    if (!mounted) return;
    setState(() => _isLoadingNodes = true);
    final subUrl = await RemnawaveService.getSubscriptionUrl();
    final List<ServerNode> nodes;
    final bool isPublic;
    if (subUrl.isEmpty) {
      nodes = await RemnawaveService.fetchPublicServers();
      isPublic = true;
    } else {
      nodes = await RemnawaveService.fetchNodes();
      isPublic = false;
    }
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final savedUuid = prefs.getString('selected_node_uuid');
    setState(() {
      _nodes = nodes;
      _isPublicCatalog = isPublic;
      _subscriptionInfo = isPublic ? null : RemnawaveService.lastSubscriptionInfo;
      _isLoadingNodes = false;
      if (_selectedNode != null) {
        _selectedNode = nodes.cast<ServerNode?>()
            .firstWhere((n) => n?.uuid == _selectedNode!.uuid, orElse: () => null);
      }
      if (_selectedNode == null && savedUuid != null) {
        _selectedNode = nodes.cast<ServerNode?>()
            .firstWhere((n) => n?.uuid == savedUuid, orElse: () => null);
      }
      if (_selectedNode != null &&
          selectedServerNotifier.value?.uuid != _selectedNode!.uuid) {
        selectedServerNotifier.value = _selectedNode;
      }
    });
  }

  // ── Connection ─────────────────────────────────────────────────────────────
  Future<void> _performLogout() async => AuthService.logout();

  Future<void> _toggleConnection() async {
    if (_isTransitioning) return;
    if (_isConnected) { await _v2ray.stopVless(); return; }
    final node = _selectedNode;
    if (node == null) { _snack('Сначала выберите сервер'); return; }
    if (node.isDisabled || node.link == null) {
      if (authStateNotifier.value.isLoggedIn) {
        widget.onGoToPremium?.call();
      } else {
        await showAuthBottomSheet(context);
      }
      return;
    }
    if (!await _v2ray.requestPermission()) { _snack('Нет разрешения VPN'); return; }
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

  void _openConfigEditor(ServerNode node) {
    if (node.link == null) { _snack('Нет ссылки'); return; }
    try {
      final parser = FlutterV2ray.parseFromURL(node.link!);
      final json = const JsonEncoder.withIndent('  ')
          .convert(jsonDecode(parser.getFullConfiguration()));
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => ConfigEditorPage(configJson: json, configName: node.name),
      ));
    } catch (e) { _snack('Не удалось разобрать конфиг: $e'); }
  }

  // ── Server picker sheet ────────────────────────────────────────────────────
  void _showServerPicker() {
    String? selectedCat;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: DS.surface1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        bool hasBypass = false, hasUnlimited = false;
        for (final n in _nodes) {
          final d = (n.description ?? '').toLowerCase();
          if (d.contains('белые')) hasBypass = true;
          if (d.contains('безлимит')) hasUnlimited = true;
        }
        final showCats = !_isPublicCatalog && (hasBypass || hasUnlimited);

        List<ServerNode> visible() {
          if (selectedCat == null) return _nodes;
          return _nodes.where((n) {
            final d = (n.description ?? '').toLowerCase();
            if (selectedCat == 'bypass') return d.contains('белые');
            if (selectedCat == 'unlimited') return d.contains('безлимит');
            return !d.contains('белые') && !d.contains('безлимит');
          }).toList();
        }

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.92,
          minChildSize: 0.3,
          builder: (_, scrollCtrl) => Column(children: [
            const SizedBox(height: 12),
            Container(width: 40, height: 4,
                decoration: BoxDecoration(color: DS.border, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),

            // Sheet header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                const Expanded(child: Text('Выбрать сервер', style: TextStyle(
                    color: DS.textPrimary, fontSize: 18, fontWeight: FontWeight.w700))),
                VpnIconBtn(
                  loading: _isLoadingNodes,
                  icon: Icons.refresh_rounded,
                  onTap: () async { setSheet(() {}); await _loadNodes(); setSheet(() {}); },
                ),
              ]),
            ),

            // Public catalog warning
            if (_isPublicCatalog)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: VpnInfoBanner(
                  color: DS.amber,
                  text: 'Публичный каталог. Для подключения нужна подписка.',
                ),
              ),

            // Category chips
            if (showCats)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final e in <(String?, String)>[
                      (null, 'Все'), ('bypass', 'Обход'),
                      ('unlimited', 'Безлимит'), ('other', 'Прочее'),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _Chip(
                          label: e.$2,
                          selected: selectedCat == e.$1,
                          onTap: () => setSheet(() => selectedCat = e.$1),
                        ),
                      ),
                  ]),
                ),
              ),

            const SizedBox(height: 10),
            Divider(height: 1, color: DS.border),

            // Server list
            Expanded(
              child: _nodes.isEmpty
                  ? Center(child: _isLoadingNodes
                  ? const CircularProgressIndicator(color: DS.violet)
                  : const _EmptyNodes())
                  : Builder(builder: (_) {
                final nodes = visible();
                if (nodes.isEmpty) {
                  return const Center(child: Text('Нет серверов в этой категории',
                      style: TextStyle(color: DS.textSecondary)));
                }
                return ListView.separated(
                  controller: scrollCtrl,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: nodes.length,
                  separatorBuilder: (_, __) => Divider(height: 1, indent: 16, endIndent: 16, color: DS.border),
                  itemBuilder: (_, i) {
                    final node = nodes[i];
                    final isSel = _selectedNode?.uuid == node.uuid;
                    return Material(
                      color: isSel ? DS.violet.withValues(alpha: 0.08) : Colors.transparent,
                      child: InkWell(
                        onTap: () async {
                          if (_isPublicCatalog) {
                            Navigator.pop(ctx);
                            if (context.mounted) {
                              if (authStateNotifier.value.isLoggedIn) {
                                widget.onGoToPremium?.call();
                              } else {
                                await showAuthBottomSheet(context);
                              }
                            }
                            return;
                          }
                          setState(() => _selectedNode = node);
                          selectedServerNotifier.value = node;
                          final p = await SharedPreferences.getInstance();
                          await p.setString('selected_node_uuid', node.uuid);
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
                          child: Row(children: [
                            CountryFlag.fromCountryCode(
                              node.countryCode,
                              theme: ImageTheme(width: 36, height: 28, shape: RoundedRectangle(8)),
                            ),
                            const SizedBox(width: 14),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(node.name, style: TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 14,
                                  color: isSel ? DS.violet : DS.textPrimary),
                                  overflow: TextOverflow.ellipsis),
                              Text(node.address, style: const TextStyle(
                                  color: DS.textSecondary, fontSize: 12),
                                  overflow: TextOverflow.ellipsis),
                            ])),
                            if (isSel)
                              const Icon(Icons.check_circle_rounded, color: DS.violet, size: 20)
                            else if (_isPublicCatalog)
                              const Icon(Icons.lock_outline_rounded, size: 16, color: DS.textMuted),
                          ]),
                        ),
                      ),
                    );
                  },
                );
              }),
            ),
          ]),
        );
      }),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
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

  String _fmtBytes(int b) {
    if (b < 1024) return '${b}B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }

  String _fmtDuration(int sec) {
    final h = sec ~/ 3600, m = (sec % 3600) ~/ 60, s = sec % 60;
    if (h > 0) return '${h}ч ${m.toString().padLeft(2, '0')}м';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Color _progressColor(double f) {
    if (f < 0.6) return DS.emerald;
    if (f < 0.85) return DS.amber;
    return DS.rose;
  }

  String _remaining(SubscriptionInfo info) {
    if (info.totalBytes <= 0) return '∞';
    final rem = info.totalBytes - info.usedBytes;
    if (rem <= 0) return '0 ГБ';
    return SubscriptionInfo(uploadBytes: 0, downloadBytes: rem, totalBytes: info.totalBytes).formattedUsed;
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Scaffold(
        backgroundColor: DS.surface0,
        body: Center(child: CircularProgressIndicator(color: DS.violet)),
      );
    }
    return Scaffold(
      backgroundColor: DS.surface0,
      body: RefreshIndicator(
        color: DS.violet,
        backgroundColor: DS.surface2,
        onRefresh: _refreshAll,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                  16, MediaQuery.of(context).padding.top + 20, 16, 120),
              sliver: SliverList(delegate: SliverChildListDelegate([
                _buildHeader(),
                const SizedBox(height: 20),
                _buildConnectionCard(),
                const SizedBox(height: 12),
                _buildSpeedCard(),
                const SizedBox(height: 12),
                _buildSubscriptionCard(),
              ])),
            ),
          ],
        ),
      ),
    );
  }

  // ── Header ─────────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Ulya VPN', style: TextStyle(
              color: DS.textPrimary, fontSize: 32,
              fontWeight: FontWeight.w800, letterSpacing: -0.5, height: 1,
            )),
            const SizedBox(height: 6),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Text(
                key: ValueKey(_isConnected),
                _isConnected ? 'Соединение защищено' : 'Свобода начинается с приватности',
                style: const TextStyle(color: DS.textSecondary, fontSize: 15),
              ),
            ),
          ]),
        ),
        VpnIconBtn(
          loading: _isLoadingNodes,
          icon: Icons.refresh_rounded,
          onTap: _isLoadingNodes ? null : _refreshAll,
        ),
      ],
    );
  }

  // ── Connection card ────────────────────────────────────────────────────────
  Widget _buildConnectionCard() {
    final connected = _isConnected;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radius),
        border: Border.all(
          color: connected ? DS.violet.withValues(alpha: 0.45) : DS.border,
          width: connected ? 1.5 : 1,
        ),
        boxShadow: connected
            ? [BoxShadow(color: DS.violet.withValues(alpha: 0.18),
            blurRadius: 36, spreadRadius: -8)]
            : [BoxShadow(color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 20, offset: const Offset(0, 6))],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
        child: Column(children: [
          // Status text
          Column(children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(key: ValueKey(_statusLabel), _statusLabel,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700,
                      color: DS.textPrimary, letterSpacing: 0.1)),
            ),
            const SizedBox(height: 5),
            Text(
              connected
                  ? 'Сессия: ${_fmtDuration(_status.duration)}'
                  : 'Выберите сервер и нажмите подключить',
              style: const TextStyle(fontSize: 13, color: DS.textSecondary),
            ),
          ]),

          const SizedBox(height: 24),
          _ConnectButton(
            isConnected: connected,
            isLoading: _isTransitioning,
            onTap: _toggleConnection,
          ),
          const SizedBox(height: 22),

          // Separator
          Container(height: 1, decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [Colors.transparent, DS.border, Colors.transparent]))),
          const SizedBox(height: 14),

          // Server selector
          GestureDetector(
            onTap: _showServerPicker,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: DS.surface2,
                borderRadius: BorderRadius.circular(DS.radiusSm),
                border: Border.all(color: DS.border),
              ),
              child: Row(children: [
                if (_selectedNode != null && _selectedNode!.countryCode.isNotEmpty)
                  CountryFlag.fromCountryCode(
                    _selectedNode!.countryCode,
                    theme: const ImageTheme(
                      width: 36,
                      height: 28,
                      shape: RoundedRectangle(8),
                    ),
                  )
                else
                // Если нет выбранного сервера или кода страны, показываем иконку глобуса
                  Container(
                    width: 36,
                    height: 28,
                    decoration: BoxDecoration(
                      color: DS.violet.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.public_rounded,
                      color: DS.violet,
                      size: 18,
                    ),
                  ),

                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    _selectedNode?.name ?? 'Выберите сервер',
                    style: TextStyle(
                        color: _selectedNode != null ? DS.textPrimary : DS.violet,
                        fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  if (_selectedNode != null)
                    Text(_selectedNode!.address,
                        style: const TextStyle(color: DS.textSecondary, fontSize: 12)),
                ])),
                const Icon(Icons.chevron_right_rounded, color: DS.violet, size: 20),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  // ── Speed card ─────────────────────────────────────────────────────────────
  Widget _buildSpeedCard() {
    final upActive = _speedCalc.uploadSpeed > 1024;
    final downActive = _speedCalc.downloadSpeed > 1024;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radius),
        border: Border.all(color: DS.border),
      ),
      child: Row(children: [
        Expanded(child: _SpeedTile(
          icon: Icons.arrow_upward_rounded,
          label: 'Отдача',
          speed: _speedCalc.uploadSpeed,
          total: _fmtBytes(_status.uploadSpeed),
          color: upActive ? DS.violet : DS.textMuted,
        )),
        Container(width: 1, height: 52, decoration: const BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topCenter, end: Alignment.bottomCenter,
                colors: [Colors.transparent, DS.border, Colors.transparent]))),
        Expanded(child: _SpeedTile(
          icon: Icons.arrow_downward_rounded,
          label: 'Загрузка',
          speed: _speedCalc.downloadSpeed,
          total: _fmtBytes(_status.download),
          color: downActive ? DS.emerald : DS.textMuted,
        )),
      ]),
    );
  }

  // ── Subscription card ──────────────────────────────────────────────────────
  Widget _buildSubscriptionCard() {
    final info = _subscriptionInfo;
    final authState = authStateNotifier.value;
    final sub = meNotifier.value?.subscription;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radius),
        border: Border.all(color: DS.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header row
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('ПОДПИСКА', style: TextStyle(
              color: DS.textMuted, fontSize: 11,
              fontWeight: FontWeight.w700, letterSpacing: 1.2)),
          if (sub != null) _SubBadge(sub: sub)
          else if (info?.expireDate != null) _ExpiryBadge(expireDate: info!.expireDate!),
        ]),

        // Auth user strip
        if (authState.isLoggedIn) ...[
          const SizedBox(height: 12),
          _TelegramStrip(
            name: authState.displayName,
            onLogout: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Выйти из аккаунта?'),
                  content: const Text(
                      'Данные подписки будут удалены с устройства.',
                      style: TextStyle(color: DS.textSecondary)),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Отмена')),
                    TextButton(onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Выйти',
                            style: TextStyle(color: DS.rose))),
                  ],
                ),
              );
              if (ok == true && mounted) await _performLogout();
            },
          ),
        ],

        const SizedBox(height: 16),

        // Content
        if (info == null && !_isPublicCatalog)
          const Center(child: Text('Загрузка данных…',
              style: TextStyle(color: DS.textSecondary, fontSize: 13)))
        else if (_isPublicCatalog && !authState.isLoggedIn)
          _LoginPrompt()
        else if (info != null) ...[
            // Big traffic numbers
            Row(crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic, children: [
                  Text(info.formattedUsed, style: const TextStyle(
                      color: DS.textPrimary, fontSize: 28, fontWeight: FontWeight.w800, height: 1)),
                  const SizedBox(width: 6),
                  Text('/ ${info.formattedTotal}',
                      style: const TextStyle(color: DS.textMuted, fontSize: 15)),
                ]),
            const SizedBox(height: 12),

            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Stack(children: [
                Container(height: 6, color: DS.surface3),
                FractionallySizedBox(
                  widthFactor: info.usedFraction.clamp(0.0, 1.0),
                  child: Container(height: 6,
                      decoration: BoxDecoration(
                        color: _progressColor(info.usedFraction),
                        boxShadow: [BoxShadow(
                            color: _progressColor(info.usedFraction).withValues(alpha: 0.5),
                            blurRadius: 8)],
                      )),
                ),
              ]),
            ),
            const SizedBox(height: 10),

            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Осталось: ${_remaining(info)}',
                  style: const TextStyle(color: DS.textSecondary, fontSize: 12)),
              Text('${(info.usedFraction * 100).toStringAsFixed(1)}%', style: TextStyle(
                  color: _progressColor(info.usedFraction),
                  fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
          ],
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Local widgets
// ─────────────────────────────────────────────────────────────────────────────

class _ConnectButton extends StatelessWidget {
  final bool isConnected;
  final bool isLoading;
  final VoidCallback onTap;
  const _ConnectButton({required this.isConnected, required this.isLoading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = isConnected ? DS.rose : DS.violet;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      width: 220, height: 56,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color, Color.lerp(color, Colors.black, 0.3)!],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(DS.radius),
        boxShadow: [BoxShadow(
            color: color.withValues(alpha: 0.35),
            blurRadius: 20, offset: const Offset(0, 6))],
      ),
      child: Material(color: Colors.transparent,
        child: InkWell(
          onTap: isLoading ? null : onTap,
          borderRadius: BorderRadius.circular(DS.radius),
          child: Center(
            child: isLoading
                ? const SizedBox(width: 22, height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : Text(isConnected ? 'Отключить' : 'Подключить',
                style: const TextStyle(color: Colors.white, fontSize: 16,
                    fontWeight: FontWeight.w700, letterSpacing: 0.3)),
          ),
        ),
      ),
    );
  }
}

class _SpeedTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final double speed;
  final String total;
  final Color color;
  const _SpeedTile({required this.icon, required this.label, required this.speed,
    required this.total, required this.color});

  String _fmt(double bps) {
    if (bps < 1024) return '${bps.toStringAsFixed(0)} B/s';
    if (bps < 1024 * 1024) return '${(bps / 1024).toStringAsFixed(1)} KB/s';
    return '${(bps / (1024 * 1024)).toStringAsFixed(2)} MB/s';
  }

  @override
  Widget build(BuildContext context) => Column(children: [
    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(icon, color: color, size: 13),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(color: DS.textSecondary, fontSize: 11)),
    ]),
    const SizedBox(height: 6),
    TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: speed),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      builder: (_, v, __) => Text(_fmt(v), style: TextStyle(
          color: color, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 0.2)),
    ),
    const SizedBox(height: 3),
    Text(total, style: const TextStyle(color: DS.textMuted, fontSize: 11)),
  ]);
}

class _TelegramStrip extends StatelessWidget {
  final String name;
  final VoidCallback onLogout;
  const _TelegramStrip({required this.name, required this.onLogout});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(
      color: DS.telegramBlue.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(DS.radiusXs),
      border: Border.all(color: DS.telegramBlue.withValues(alpha: 0.2)),
    ),
    child: Row(children: [
      const Icon(Icons.telegram, color: DS.telegramBlue, size: 15),
      const SizedBox(width: 8),
      Expanded(child: Text(name, style: const TextStyle(
          color: DS.textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
          overflow: TextOverflow.ellipsis)),
      GestureDetector(
          onTap: onLogout,
          child: const Icon(Icons.logout_rounded, size: 16, color: DS.textMuted)),
    ]),
  );
}

class _LoginPrompt extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Column(children: [
    const Text('Войдите через Telegram, чтобы активировать подписку.',
        style: TextStyle(color: DS.textSecondary, fontSize: 13, height: 1.5)),
    const SizedBox(height: 12),
    TelegramLoginButton(onTap: () => showAuthBottomSheet(context)),
  ]);
}

class _SubBadge extends StatelessWidget {
  final MeSubscription sub;
  const _SubBadge({required this.sub});

  @override
  Widget build(BuildContext context) {
    Color color; String label; IconData icon;
    if (sub.isActive) {
      if (sub.isTrial) {
        color = DS.amber; label = 'Пробный'; icon = Icons.hourglass_top_rounded;
      } else {
        final diff = sub.expireDate?.difference(DateTime.now());
        if (diff != null && diff.inDays < 7 && !diff.isNegative) {
          color = DS.amber; label = '${diff.inDays}д'; icon = Icons.timer_outlined;
        } else {
          color = DS.emerald; label = 'Активна'; icon = Icons.verified_rounded;
        }
      }
    } else if (sub.isExpired) {
      color = DS.rose; label = 'Истекла'; icon = Icons.timer_off_rounded;
    } else {
      color = DS.textMuted; label = sub.status; icon = Icons.info_outline_rounded;
    }
    return _StatusPill(color: color, label: label, icon: icon);
  }
}

class _ExpiryBadge extends StatelessWidget {
  final DateTime expireDate;
  const _ExpiryBadge({required this.expireDate});

  @override
  Widget build(BuildContext context) {
    final diff = expireDate.difference(DateTime.now());
    final expired = diff.isNegative;
    final soon = !expired && diff.inDays < 7;
    final color = expired ? DS.rose : soon ? DS.amber : DS.emerald;
    final label = expired ? 'Истекла' : diff.inDays > 0 ? '${diff.inDays}д' : '< 1д';
    return _StatusPill(
        color: color, label: label,
        icon: expired ? Icons.timer_off_rounded : Icons.timer_outlined);
  }
}

class _StatusPill extends StatelessWidget {
  final Color color; final String label; final IconData icon;
  const _StatusPill({required this.color, required this.label, required this.icon});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: 0.3)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: color, size: 12),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
    ]),
  );
}

// ── Shared micro-widgets ──────────────────────────────────────────────────────

class VpnIconBtn extends StatelessWidget {
  final bool loading;
  final IconData icon;
  final VoidCallback? onTap;
  const VpnIconBtn({required this.loading, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 42, height: 42,
      decoration: BoxDecoration(
        color: DS.surface2,
        borderRadius: BorderRadius.circular(DS.radiusSm),
        border: Border.all(color: DS.border),
      ),
      child: loading
          ? const Center(child: SizedBox(width: 18, height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: DS.violet)))
          : Icon(icon, color: DS.textSecondary, size: 20),
    ),
  );
}

class _Chip extends StatelessWidget {
  final String label; final bool selected; final VoidCallback onTap;
  const _Chip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: selected ? DS.violet.withValues(alpha: 0.15) : DS.surface2,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: selected ? DS.violet : DS.border),
      ),
      child: Text(label, style: TextStyle(
          color: selected ? DS.violet : DS.textSecondary,
          fontSize: 12, fontWeight: FontWeight.w600)),
    ),
  );
}

class VpnInfoBanner extends StatelessWidget {
  final Color color; final String text;
  const VpnInfoBanner({required this.color, required this.text});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(DS.radiusSm),
      border: Border.all(color: color.withValues(alpha: 0.25)),
    ),
    child: Row(children: [
      Icon(Icons.info_outline_rounded, size: 15, color: color.withValues(alpha: 0.85)),
      const SizedBox(width: 10),
      Expanded(child: Text(text, style: TextStyle(color: color.withValues(alpha: 0.9), fontSize: 12))),
    ]),
  );
}

class _EmptyNodes extends StatelessWidget {
  const _EmptyNodes();

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.cloud_off_rounded, size: 40, color: DS.textMuted),
    const SizedBox(height: 10),
    const Text('Серверы не найдены',
        style: TextStyle(color: DS.textSecondary, fontSize: 14)),
  ]);
}
