import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:v2ray_box/v2ray_box.dart';

import '../models/server_node.dart';
import '../models/subscription_info.dart';
import '../services/remnawave_service.dart';

class HomePage extends StatefulWidget {
  final V2rayBox v2rayBox;
  const HomePage({super.key, required this.v2rayBox});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  VpnStatus _status = VpnStatus.stopped;
  VpnStats _stats = const VpnStats();
  VpnMode _mode = VpnMode.vpn;
  String _coreEngine = 'xray';
  TotalTraffic _totalTraffic = const TotalTraffic();

  List<VpnConfig> _configs = [];
  VpnConfig? _selectedConfig;

  List<ServerNode> _subscriptionNodes = [];
  bool _isLoadingNodes = false;
  SubscriptionInfo? _subscriptionInfo;

  StreamSubscription<VpnStatus>? _statusSub;
  StreamSubscription<VpnStats>? _statsSub;
  Timer? _trafficTimer;
  bool _proxyProbeInProgress = false;
  Map<String, bool?> _proxyEndpointStatus = {};

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pulseCtrl = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(
      begin: 0.8,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _load();
  }

  Future<void> _load() async {
    await _loadConfigs();
    await _refreshRuntimeState();
    _startWatching();
    unawaited(_loadSubscriptionNodes());
    if (mounted) setState(() {});
  }

  Future<void> _loadSubscriptionNodes() async {
    if (mounted) setState(() => _isLoadingNodes = true);
    final nodes = await RemnawaveService.fetchNodes();
    if (!mounted) return;
    setState(() {
      _subscriptionNodes = nodes;
      _subscriptionInfo = RemnawaveService.lastSubscriptionInfo;
      _isLoadingNodes = false;
    });
  }

  Future<void> _refreshRuntimeState() async {
    final mode = await widget.v2rayBox.getServiceMode();
    final core = await widget.v2rayBox.getCoreEngine();
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _coreEngine = core;
    });
  }

  List<_LocalProxyEndpoint> _proxyEndpointsForCurrentCore() {
    final core = _coreEngine.toLowerCase();
    if (core == 'singbox') {
      return const [
        _LocalProxyEndpoint(
          label: 'SOCKS5',
          uri: 'socks5://127.0.0.1:10808',
          note: 'sing-box mixed inbound',
        ),
        _LocalProxyEndpoint(
          label: 'HTTP',
          uri: 'http://127.0.0.1:10808',
          note: 'sing-box mixed inbound',
        ),
      ];
    }
    return const [
      _LocalProxyEndpoint(
        label: 'SOCKS5',
        uri: 'socks5://127.0.0.1:10808',
        note: 'xray socks inbound',
      ),
      _LocalProxyEndpoint(
        label: 'HTTP',
        uri: 'http://127.0.0.1:10809',
        note: 'xray http inbound',
      ),
    ];
  }

  Future<bool> _isLocalPortReady(int port) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 800),
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  Future<void> _probeLocalProxyEndpoints() async {
    if (_proxyProbeInProgress) return;
    await _refreshRuntimeState();
    final endpoints = _proxyEndpointsForCurrentCore();

    setState(() {
      _proxyProbeInProgress = true;
      _proxyEndpointStatus = {};
    });

    try {
      final result = <String, bool?>{};
      for (final endpoint in endpoints) {
        final uri = Uri.parse(endpoint.uri);
        result[endpoint.uri] = await _isLocalPortReady(uri.port);
      }
      if (!mounted) return;
      setState(() => _proxyEndpointStatus = result);
    } finally {
      if (mounted) {
        setState(() => _proxyProbeInProgress = false);
      }
    }
  }

  Future<void> _copyProxyEndpoint(String uri) async {
    await Clipboard.setData(ClipboardData(text: uri));
    _snack('$uri copied');
  }

  Future<void> _loadConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString('vpn_configs');
    var hadTransientPing = false;
    if (json != null) {
      final List<dynamic> list = jsonDecode(json);
      _configs = list.map((e) => VpnConfig.fromJson(e)).toList();
      for (final c in _configs) {
        if (c.ping == -2) {
          c.ping = -1;
          hadTransientPing = true;
        }
      }
      for (var c in _configs) {
        if (c.isSelected) {
          _selectedConfig = c;
          break;
        }
      }
    }
    if (hadTransientPing) {
      await _saveConfigs();
    }
  }

  Future<void> _saveConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    final persistable = _configs
        .map((e) => e.copyWith(ping: e.ping == -2 ? -1 : e.ping))
        .map((e) => e.toJson())
        .toList();
    await prefs.setString('vpn_configs', jsonEncode(persistable));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshRuntimeState());
      if (_mode == VpnMode.proxy && _status == VpnStatus.started) {
        unawaited(_probeLocalProxyEndpoints());
      }
    }
  }

  void _startWatching() {
    _statusSub = widget.v2rayBox.watchStatus().listen((s) {
      if (!mounted) return;
      setState(() => _status = s);
      if (_mode == VpnMode.proxy && s == VpnStatus.started) {
        unawaited(_probeLocalProxyEndpoints());
      } else if (s != VpnStatus.started && _proxyEndpointStatus.isNotEmpty) {
        setState(() => _proxyEndpointStatus = {});
      }
    });
    _statsSub = widget.v2rayBox.watchStats().listen((s) {
      if (mounted) setState(() => _stats = s);
    });
    _loadTraffic();
    _trafficTimer = Timer.periodic(
      const Duration(seconds: 10),
          (_) => _loadTraffic(),
    );
  }

  Future<void> _loadTraffic() async {
    final t = await widget.v2rayBox.getTotalTraffic();
    if (mounted) setState(() => _totalTraffic = t);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusSub?.cancel();
    _statsSub?.cancel();
    _trafficTimer?.cancel();
    _pulseCtrl.dispose();
    super.dispose();
  }

  void _selectConfig(VpnConfig config) {
    setState(() {
      for (var c in _configs) {
        c.isSelected = false;
      }
      config.isSelected = true;
      _selectedConfig = config;
    });
    _saveConfigs();
  }

  void _selectSubscriptionNode(ServerNode node) {
    final link = node.link;
    if (link == null || link.isEmpty) return;

    // Reuse existing config if already imported; otherwise parse and add.
    try {
      var config = _configs.firstWhere(
        (c) => c.link == link,
        orElse: () {
          final newCfg = widget.v2rayBox.parseConfigLink(link);
          _configs.add(newCfg);
          return newCfg;
        },
      );
      _selectConfig(config); // _selectConfig already calls _saveConfigs()
    } catch (e) {
      _snack('Не удалось загрузить конфиг: $e');
    }
  }

  void _showServerPicker() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            // Reload nodes and update both the sheet and the parent state.
            Future<void> reload() async {
              setSheetState(() => _isLoadingNodes = true);
              final nodes = await RemnawaveService.fetchNodes();
              if (!mounted) return;
              setState(() {
                _subscriptionNodes = nodes;
                _subscriptionInfo = RemnawaveService.lastSubscriptionInfo;
                _isLoadingNodes = false;
              });
              setSheetState(() {});
            }

            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.55,
              maxChildSize: 0.9,
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
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (_isLoadingNodes)
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          IconButton(
                            icon: const Icon(Icons.refresh, size: 20),
                            onPressed: reload,
                            tooltip: 'Обновить',
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: _subscriptionNodes.isEmpty
                        ? Center(
                            child: _isLoadingNodes
                                ? const CircularProgressIndicator()
                                : Padding(
                                    padding: const EdgeInsets.all(32),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.cloud_off,
                                          size: 48,
                                          color: Colors.grey[600],
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          'Серверы не получены',
                                          style: TextStyle(
                                            color: Colors.grey[400],
                                            fontSize: 14,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Проверьте URL подписки в Настройках',
                                          style: TextStyle(
                                            color: Colors.grey[600],
                                            fontSize: 12,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ],
                                    ),
                                  ),
                          )
                        : ListView.builder(
                            controller: scrollCtrl,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            itemCount: _subscriptionNodes.length,
                            itemBuilder: (_, i) {
                              final node = _subscriptionNodes[i];
                              final isSelected =
                                  _selectedConfig?.link == node.link;
                              return Card(
                                margin: const EdgeInsets.only(bottom: 6),
                                color: isSelected
                                    ? const Color(0xFF6C5CE7).withOpacity(0.15)
                                    : null,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  side: isSelected
                                      ? const BorderSide(
                                          color: Color(0xFF6C5CE7),
                                          width: 1.5,
                                        )
                                      : BorderSide.none,
                                ),
                                child: ListTile(
                                  onTap: () {
                                    _selectSubscriptionNode(node);
                                    Navigator.pop(ctx);
                                  },
                                  leading: Text(
                                    _countryEmoji(node.countryCode),
                                    style: const TextStyle(fontSize: 24),
                                  ),
                                  title: Text(
                                    node.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    node.address,
                                    style: TextStyle(
                                      color: Colors.grey[500],
                                      fontSize: 12,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: isSelected
                                      ? const Icon(
                                          Icons.check_circle,
                                          color: Color(0xFF6C5CE7),
                                        )
                                      : _protocolBadge(node.protocol ?? ''),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  String _countryEmoji(String countryCode) {
    if (countryCode.length != 2) return '🌐';
    final upper = countryCode.toUpperCase();
    final f = upper.codeUnitAt(0);
    final s = upper.codeUnitAt(1);
    // Only emit flag emoji for valid ASCII letter pairs.
    if (f < 0x41 || f > 0x5A || s < 0x41 || s > 0x5A) return '🌐';
    const base = 0x1F1E6 - 0x41;
    return String.fromCharCode(base + f) + String.fromCharCode(base + s);
  }

  Widget _protocolBadge(String protocol) {
    if (protocol.isEmpty) return const SizedBox.shrink();
    Color color;
    switch (protocol.toLowerCase()) {
      case 'vless':
        color = const Color(0xFF00D9FF);
      case 'vmess':
        color = const Color(0xFF6C5CE7);
      case 'trojan':
        color = const Color(0xFFFFA502);
      case 'ss':
        color = const Color(0xFF2ED573);
      default:
        color = Colors.grey;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        protocol.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Future<void> _toggleConnection() async {
    final runtimeMode = await widget.v2rayBox.getServiceMode();
    final runtimeCore = await widget.v2rayBox.getCoreEngine();
    if (mounted && (runtimeMode != _mode || runtimeCore != _coreEngine)) {
      setState(() {
        _mode = runtimeMode;
        _coreEngine = runtimeCore;
      });
    } else {
      _mode = runtimeMode;
      _coreEngine = runtimeCore;
    }

    if (_status == VpnStatus.stopping) {
      return;
    }

    if (_status == VpnStatus.started || _status == VpnStatus.starting) {
      if (mounted) {
        setState(() => _status = VpnStatus.stopping);
      }
      await widget.v2rayBox.disconnect();
    } else {
      if (_selectedConfig == null) {
        _snack('Please select a config first');
        return;
      }
      try {
        if (mounted) {
          setState(() => _status = VpnStatus.starting);
        }
        if (runtimeMode == VpnMode.vpn) {
          final has = await widget.v2rayBox.checkVpnPermission();
          if (!has) {
            final granted = await widget.v2rayBox.requestVpnPermission();
            if (!granted) {
              if (mounted) {
                setState(() => _status = VpnStatus.stopped);
              }
              _snack('VPN permission required');
              return;
            }
          }
        }
        // Connect using the library's engine directly — the patched v2ray_box
        // library now uses a real IP-based dns-direct server (8.8.8.8) in
        // the sing-box config, so DNS resolution works without any app-side
        // JSON patching.
        final err = await widget.v2rayBox.parseConfig(_selectedConfig!.link);
        if (err.isNotEmpty) {
          if (mounted) {
            setState(() => _status = VpnStatus.stopped);
          }
          _snack('Config error: $err');
          return;
        }
        final prefs = await SharedPreferences.getInstance();
        final fragmentOn = prefs.getBool('tls_fragment_enabled') ?? false;
        await widget.v2rayBox.setConfigOptions(
          fragmentOn
              ? const _FragmentConfigOptions()
              : const ConfigOptions(),
        );
        await widget.v2rayBox.connect(
          _selectedConfig!.link,
          name: _selectedConfig!.name,
        );
      } catch (e) {
        if (mounted) {
          setState(() => _status = VpnStatus.stopped);
        }
        _snack('Connection failed: $e');
      }
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF2D2D44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _buildConnectionCard(),
                  if (_mode == VpnMode.proxy) _buildProxyModeCard(),
                  _buildStatsRow(),
                  _buildTotalTrafficCard(),
                  if (_subscriptionInfo != null) _buildSubscriptionCard(),
                  const SizedBox(height: 80),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'V2Ray Box',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          Text(
            _mode == VpnMode.vpn ? 'VPN Mode' : 'Proxy Mode',
            style: TextStyle(color: Colors.grey[400], fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionCard() {
    final isConnected = _status == VpnStatus.started;
    final isTransitioning =
        _status == VpnStatus.starting || _status == VpnStatus.stopping;

    String statusText = 'Disconnected';
    Color statusColor = Colors.grey;
    IconData statusIcon = Icons.shield_outlined;

    if (isConnected) {
      statusText = 'Connected';
      statusColor = const Color(0xFF00D9FF);
      statusIcon = Icons.shield;
    } else if (_status == VpnStatus.starting) {
      statusText = 'Connecting...';
      statusColor = const Color(0xFFFFA502);
    } else if (_status == VpnStatus.stopping) {
      statusText = 'Disconnecting...';
      statusColor = const Color(0xFFFFA502);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GestureDetector(
        onTap: _toggleConnection,
        child: Card(
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: isConnected
                  ? LinearGradient(
                colors: [
                  const Color(0xFF6C5CE7).withOpacity(0.3),
                  const Color(0xFF00D9FF).withOpacity(0.1),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
                  : null,
            ),
            child: Row(
              children: [
                AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: isTransitioning ? _pulseAnim.value : 1.0,
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: statusColor.withOpacity(0.2),
                        ),
                        child: isTransitioning
                            ? SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            valueColor: AlwaysStoppedAnimation(
                              statusColor,
                            ),
                          ),
                        )
                            : Icon(statusIcon, color: statusColor, size: 32),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        statusText,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: statusColor,
                        ),
                      ),
                      const SizedBox(height: 6),
                      GestureDetector(
                        onTap: _showServerPicker,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                _selectedConfig?.name ?? 'Выбрать сервер',
                                style: TextStyle(
                                  color: _selectedConfig != null
                                      ? Colors.grey[400]
                                      : const Color(0xFF6C5CE7),
                                  fontSize: 13,
                                  fontWeight: _selectedConfig != null
                                      ? FontWeight.normal
                                      : FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.expand_more_rounded,
                              size: 16,
                              color: _selectedConfig != null
                                  ? Colors.grey[500]
                                  : const Color(0xFF6C5CE7),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  isConnected
                      ? Icons.stop_circle_outlined
                      : Icons.play_circle_outline,
                  color: statusColor,
                  size: 40,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _proxyStatusColor(bool? ready, bool connected) {
    if (!connected) return Colors.grey;
    if (ready == null) return const Color(0xFFFFA502);
    return ready ? const Color(0xFF2ED573) : const Color(0xFFFF4757);
  }

  String _proxyStatusText(bool? ready, bool connected) {
    if (!connected) return 'Connect first';
    if (ready == null) return 'Not tested';
    return ready ? 'Ready' : 'Not listening';
  }

  Widget _buildProxyModeCard() {
    final endpoints = _proxyEndpointsForCurrentCore();
    final connected = _status == VpnStatus.started;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFA502).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.settings_ethernet,
                      color: Color(0xFFFFA502),
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Proxy Mode Endpoints',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Core: ${_coreEngine == 'singbox' ? 'sing-box' : 'xray'}',
                          style: TextStyle(
                            color: Colors.grey[400],
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'In Proxy mode, apps may not route traffic automatically. '
                    'Set proxy manually in app/system settings using these local endpoints.',
                style: TextStyle(
                  color: Colors.grey[350],
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 10),
              ...endpoints.map((endpoint) {
                final ready = _proxyEndpointStatus[endpoint.uri];
                final statusColor = _proxyStatusColor(ready, connected);
                final statusText = _proxyStatusText(ready, connected);
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.16),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  endpoint.label,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    endpoint.note,
                                    style: TextStyle(
                                      color: Colors.grey[500],
                                      fontSize: 11,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              endpoint.uri,
                              style: TextStyle(
                                color: Colors.grey[300],
                                fontSize: 12,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: statusColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                statusText,
                                style: TextStyle(
                                  color: statusColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy_rounded, size: 18),
                            tooltip: 'Copy endpoint',
                            onPressed: () => _copyProxyEndpoint(endpoint.uri),
                            color: const Color(0xFF00D9FF),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: connected && !_proxyProbeInProgress
                        ? _probeLocalProxyEndpoints
                        : null,
                    icon: _proxyProbeInProgress
                        ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                        : const Icon(Icons.wifi_find, size: 16),
                    label: Text(
                      _proxyProbeInProgress ? 'Testing...' : 'Test Local Proxy',
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _refreshRuntimeState,
                    icon: const Icon(Icons.sync, size: 16),
                    label: const Text('Refresh'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatsRow() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: _StatTile(
              icon: Icons.arrow_upward,
              label: 'Upload',
              value: _stats.formattedUplink,
              total: _stats.formattedUplinkTotal,
              color: const Color(0xFF6C5CE7),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _StatTile(
              icon: Icons.arrow_downward,
              label: 'Download',
              value: _stats.formattedDownlink,
              total: _stats.formattedDownlinkTotal,
              color: const Color(0xFF00D9FF),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTotalTrafficCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF2ED573).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.data_usage,
                  color: Color(0xFF2ED573),
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Total Traffic',
                      style: TextStyle(color: Colors.grey[400], fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _totalTraffic.formattedTotal,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2ED573),
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.arrow_upward,
                        size: 12,
                        color: Color(0xFF6C5CE7),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _totalTraffic.formattedUpload,
                        style: TextStyle(color: Colors.grey[400], fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.arrow_downward,
                        size: 12,
                        color: Color(0xFF00D9FF),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _totalTraffic.formattedDownload,
                        style: TextStyle(color: Colors.grey[400], fontSize: 11),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.refresh, color: Colors.grey),
                onPressed: () async {
                  await widget.v2rayBox.resetTotalTraffic();
                  await _loadTraffic();
                  _snack('Total traffic reset');
                },
                tooltip: 'Reset',
                iconSize: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSubscriptionCard() {
    final info = _subscriptionInfo!;
    final expDate = info.expireDate;
    final fraction = info.usedFraction;

    // Progress bar color: green → yellow → red as quota fills up
    Color barColor;
    if (fraction < 0.6) {
      barColor = const Color(0xFF2ED573);
    } else if (fraction < 0.85) {
      barColor = const Color(0xFFFFA502);
    } else {
      barColor = const Color(0xFFFF4757);
    }

    String? expiryText;
    if (expDate != null) {
      final now = DateTime.now();
      final diff = expDate.difference(now);
      if (diff.isNegative) {
        expiryText = 'Подписка истекла';
      } else if (diff.inDays == 0) {
        expiryText = 'Истекает сегодня';
      } else {
        final d = expDate;
        expiryText =
            'До ${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: barColor.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.data_usage_rounded,
                      color: barColor,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Трафик подписки',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (expiryText != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            expiryText,
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Text(
                    '${info.formattedUsed} / ${info.formattedTotal}',
                    style: TextStyle(
                      color: barColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              if (info.totalBytes > 0) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: fraction,
                    backgroundColor: barColor.withOpacity(0.15),
                    valueColor: AlwaysStoppedAnimation(barColor),
                    minHeight: 6,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LocalProxyEndpoint {
  final String label;
  final String uri;
  final String note;

  const _LocalProxyEndpoint({
    required this.label,
    required this.uri,
    required this.note,
  });
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label, value, total;
  final Color color;

  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.total,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 18),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(color: Colors.grey[400], fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            Text(
              'Total: $total',
              style: TextStyle(color: Colors.grey[500], fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

/// A [ConfigOptions] variant that enables TLS fragmentation.
///
/// Fragmentation breaks the TLS ClientHello into multiple TCP segments so that
/// DPI systems cannot read the SNI field.  This is effective against
/// whitelist-based mobile filtering (e.g. Rostelecom, Beeline, etc.).
class _FragmentConfigOptions extends ConfigOptions {
  const _FragmentConfigOptions() : super();

  @override
  Map<String, dynamic> toJson() {
    final json = super.toJson();
    json['tls-tricks'] = {
      'enable-fragment': true,
      'fragment-size': '100-200',
      'fragment-sleep': '50-100',
      'mixed-sni-case': false,
      'enable-padding': false,
      'padding-size': '100-200',
    };
    return json;
  }
}

