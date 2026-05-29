import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter_v2ray_plus/flutter_v2ray.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/me_response.dart';
import '../models/server_node.dart';
import '../models/subscription_info.dart';
import '../config/app_config.dart';
import '../services/app_logger.dart';
import '../services/auth_service.dart';
import '../services/auth_state.dart';
import '../services/me_service.dart';
import '../services/remnawave_service.dart';
import '../services/selected_server_state.dart';
import '../utils/speed_calculator.dart';
import '../widgets/telegram_login_button.dart';
import 'auth_bottom_sheet.dart';
import 'subscription_page.dart';
import 'support_page.dart';
import '../main.dart' show DS;

class HomePage extends StatefulWidget {
  final VoidCallback? onGoToPremium;

  const HomePage({super.key, this.onGoToPremium});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const List<String> _bypassKeywords = [
    'белые',
    'обход',
    'bypass',
    'лте',
    'lte',
  ];
  // Multi-token signatures where all tokens must be present in description.
  static const List<List<String>> _bypassKeywordCombos = [
    ['yt', 'tg'],
  ];
  static const int _defaultServerPort = 443;
  static const Duration _nodeReachabilityTimeout = Duration(seconds: 1);
  static const int _maxReachabilityWorkers = 4;

  // ── V2ray ──────────────────────────────────────────────────────────────────
  late final FlutterV2ray _v2ray;
  VlessStatus _status = VlessStatus();
  StreamSubscription<VlessStatus>? _statusSub;

  // ── Nodes ──────────────────────────────────────────────────────────────────
  List<ServerNode> _nodes = [];
  ServerNode? _selectedNode;
  bool _isLoadingNodes  = false;
  bool _pendingLoad     = false;   // set when a load is requested while one is running
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

  // ── Lifecycle ──────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    selectedServerNotifier.addListener(_onSelectedServerChanged);
    authStateNotifier.addListener(_onAuthChanged);
    meNotifier.addListener(_onMeChanged);
    globalRefreshNotifier.addListener(_onGlobalRefresh);
    _speedCalc = SpeedCalculator(smoothing: 0.25);
    _v2ray = FlutterV2ray();
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Reset speed calculator to prevent stale delta causing unrealistic values
      _speedCalc.reset();
      _refreshAll();
      // Re-subscribe to VPN status to catch any state changes that happened
      // while the app was in the background (e.g. user disconnected via
      // the system VPN notification).
      _resubscribeVpnStatus();
    }
  }

  void _resubscribeVpnStatus() {
    // Cancel the old subscription and re-attach so the plugin sends the
    // current real state immediately rather than waiting for the next change.
    _statusSub?.cancel();
    _statusSub = _v2ray.onStatusChanged.listen((s) {
      if (!mounted) return;
      final connected = s.state.toUpperCase() == 'CONNECTED';
      vpnConnectedNotifier.value = connected;
      if (connected) {
        _speedCalc.update(totalUploadBytes: s.upload, totalDownloadBytes: s.download);
      } else {
        _speedCalc.reset();
      }
      setState(() => _status = s);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    selectedServerNotifier.removeListener(_onSelectedServerChanged);
    authStateNotifier.removeListener(_onAuthChanged);
    meNotifier.removeListener(_onMeChanged);
    globalRefreshNotifier.removeListener(_onGlobalRefresh);
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

  /// Called when another page triggers a global refresh.  Update traffic/subscription
  /// info from the already-refreshed [RemnawaveService.lastSubscriptionInfo] cache.
  void _onGlobalRefresh() {
    if (!mounted) return;
    // Only update the subscription/traffic info from cache — do not touch
    // _isLoadingNodes to avoid conflicting with any in-progress _loadNodes call.
    setState(() {
      _subscriptionInfo = RemnawaveService.lastSubscriptionInfo;
    });
  }

  // ── Init ───────────────────────────────────────────────────────────────────
  Future<void> _init() async {
    // Pre-populate /me from cache so subscription card renders immediately,
    // before any network call completes.
    await MeService.loadFromCache();

    await _v2ray.initializeVless(
      notificationIconResourceType: 'mipmap',
      notificationIconResourceName: 'ic_launcher',
    );
    // Use the same subscription setup as _resubscribeVpnStatus so that
    // _persistTileState is always called on state changes.
    _resubscribeVpnStatus();
    if (mounted) setState(() => _initialized = true);
    _loadNodes();
  }

  // ── Data ───────────────────────────────────────────────────────────────────
  Future<void> _refreshAll() async {
    await MeService.refreshAll();
    await _loadNodes();
  }

  Future<void> _loadNodes() async {
    if (!mounted) return;
    // Guard: if already loading, mark as pending so we run once more after.
    if (_isLoadingNodes) { _pendingLoad = true; return; }
    _pendingLoad = false;
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
    // If a load was requested while we were busy, run it now once.
    if (_pendingLoad && mounted) {
      _pendingLoad = false;
      _loadNodes();
    }
  }

  // ── Connection ─────────────────────────────────────────────────────────────
  Future<void> _performLogout() async => AuthService.logout();

  Future<List<String>> _loadBlockedApps() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('settings_blocked_apps');
    if (raw != null) {
      try {
        return List<String>.from((jsonDecode(raw) as List).whereType<String>());
      } catch (e) {
        appLogger.error(
          'HomePage',
          'failed to parse blocked apps setting: $e',
        );
      }
    }
    return List<String>.from(AppConfig.defaultBlockedApps);
  }

  static bool _isBypassDescription(String? description) {
    final hay = (description ?? '').toLowerCase();
    return _bypassKeywords.any(hay.contains) ||
        _bypassKeywordCombos.any((combo) => combo.every(hay.contains));
  }

  static bool _isBypassNode(ServerNode node) => _isBypassDescription(node.description);

  Future<bool> _canReachNode(ServerNode node) async {
    final host = node.address.trim();
    if (host.isEmpty) return false;
    // Default to HTTPS port if backend did not provide an explicit one.
    final port = node.serverPort > 0 ? node.serverPort : _defaultServerPort;
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: _nodeReachabilityTimeout,
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _hasReachableNonBypassServer() async {
    final candidates = _nodes.where((n) =>
        n.protocol != 'auto' &&
        !_isBypassNode(n) &&
        n.link != null &&
        !n.isDisabled).toList();
    if (candidates.any((server) => server.isAvailable)) return true;
    if (candidates.isEmpty) return false;
    for (var i = 0; i < candidates.length; i += _maxReachabilityWorkers) {
      final end = (i + _maxReachabilityWorkers < candidates.length)
          ? i + _maxReachabilityWorkers
          : candidates.length;
      final batch = candidates.sublist(i, end);
      final checks = await Future.wait(batch.map(_canReachNode));
      if (checks.any((ok) => ok)) return true;
    }
    return false;
  }

  Future<void> _toggleConnection() async {
    if (_isTransitioning) return;
    if (_isConnected) {
      appLogger.info('HomePage', 'disconnecting from ${_selectedNode?.name ?? "unknown"}');
      await _v2ray.stopVless();
      return;
    }
    final node = _selectedNode;
    if (node == null) { _snack('Сначала выберите сервер'); return; }
    if (node.isDisabled || node.link == null) {
      if (authStateNotifier.value.isLoggedIn) {
        appLogger.info('HomePage', 'blocked server tapped — redirecting to premium');
        widget.onGoToPremium?.call();
      } else {
        await showAuthBottomSheet(context);
      }
      return;
    }
    if (_isBypassNode(node) && await _hasReachableNonBypassServer()) {
      appLogger.info(
        'HomePage',
        'bypass connection blocked: reachable non-bypass server detected',
      );
      _snack('Сервер обхода заблокирован: используйте обычные серверы');
      return;
    }
    if (!await _v2ray.requestPermission()) { _snack('Нет разрешения VPN'); return; }
    setState(() => _isConnecting = true);
    appLogger.info('HomePage', 'connecting to ${node.name} (${node.countryCode})');
    try {
      // Support both full Xray JSON configs (Remnawave JSON-array subscription)
      // and legacy vless:// / vmess:// / trojan:// URI links.
      final rawLink = node.link!.trim();
      final String vpnConfig;
      if (rawLink.startsWith('{')) {
        vpnConfig = rawLink;
      } else {
        vpnConfig = FlutterV2ray.parseFromURL(rawLink).getFullConfiguration();
      }
      appLogger.info('HomePage',
          'connecting: type=${rawLink.startsWith('{') ? 'JSON' : 'URI'} '
          'addr=${node.address}:${node.serverPort}');
      final blockedApps = await _loadBlockedApps();

      await _v2ray.startVless(
        remark: node.name,
        config: vpnConfig,
        blockedApps: blockedApps,
        notificationDisconnectButtonName: 'Отключить',
      );
    } catch (e) {
      appLogger.error('HomePage', 'connection error: $e');
      _snack('Ошибка подключения: $e');
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  // ── Server picker helpers ──────────────────────────────────────────────────

  /// Splits nodes into auto/manual and sorts each group.
  /// Manual nodes: primary sort = country code (keeps same-country servers
  /// together), secondary = availability, tertiary = name.
  /// Auto nodes: alphabetical by name.
  ({List<ServerNode> auto, List<ServerNode> manual})
      _splitAndSort(List<ServerNode> nodes) {
    final auto   = nodes.where((n) => n.protocol == 'auto').toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final manual = nodes.where((n) => n.protocol != 'auto').toList()
      ..sort((a, b) {
        // Keep countries grouped — ping is NOT a cross-country key.
        final cc = a.countryCode.compareTo(b.countryCode);
        if (cc != 0) return cc;
        // Within same country: available first, then name.
        final aOk = a.isAvailable ? 0 : 1;
        final bOk = b.isAvailable ? 0 : 1;
        if (aOk != bOk) return aOk.compareTo(bOk);
        return a.name.compareTo(b.name);
      });
    return (auto: auto, manual: manual);
  }

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
        // Detect which manual categories exist (for filter chips)
        bool hasBypass = false, hasUnlimited = false;
        for (final n in _nodes) {
          final d = (n.description ?? '').toLowerCase();
          if (d.contains('белые')) hasBypass = true;
          if (d.contains('безлимит')) hasUnlimited = true;
        }
        final showCats = !_isPublicCatalog && (hasBypass || hasUnlimited);

        // Split and sort
        final (:auto, :manual) = _splitAndSort(_nodes);

        // Apply category filter to manual nodes only.
        // Auto-select is hidden while a sub-category filter is active.
        final List<ServerNode> filteredManual;
        if (selectedCat == null) {
          filteredManual = manual;
        } else {
          filteredManual = manual.where((n) {
            final d = (n.description ?? '').toLowerCase();
            if (selectedCat == 'bypass')   return d.contains('белые');
            if (selectedCat == 'unlimited') return d.contains('безлимит');
            return !d.contains('белые') && !d.contains('безлимит');
          }).toList();
        }

        final showAuto = selectedCat == null && auto.isNotEmpty && !_isPublicCatalog;
        final int autoCount     = showAuto ? auto.length : 0;
        final int dividerCount  = (showAuto && filteredManual.isNotEmpty) ? 1 : 0;
        final int total         = autoCount + dividerCount + filteredManual.length;

        // ── Tile builder ──────────────────────────────────────────────────────
        Widget buildTile(ServerNode node, {required bool isAutoNode}) {
          final isSel    = _selectedNode?.uuid == node.uuid;
          final locked   = _isPublicCatalog || node.isDisabled || node.link == null;
          final nameColor = isSel ? DS.violet : DS.textPrimary;

          return Material(
            color: isSel
                ? (isAutoNode
                    ? DS.indigoLight.withValues(alpha: 0.09)
                    : DS.violet.withValues(alpha: 0.08))
                : Colors.transparent,
            child: InkWell(
              onTap: () async {
                if (locked) {
                  Navigator.pop(ctx);
                  if (context.mounted) {
                    authStateNotifier.value.isLoggedIn
                        ? widget.onGoToPremium?.call()
                        : await showAuthBottomSheet(context);
                  }
                  return;
                }
                setState(() => _selectedNode = node);
                selectedServerNotifier.value = node;
                final p = await SharedPreferences.getInstance();
                await p.setString('selected_node_uuid', node.uuid);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              splashColor: (isAutoNode ? DS.indigoLight : DS.violet)
                  .withValues(alpha: 0.08),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
                child: Row(children: [
                  // Flag or auto icon
                  if (isAutoNode || node.countryCode.isEmpty)
                    Container(
                      width: 36, height: 28,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF1E1B4B), Color(0xFF1A1760)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                            color: DS.indigoLight.withValues(alpha: 0.40)),
                      ),
                      child: const Icon(Icons.bolt_rounded,
                          size: 18, color: DS.indigoLight),
                    )
                  else
                    CountryFlag.fromCountryCode(
                      node.countryCode,
                      theme: ImageTheme(
                          width: 36, height: 28, shape: RoundedRectangle(8)),
                    ),
                  const SizedBox(width: 14),
                  // Name + protocol
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(node.name,
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color: nameColor),
                          overflow: TextOverflow.ellipsis),
                      if ((node.protocol ?? '').isNotEmpty)
                        Text(
                          isAutoNode ? 'Авто-выбор' : node.protocol!.toUpperCase(),
                          style: TextStyle(
                              color: isAutoNode
                                  ? DS.indigoLight.withValues(alpha: 0.80)
                                  : DS.textSecondary,
                              fontSize: 12),
                        ),
                    ],
                  )),
                  // Trailing
                  if (isSel)
                    Icon(Icons.check_circle_rounded,
                        color: isAutoNode ? DS.indigoLight : DS.violet,
                        size: 20)
                  else if (locked)
                    const Icon(Icons.lock_outline_rounded,
                        size: 16, color: DS.textMuted),
                ]),
              ),
            ),
          );
        }

        // ── Section divider row ───────────────────────────────────────────────
        Widget buildManualDivider() => Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
          child: Row(children: [
            Expanded(child: Container(height: 1, color: DS.border)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'СЕРВЕРЫ',
                style: TextStyle(
                  color: DS.textMuted.withValues(alpha: 0.70),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                ),
              ),
            ),
            Expanded(child: Container(height: 1, color: DS.border)),
          ]),
        );

        // ─────────────────────────────────────────────────────────────────────
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.92,
          minChildSize: 0.3,
          builder: (_, scrollCtrl) => Column(children: [
            const SizedBox(height: 12),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                  color: DS.border, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 16),

            // Sheet header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                const Expanded(child: Text('Выбрать сервер', style: TextStyle(
                    color: DS.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700))),
                VpnIconBtn(
                  loading: _isLoadingNodes,
                  icon: Icons.refresh_rounded,
                  onTap: () async {
                    setSheet(() {});
                    await _loadNodes();
                    setSheet(() {});
                  },
                ),
              ]),
            ),

            // Public catalog banner
            if (_isPublicCatalog)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: VpnInfoBanner(
                  color: DS.amber,
                  text: 'Публичный каталог. Для подключения нужна подписка.',
                ),
              ),

            // Category filter chips (manual categories only)
            if (showCats)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final e in <(String?, String)>[
                      (null, 'Все'),
                      if (hasBypass)   ('bypass', 'Обход'),
                      if (hasUnlimited) ('unlimited', 'Безлимит'),
                      ('other', 'Прочее'),
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
                  ? Center(
                      child: _isLoadingNodes
                          ? const CircularProgressIndicator(color: DS.violet)
                          : const _EmptyNodes())
                  : total == 0
                      ? const Center(
                          child: Text('Нет серверов в этой категории',
                              style: TextStyle(color: DS.textSecondary)))
                      : ListView.separated(
                          controller: scrollCtrl,
                          padding: const EdgeInsets.only(bottom: 16),
                          itemCount: total,
                          separatorBuilder: (_, i) {
                            // No hairline separator adjacent to the section
                            // divider row — it provides its own spacing.
                            if (dividerCount > 0 &&
                                (i == autoCount - 1 || i == autoCount)) {
                              return const SizedBox.shrink();
                            }
                            return Divider(
                                height: 1,
                                indent: 16,
                                endIndent: 16,
                                color: DS.border);
                          },
                          itemBuilder: (_, i) {
                            if (showAuto && i < autoCount) {
                              return buildTile(auto[i], isAutoNode: true);
                            }
                            if (dividerCount > 0 && i == autoCount) {
                              return buildManualDivider();
                            }
                            final mi = i - autoCount - dividerCount;
                            return buildTile(filteredManual[mi],
                                isAutoNode: false);
                          },
                        ),
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

  String _fmtBytes(int b) {
    if (b < 0) b = 0;
    if (b < 1024) return '${b}B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }

  String _fmtDuration(int sec) {
    final h = sec ~/ 3600, m = (sec % 3600) ~/ 60, s = sec % 60;
    if (h > 0) return '$hч ${m.toString().padLeft(2, '0')}м';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Color _progressColor(double f) {
    if (f < 0.6) return DS.emerald;
    if (f < 0.85) return DS.amber;
    return DS.rose;
  }

  static String _formatExpiry(DateTime dt) {
    const months = [
      'янв.', 'фев.', 'мар.', 'апр.', 'мая', 'июн.',
      'июл.', 'авг.', 'сен.', 'окт.', 'ноя.', 'дек.',
    ];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
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
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                  16, MediaQuery.of(context).padding.top + 12, 16, 120),
              sliver: SliverList(delegate: SliverChildListDelegate([
                _buildHeader(),
                const SizedBox(height: 14),
                _buildConnectionCard(),
                const SizedBox(height: 12),
                // Speed card появляется только при подключении, прилетая сверху
                AnimatedSize(
                  duration: const Duration(milliseconds: 380),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: _isConnected
                      ? Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _SpeedCardFlyIn(
                            uploadSpeed: _speedCalc.uploadSpeed,
                            downloadSpeed: _speedCalc.downloadSpeed,
                            uploadTotal: _fmtBytes(_status.uploadSpeed),
                            downloadTotal: _fmtBytes(_status.download),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                _buildSubscriptionCard(),
              ])),
            ),
          ],
        ),
        ),
      ),
    );
  }

  // ── Header ─────────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text('Ulya VPN', style: const TextStyle(
            color: DS.textPrimary,
            fontSize: 28,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
            height: 1,
          )),
        ),
        VpnIconBtn(
          loading: false,
          icon: Icons.support_agent_rounded,
          onTap: _openSupportPage,
        ),
        const SizedBox(width: 8),
        VpnIconBtn(
          loading: _isLoadingNodes,
          icon: Icons.refresh_rounded,
          onTap: _isLoadingNodes ? null : _refreshAll,
        ),
      ],
    );
  }

  void _openSupportPage() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => const SupportPage()));
  }

  // ── Connection card ────────────────────────────────────────────────────────
  Widget _buildConnectionCard() {
    final connected = _isConnected;
    final transitioning = _isTransitioning;

    final String statusSub;
    if (connected) {
      statusSub = 'Сессия: ${_fmtDuration(_status.duration)} · IP скрыт';
    } else if (transitioning) {
      statusSub = 'Устанавливаем соединение…';
    } else {
      statusSub = 'Ваш IP виден сайтам';
    }

    final borderColor = connected
        ? DS.emerald.withValues(alpha: 0.38)
        : transitioning
            ? DS.amber.withValues(alpha: 0.28)
            : DS.border;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radius),
        border: Border.all(color: borderColor, width: connected ? 1.5 : 1.0),
        boxShadow: connected
            ? [BoxShadow(
                color: DS.emerald.withValues(alpha: 0.12),
                blurRadius: 32, spreadRadius: -4)]
            : [BoxShadow(
                color: Colors.black.withValues(alpha: 0.20),
                blurRadius: 16, offset: const Offset(0, 4))],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(children: [
          // Статус / время сессии
          if (connected)
            // При активном соединении — только таймер «тикает» слайдом вверх,
            // а префикс/суффикс остаются на месте (не моргают)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Сессия: ',
                    style: TextStyle(fontSize: 13, color: DS.textSecondary)),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 320),
                  transitionBuilder: (child, anim) => SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.6),
                      end: Offset.zero,
                    ).animate(CurvedAnimation(
                        parent: anim, curve: Curves.easeOutCubic)),
                    child: FadeTransition(
                        opacity: CurvedAnimation(
                            parent: anim, curve: Curves.easeOut),
                        child: child),
                  ),
                  child: Text(
                    key: ValueKey(_fmtDuration(_status.duration)),
                    _fmtDuration(_status.duration),
                    style: const TextStyle(
                        fontSize: 13,
                        color: DS.textSecondary,
                        fontVariations: [FontVariation('wght', 600)]),
                  ),
                ),
                const Text(' · IP скрыт',
                    style: TextStyle(fontSize: 13, color: DS.textSecondary)),
              ],
            )
          else
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                key: ValueKey(statusSub),
                statusSub,
                style: const TextStyle(fontSize: 13, color: DS.textSecondary),
              ),
            ),

          const SizedBox(height: 18),

          // Big circle button
          _ConnectButton(
            isConnected: connected,
            isLoading: transitioning,
            onTap: _toggleConnection,
          ),

          const SizedBox(height: 18),

          // Gradient separator
          Container(
            height: 1,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.transparent, DS.border, Colors.transparent],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Server selector
          GestureDetector(
            onTap: _showServerPicker,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
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
                        width: 36, height: 26, shape: RoundedRectangle(6)),
                  )
                else
                  Container(
                    width: 36, height: 26,
                    decoration: BoxDecoration(
                      color: DS.violet.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Icons.public_rounded, color: DS.violet, size: 16),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      _selectedNode?.name ?? 'Выберите сервер',
                      style: TextStyle(
                        color: _selectedNode != null ? DS.textPrimary : DS.violet,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    if (_selectedNode != null &&
                        (_selectedNode!.protocol ?? '').isNotEmpty)
                      Text(
                        _selectedNode!.protocol!.toUpperCase(),
                        style: const TextStyle(color: DS.textSecondary, fontSize: 12),
                      ),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded, color: DS.textMuted, size: 20),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  // ── Subscription card ──────────────────────────────────────────────────────
  Widget _buildSubscriptionCard() {
    final info      = _subscriptionInfo;
    final authState = authStateNotifier.value;
    final sub       = meNotifier.value?.subscription;

    // Whether the card header is navigable to SubscriptionPage
    final canOpenDetails = authState.isLoggedIn && (info != null || sub != null);

    void openDetails() {
      if (!canOpenDetails) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SubscriptionPage(onGoToPremium: widget.onGoToPremium),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radius),
        border: Border.all(color: DS.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
          child: Row(children: [
            const Text('ПОДПИСКА', style: TextStyle(
              color: DS.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            )),
            const Spacer(),
            if (sub != null) _SubBadge(sub: sub)
            else if (info?.expireDate != null) _ExpiryBadge(expireDate: info!.expireDate!),
          ]),
        ),

        // Body
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Telegram user strip
            if (authState.isLoggedIn) ...[
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
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Отмена')),
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Выйти',
                                style: TextStyle(color: DS.rose))),
                      ],
                    ),
                  );
                  if (ok == true && mounted) await _performLogout();
                },
              ),
              const SizedBox(height: 14),
            ],

            // Content
            if (info == null && !_isPublicCatalog) ...[
              if (!authState.isLoggedIn)
                _LoginPrompt()
              else if (sub != null &&
                  (sub.expireDate?.isBefore(DateTime.now()) ?? false)) ...[
                Text(
                  sub.expireDate != null
                      ? 'Истекла ${_formatExpiry(sub.expireDate!)}'
                      : 'Доступ приостановлен',
                  style: const TextStyle(
                      color: DS.textSecondary, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 14),
                _RenewButton(onTap: widget.onGoToPremium),
              ] else if (sub != null)
                Row(mainAxisAlignment: MainAxisAlignment.center, children: const [
                  SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: DS.textMuted),
                  ),
                  SizedBox(width: 8),
                  Text('Загрузка трафика…',
                      style: TextStyle(color: DS.textSecondary, fontSize: 13)),
                ])
              else
                const Center(
                  child: Text('Загрузка данных…',
                      style: TextStyle(color: DS.textSecondary, fontSize: 13)),
                ),
            ] else if (_isPublicCatalog && !authState.isLoggedIn)
              _LoginPrompt()
            else if (_isPublicCatalog && authState.isLoggedIn)
              _NoPlanPrompt(onGoToPremium: widget.onGoToPremium)
            else if (info != null) ...[
              if (sub != null &&
                  (sub.expireDate?.isBefore(DateTime.now()) ?? false)) ...[
                Text(
                  sub.expireDate != null
                      ? 'Истекла ${_formatExpiry(sub.expireDate!)}'
                      : 'Доступ приостановлен',
                  style: const TextStyle(
                      color: DS.textSecondary, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 14),
                _RenewButton(onTap: widget.onGoToPremium),
              ] else if (info.totalBytes <= 0) ...[
                // Безлимитный трафик — особый вид
                _UnlimitedTrafficSection(usedLabel: info.formattedUsed),
              ] else ...[
                // Traffic stats
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(info.formattedUsed, style: const TextStyle(
                        color: DS.textPrimary, fontSize: 28,
                        fontWeight: FontWeight.w800, height: 1)),
                    const SizedBox(width: 6),
                    Text('/ ${info.formattedTotal}',
                        style: const TextStyle(color: DS.textMuted, fontSize: 15)),
                  ],
                ),
                const SizedBox(height: 12),

                // Progress bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Stack(children: [
                    Container(height: 6, color: DS.surface3),
                    FractionallySizedBox(
                      widthFactor: info.usedFraction.clamp(0.0, 1.0),
                      child: Container(
                        height: 6,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              _progressColor(info.usedFraction),
                              Color.lerp(
                                  _progressColor(info.usedFraction),
                                  Colors.white, 0.22)!,
                            ],
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                          ),
                          boxShadow: [BoxShadow(
                              color: _progressColor(info.usedFraction)
                                  .withValues(alpha: 0.45),
                              blurRadius: 6)],
                        ),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 10),

                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('Осталось: ${_remaining(info)}',
                      style: const TextStyle(color: DS.textSecondary, fontSize: 12)),
                  Text('${(info.usedFraction * 100).toStringAsFixed(1)}%',
                      style: TextStyle(
                          color: _progressColor(info.usedFraction),
                          fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              ],
            ],

            const SizedBox(height: 16),
          ]),
        ),

        // ── CTA «Управление подпиской» ───────────────────────────────────────
        if (canOpenDetails) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Material(
              color: DS.surface2,
              borderRadius: BorderRadius.circular(DS.radiusSm),
              child: InkWell(
                onTap: openDetails,
                borderRadius: BorderRadius.circular(DS.radiusSm),
                splashColor: DS.violet.withValues(alpha: 0.12),
                highlightColor: DS.violet.withValues(alpha: 0.06),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(DS.radiusSm),
                    border: Border.all(
                        color: DS.violet.withValues(alpha: 0.40), width: 1),
                  ),
                  child: Row(children: [
                    Icon(Icons.manage_accounts_rounded,
                        size: 18,
                        color: Color.lerp(DS.violet, Colors.white, 0.28)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Управление подпиской',
                              style: TextStyle(
                                color:
                                    Color.lerp(DS.violet, Colors.white, 0.28),
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                height: 1.2,
                              )),
                          const SizedBox(height: 2),
                          const Text('Тариф, оплата, продление',
                              style: TextStyle(
                                color: DS.textMuted,
                                fontSize: 11.5,
                                height: 1.2,
                              )),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.chevron_right_rounded,
                        size: 20,
                        color: DS.violet.withValues(alpha: 0.70)),
                  ]),
                ),
              ),
            ),
          ),
        ] else
          const SizedBox(height: 2),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Local widgets
// ─────────────────────────────────────────────────────────────────────────────

// ── Круглая кнопка подключения ────────────────────────────────────────────────

class _ConnectButton extends StatefulWidget {
  final bool isConnected;
  final bool isLoading;
  final VoidCallback onTap;
  const _ConnectButton({
    required this.isConnected,
    required this.isLoading,
    required this.onTap,
  });

  @override
  State<_ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<_ConnectButton>
    with TickerProviderStateMixin {
  // Pulsing glow ring when connected
  late final AnimationController _glowCtrl;
  late final Animation<double> _glowAnim;
  // Icon rotation when loading
  late final AnimationController _spinCtrl;

  @override
  void initState() {
    super.initState();
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _glowAnim = Tween<double>(begin: 0.06, end: 0.24).animate(
      CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut),
    );
    _spinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.isConnected) _glowCtrl.repeat(reverse: true);
    if (widget.isLoading) _spinCtrl.repeat();
  }

  @override
  void didUpdateWidget(covariant _ConnectButton old) {
    super.didUpdateWidget(old);
    if (widget.isConnected && !old.isConnected) {
      _glowCtrl.repeat(reverse: true);
    } else if (!widget.isConnected && old.isConnected) {
      _glowCtrl
        ..stop()
        ..reset();
    }
    if (widget.isLoading && !old.isLoading) {
      _spinCtrl.repeat();
    } else if (!widget.isLoading && old.isLoading) {
      _spinCtrl
        ..stop()
        ..reset();
    }
  }

  @override
  void dispose() {
    _glowCtrl.dispose();
    _spinCtrl.dispose();
    super.dispose();
  }

  Color get _color => widget.isConnected
      ? DS.emerald
      : widget.isLoading
          ? DS.amber
          : DS.violet;


  String get _hint => widget.isConnected
      ? 'Нажмите, чтобы отключить'
      : widget.isLoading
          ? 'Подождите…'
          : 'Нажмите, чтобы подключить';

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: Listenable.merge([_glowAnim, _spinCtrl]),
          builder: (_, __) {
            final glowAlpha = widget.isConnected ? _glowAnim.value : 0.0;
            return GestureDetector(
              onTap: widget.isLoading ? null : widget.onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 350),
                width: 128,
                height: 128,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _color,
                  boxShadow: [
                    BoxShadow(
                      color: _color.withValues(alpha: 0.45),
                      blurRadius: 40,
                      spreadRadius: 0,
                    ),
                    if (widget.isConnected)
                      BoxShadow(
                        color: DS.emerald.withValues(alpha: glowAlpha),
                        blurRadius: 0,
                        spreadRadius: 18,
                      ),
                  ],
                ),
                child: widget.isLoading
                    ? RotationTransition(
                        turns: _spinCtrl,
                        child: const Icon(Icons.refresh_rounded,
                            color: Colors.white, size: 44),
                      )
                    : AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: !widget.isConnected
                            ? Column(
                                key: const ValueKey('off'),
                                mainAxisSize: MainAxisSize.min,
                                children: const [
                                  Icon(Icons.power_settings_new_rounded,
                                      color: Colors.white, size: 38),
                                  SizedBox(height: 4),
                                  Text('Отключено',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      )),
                                ],
                              )
                            : const Icon(
                                key: ValueKey('on'),
                                Icons.shield_rounded,
                                color: Colors.white,
                                size: 44,
                              ),
                      ),
              ),
            );
          },
        ),
        // Достаточный отступ, чтобы свечение не наезжало на подпись
        const SizedBox(height: 28),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Text(
            key: ValueKey(_hint),
            _hint,
            style: const TextStyle(
              color: DS.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ],
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
      builder: (_, v, _) => Text(_fmt(v), style: TextStyle(
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
      borderRadius: BorderRadius.circular(DS.radiusSm),
      border: Border.all(color: DS.telegramBlue.withValues(alpha: 0.20)),
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

class _NoPlanPrompt extends StatelessWidget {
  final VoidCallback? onGoToPremium;
  const _NoPlanPrompt({this.onGoToPremium});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('У вас нет активной подписки.',
          style: TextStyle(color: DS.textSecondary, fontSize: 13, height: 1.5)),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        height: 52,
        child: GestureDetector(
          onTap: onGoToPremium,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: DS.violet,
              borderRadius: BorderRadius.circular(DS.radius),
              boxShadow: [
                BoxShadow(
                  color: DS.violet.withValues(alpha: 0.30),
                  blurRadius: 16, offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Text('Получить подписку',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    ],
  );
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
          // Violet = brand colour → reads as "active/ok" in this palette context.
          // Gold works as accent only against a deep-indigo background (hero card);
          // on neutral surface1 it looks like a warning — violet is unambiguous here.
          color = DS.violet; label = 'Активна'; icon = Icons.verified_rounded;
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
    final color = expired ? DS.rose : soon ? DS.amber : DS.violet;
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

class _RenewButton extends StatelessWidget {
  final VoidCallback? onTap;
  const _RenewButton({this.onTap});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: 56,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: DS.violet,
          borderRadius: BorderRadius.circular(DS.radius),
          boxShadow: [
            BoxShadow(
              color: DS.violet.withValues(alpha: 0.30),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.bolt_rounded, size: 18, color: Colors.white),
            SizedBox(width: 8),
            Text('Возобновить подписку',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    ),
  );
}

// ── Shared micro-widgets ──────────────────────────────────────────────────────

class VpnIconBtn extends StatefulWidget {
  final bool loading;
  final IconData icon;
  final VoidCallback? onTap;
  const VpnIconBtn({super.key, required this.loading, required this.icon, this.onTap});

  @override
  State<VpnIconBtn> createState() => _VpnIconBtnState();
}

class _VpnIconBtnState extends State<VpnIconBtn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotCtrl;

  @override
  void initState() {
    super.initState();
    _rotCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    if (widget.loading) _rotCtrl.repeat();
  }

  @override
  void didUpdateWidget(VpnIconBtn old) {
    super.didUpdateWidget(old);
    if (widget.loading && !old.loading) {
      _rotCtrl.repeat();
    } else if (!widget.loading && old.loading) {
      final remaining = 1.0 - (_rotCtrl.value % 1.0);
      if (remaining > 0 && remaining < 1.0) {
        _rotCtrl.animateTo(
          _rotCtrl.value + remaining,
          duration: Duration(milliseconds: (remaining * 700).round().clamp(1, 700)),
        ).then((_) { if (mounted) _rotCtrl.reset(); });
      } else {
        _rotCtrl.reset();
      }
    }
  }

  @override
  void dispose() {
    _rotCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: widget.onTap,
    child: Container(
      width: 40, height: 40,
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radiusSm),
        border: Border.all(color: DS.border),
      ),
      child: RotationTransition(
        turns: _rotCtrl,
        child: Icon(widget.icon, color: DS.textSecondary, size: 20),
      ),
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
  const VpnInfoBanner({super.key, required this.color, required this.text});

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

// ─────────────────────────────────────────────────────────────────────────────
// _SpeedCardFlyIn — карточка скоростей, прилетающая сверху при подключении
// ─────────────────────────────────────────────────────────────────────────────
class _SpeedCardFlyIn extends StatefulWidget {
  final double uploadSpeed;
  final double downloadSpeed;
  final String uploadTotal;
  final String downloadTotal;

  const _SpeedCardFlyIn({
    required this.uploadSpeed,
    required this.downloadSpeed,
    required this.uploadTotal,
    required this.downloadTotal,
  });

  @override
  State<_SpeedCardFlyIn> createState() => _SpeedCardFlyInState();
}

class _SpeedCardFlyInState extends State<_SpeedCardFlyIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 520));
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.8),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));
    _fade = Tween<double>(begin: 0, end: 1).animate(
        CurvedAnimation(parent: _ctrl, curve: const Interval(0, 0.55)));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: DS.surface1,
            borderRadius: BorderRadius.circular(DS.radiusSm),
            border: Border.all(color: DS.border),
          ),
          child: Row(children: [
            Expanded(
                child: _SpeedTile(
              icon: Icons.arrow_upward_rounded,
              color: DS.emerald,
              label: 'Отдача',
              speed: widget.uploadSpeed,
              total: widget.uploadTotal,
            )),
            Container(width: 1, height: 36, color: DS.border),
            Expanded(
                child: _SpeedTile(
              icon: Icons.arrow_downward_rounded,
              color: DS.violet,
              label: 'Загрузка',
              speed: widget.downloadSpeed,
              total: widget.downloadTotal,
            )),
          ]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _UnlimitedTrafficSection — блок для безлимитного трафика
// ─────────────────────────────────────────────────────────────────────────────
class _UnlimitedTrafficSection extends StatelessWidget {
  final String usedLabel;
  const _UnlimitedTrafficSection({required this.usedLabel});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Иконка-плашка
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: DS.cyan.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: DS.cyan.withValues(alpha: 0.22),
                    blurRadius: 14,
                    spreadRadius: -3,
                  ),
                ],
              ),
              child: const Icon(Icons.all_inclusive_rounded,
                  size: 22, color: DS.cyan),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Безлимитный трафик',
                  style: TextStyle(
                    color: DS.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'использовано $usedLabel',
                  style: const TextStyle(
                    color: DS.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

