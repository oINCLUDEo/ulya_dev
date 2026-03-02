import 'dart:convert';
import 'dart:typed_data';

import 'package:device_apps/device_apps.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_v2ray_plus/flutter_v2ray.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/remnawave_service.dart';
import '../utils/core_info_parser.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  // ── Настройки подписки ────────────────────────────────────────────────────
  String _subscriptionUrl = '';

  // ── Режим работы ─────────────────────────────────────────────────────────
  bool _proxyOnly = false;

  // ── DNS-серверы ───────────────────────────────────────────────────────────
  List<String> _dnsServers = ['8.8.8.8', '114.114.114.114'];
  bool _useCustomDns = false;

  // ── Исключение приложений (blockedApps) ───────────────────────────────────
  /// Пакеты которые будут исключены из VPN-туннеля
  Set<String> _blockedApps = {};

  // ── TLS Fragment (bypass DPI) ─────────────────────────────────────────────
  bool _fragmentEnabled = false;

  // ── Ping URL ──────────────────────────────────────────────────────────────
  String _pingTestUrl = 'https://www.gstatic.com/generate_204';

  // ── Версия ядра ───────────────────────────────────────────────────────────
  CoreInfo _coreInfo = CoreInfo(
    name: 'Xray',
    version: 'загрузка...',
    architecture: '',
    goVersion: '',
    fullString: '',
  );

  // ── Состояние загрузки ────────────────────────────────────────────────────
  bool _loading = true;

  // ── Кэш иконок приложений ────────────────────────────────────────────────
  List<Application> _installedApps = [];
  final Map<String, Uint8List> _iconCache = {};
  bool _appsLoading = false;
  bool _iconsLoading = false;
  final _iconCacheNotifier = ValueNotifier<int>(0);

  // ── flutter_v2ray_plus ────────────────────────────────────────────────────
  late final FlutterV2ray _v2ray;

  static const String _keyProxyOnly = 'settings_proxy_only';
  static const String _keyCustomDns = 'settings_custom_dns_enabled';
  static const String _keyDnsServers = 'settings_dns_servers';
  static const String _keyBlockedApps = 'settings_blocked_apps';
  static const String _keyFragment = 'tls_fragment_enabled';
  static const String _keyPingUrl = 'settings_ping_url';

  @override
  void initState() {
    super.initState();
    _v2ray = FlutterV2ray();
    _load();
    _loadCoreInfo(); // Добавляем загрузку информации о ядре
  }

  @override
  void dispose() {
    _iconCacheNotifier.dispose();
    super.dispose();
  }

  // Новый метод для загрузки информации о ядре
  Future<void> _loadCoreInfo() async {
    try {
      String versionString = await _v2ray.getCoreVersion();
      if (mounted) {
        setState(() {
          _coreInfo = CoreInfo.fromString(versionString);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _coreInfo = CoreInfo(
            name: 'Xray',
            version: 'ошибка',
            architecture: '',
            goVersion: '',
            fullString: '',
          );
        });
      }
    }
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();

    _subscriptionUrl = await RemnawaveService.getSubscriptionUrl();
    _proxyOnly = prefs.getBool(_keyProxyOnly) ?? false;
    _useCustomDns = prefs.getBool(_keyCustomDns) ?? false;
    _fragmentEnabled = prefs.getBool(_keyFragment) ?? false;
    _pingTestUrl =
        prefs.getString(_keyPingUrl) ?? 'https://www.gstatic.com/generate_204';

    final dnsRaw = prefs.getString(_keyDnsServers);
    if (dnsRaw != null) {
      try {
        _dnsServers = List<String>.from(jsonDecode(dnsRaw) as List);
      } catch (_) {}
    }

    final blockedRaw = prefs.getString(_keyBlockedApps);
    if (blockedRaw != null) {
      try {
        _blockedApps = Set<String>.from(jsonDecode(blockedRaw) as List);
      } catch (_) {}
    }



    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyProxyOnly, _proxyOnly);
    await prefs.setBool(_keyCustomDns, _useCustomDns);
    await prefs.setBool(_keyFragment, _fragmentEnabled);
    await prefs.setString(_keyPingUrl, _pingTestUrl);
    await prefs.setString(_keyDnsServers, jsonEncode(_dnsServers));
    await prefs.setString(_keyBlockedApps, jsonEncode(_blockedApps.toList()));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return SafeArea(
      child: CustomScrollView(
        slivers: [
          // Заголовок
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Text(
                'Настройки',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ),

          // ── Подписка ──────────────────────────────────────────────
          _sliver(
            _buildSection('Подписка', [
              ListTile(
                leading: const Icon(Icons.link, size: 20),
                title: const Text('URL подписки'),
                subtitle: Text(
                  _subscriptionUrl.isEmpty ? 'Не задан' : _subscriptionUrl,
                  style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
                trailing: const Icon(Icons.edit, size: 18),
                onTap: _showSubscriptionDialog,
              ),
            ]),
          ),

          const SliverPadding(padding: EdgeInsets.only(top: 16)),

          // ── Информация о ядре ──────────────────────────────────────
          _sliver(_buildCoreCard()),

          const SliverPadding(padding: EdgeInsets.only(top: 16)),

          // ── Режим работы ───────────────────────────────────────────
          _sliver(
            _buildSection('Режим подключения', [
              RadioListTile<bool>(
                title: const Text('VPN'),
                subtitle: Text(
                  'Весь трафик проходит через VPN-туннель',
                  style: TextStyle(color: Colors.grey[400], fontSize: 12),
                ),
                value: false,
                groupValue: _proxyOnly,
                onChanged: (v) async {
                  setState(() => _proxyOnly = false);
                  await _save();
                },
              ),
              RadioListTile<bool>(
                title: const Text('Только прокси'),
                subtitle: Text(
                  'Только локальный SOCKS5/HTTP прокси, без VPN-туннеля. '
                  'Порт: 10808',
                  style: TextStyle(color: Colors.grey[400], fontSize: 12),
                ),
                value: true,
                groupValue: _proxyOnly,
                onChanged: (v) async {
                  setState(() => _proxyOnly = true);
                  await _save();
                },
              ),
            ]),
          ),

          const SliverPadding(padding: EdgeInsets.only(top: 16)),

          // ── Обход DPI ──────────────────────────────────────────────
          _sliver(
            _buildSection('Обход фильтрации (DPI)', [
              SwitchListTile(
                secondary: const Icon(Icons.security_outlined, size: 20),
                title: const Text('TLS Fragment'),
                subtitle: Text(
                  'Разбивает TLS ClientHello на фрагменты, скрывая SNI от '
                  'глубокой инспекции пакетов. Помогает при мобильном '
                  'интернете с белыми списками (особенно РФ-операторы).',
                  style: TextStyle(color: Colors.grey[400], fontSize: 12),
                ),
                value: _fragmentEnabled,
                onChanged: (v) async {
                  setState(() => _fragmentEnabled = v);
                  await _save();
                  _snack(
                    v
                        ? 'TLS Fragment включён — применится при следующем подключении'
                        : 'TLS Fragment выключен',
                  );
                },
              ),
            ]),
          ),

          const SliverPadding(padding: EdgeInsets.only(top: 16)),

          // ── DNS-серверы ────────────────────────────────────────────
          _sliver(
            _buildSection('DNS-серверы', [
              SwitchListTile(
                secondary: const Icon(Icons.dns_outlined, size: 20),
                title: const Text('Использовать свои DNS'),
                subtitle: Text(
                  'По умолчанию: 8.8.8.8, 114.114.114.114',
                  style: TextStyle(color: Colors.grey[400], fontSize: 12),
                ),
                value: _useCustomDns,
                onChanged: (v) async {
                  setState(() => _useCustomDns = v);
                  await _save();
                },
              ),
              if (_useCustomDns) ...[
                const Divider(height: 1),
                ..._dnsServers.asMap().entries.map(
                  (e) => ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 12,
                      backgroundColor: const Color(0xFF6C5CE7).withOpacity(0.2),
                      child: Text(
                        '${e.key + 1}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF6C5CE7),
                        ),
                      ),
                    ),
                    title: Text(
                      e.value,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.edit, size: 16),
                      onPressed: () => _editDns(e.key, e.value),
                    ),
                  ),
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(
                    Icons.add_circle_outline,
                    size: 20,
                    color: Color(0xFF2ED573),
                  ),
                  title: const Text(
                    'Добавить DNS-сервер',
                    style: TextStyle(color: Color(0xFF2ED573), fontSize: 13),
                  ),
                  onTap: () => _editDns(null, ''),
                ),
                // Пресеты
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _dnsPreset('Google', ['8.8.8.8', '8.8.4.4']),
                      _dnsPreset('Cloudflare', ['1.1.1.1', '1.0.0.1']),
                      _dnsPreset('AdGuard', ['94.140.14.14', '94.140.15.15']),
                      _dnsPreset('Quad9', ['9.9.9.9', '149.112.112.112']),
                    ],
                  ),
                ),
              ],
            ]),
          ),

          const SliverPadding(padding: EdgeInsets.only(top: 16)),

          // ── Исключение приложений ──────────────────────────────────
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
            _sliver(
              _buildSection('Исключение приложений (blockedApps)', [
                ListTile(
                  leading: const Icon(Icons.apps_outlined, size: 20),
                  title: const Text('Исключённые приложения'),
                  subtitle: Text(
                    _blockedApps.isEmpty
                        ? 'Все приложения идут через VPN'
                        : '${_blockedApps.length} прил. обходят VPN',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: _showBlockedAppsDialog,
                ),
              ]),
            ),

          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
            const SliverPadding(padding: EdgeInsets.only(top: 16)),

          // ── Дополнительно ──────────────────────────────────────────
          _sliver(
            _buildSection('Дополнительно', [
              ListTile(
                leading: const Icon(Icons.network_ping, size: 20),
                title: const Text('URL для проверки пинга'),
                subtitle: Text(
                  _pingTestUrl,
                  style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.edit, size: 18),
                onTap: _showPingUrlDialog,
              ),
            ]),
          ),

          const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
        ],
      ),
    );
  }

  // ── Section helpers ───────────────────────────────────────────────────────

  Widget _sliver(Widget child) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    sliver: SliverToBoxAdapter(child: child),
  );

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
        Card(child: Column(children: _separated(children))),
      ],
    );
  }

  List<Widget> _separated(List<Widget> widgets) {
    final result = <Widget>[];
    for (int i = 0; i < widgets.length; i++) {
      result.add(widgets[i]);
      if (i < widgets.length - 1) {
        result.add(const Divider(height: 1, indent: 16, endIndent: 16));
      }
    }
    return result;
  }

  // ── Core card ─────────────────────────────────────────────────────────────

  Widget _buildCoreCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // Иконка
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF6C5CE7).withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.memory,
                color: Color(0xFF6C5CE7),
                size: 24,
              ),
            ),
            const SizedBox(width: 16),

            // Информация о ядре
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Название ядра + архитектура (если есть)
                  Row(
                    children: [
                      Text(
                        '${_coreInfo.name}-core',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      if (_coreInfo.architecture.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey[800],
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _coreInfo.shortArch,
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 9,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),

                  // Строка с версией и Go
                  Row(
                    children: [
                      // Бейдж с версией
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2ED573).withOpacity(0.18),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'v${_coreInfo.version}',
                          style: const TextStyle(
                            color: Color(0xFF2ED573),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),

                      // Версия Go (если есть)
                      if (_coreInfo.goVersion.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey[800],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _coreInfo.goVersionShort,
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 9,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── DNS preset chip ──────────────────────��────────────────────────────────

  Widget _dnsPreset(String label, List<String> servers) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      visualDensity: VisualDensity.compact,
      onPressed: () async {
        setState(() => _dnsServers = List.from(servers));
        await _save();
        _snack('DNS: $label (${servers.join(', ')})');
      },
    );
  }

  // ── Диалоги ───────────────────────────────────────────────────────────────

  void _showSubscriptionDialog() {
    final ctrl = TextEditingController(text: _subscriptionUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('URL подписки'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                hintText: 'https://panel.example.com/sub/...',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              maxLines: 3,
            ),
            const SizedBox(height: 8),
            Text(
              'Получите ссылку в Telegram-боте или личном кабинете панели.',
              style: TextStyle(color: Colors.grey[500], fontSize: 11),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () async {
              final url = ctrl.text.trim();
              await RemnawaveService.saveSubscriptionUrl(url);
              setState(() => _subscriptionUrl = url);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  void _showPingUrlDialog() {
    final ctrl = TextEditingController(text: _pingTestUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('URL для проверки пинга'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                hintText: 'https://www.gstatic.com/generate_204',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                ActionChip(
                  label: const Text('gstatic', style: TextStyle(fontSize: 11)),
                  onPressed: () =>
                      ctrl.text = 'https://www.gstatic.com/generate_204',
                ),
                ActionChip(
                  label: const Text(
                    'Cloudflare',
                    style: TextStyle(fontSize: 11),
                  ),
                  onPressed: () => ctrl.text = 'http://cp.cloudflare.com',
                ),
                ActionChip(
                  label: const Text('Google', style: TextStyle(fontSize: 11)),
                  onPressed: () =>
                      ctrl.text = 'http://www.google.com/generate_204',
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () async {
              final url = ctrl.text.trim();
              if (url.isNotEmpty) {
                setState(() => _pingTestUrl = url);
                await _save();
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  void _editDns(int? index, String initial) {
    final ctrl = TextEditingController(text: initial);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(index == null ? 'Добавить DNS' : 'Изменить DNS'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                hintText: '1.1.1.1',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.dns_outlined),
              ),
              keyboardType: TextInputType.number,
            ),
            if (index != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                icon: const Icon(
                  Icons.delete_outline,
                  color: Color(0xFFE74C3C),
                ),
                label: const Text(
                  'Удалить',
                  style: TextStyle(color: Color(0xFFE74C3C)),
                ),
                onPressed: () async {
                  setState(() => _dnsServers.removeAt(index));
                  await _save();
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () async {
              final val = ctrl.text.trim();
              if (val.isNotEmpty) {
                setState(() {
                  if (index == null) {
                    _dnsServers.add(val);
                  } else {
                    _dnsServers[index] = val;
                  }
                });
                await _save();
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadInstalledApps() async {
    if (_appsLoading || _installedApps.isNotEmpty) return;
    _appsLoading = true;

    final apps = await DeviceApps.getInstalledApplications(
      onlyAppsWithLaunchIntent: true,
      includeSystemApps: false,
      includeAppIcons: false,
    );
    apps.sort((a, b) => a.appName.compareTo(b.appName));

    if (mounted) {
      setState(() => _installedApps = apps);
      _iconCacheNotifier.value++;
    }

    _loadIconsBatched(apps);
  }

  Future<void> _loadIconsBatched(List<Application> apps) async {
    if (_iconsLoading) return;
    _iconsLoading = true;

    try {
      const batchSize = 15;
      for (int i = 0; i < apps.length; i += batchSize) {
        final batch = apps.skip(i).take(batchSize).toList();

        final results = await Future.wait(
          batch.map((app) async {
            try {
              final info = await DeviceApps.getApp(
                  app.packageName, includeAppIcon: true);
              final icon = info is ApplicationWithIcon ? info.icon : null;
              return MapEntry(app.packageName, icon);
            } catch (_) {
              return MapEntry(app.packageName, null);
            }
          }),
        );

        if (!mounted) break;

        final newIcons = <String, Uint8List>{};
        for (final entry in results) {
          if (entry.value != null) {
            newIcons[entry.key] = entry.value!;
          }
        }

        if (newIcons.isNotEmpty && mounted) {
          setState(() => _iconCache.addAll(newIcons));
          _iconCacheNotifier.value++;
        }

        // Small pause between batches to keep UI responsive
        await Future.delayed(const Duration(milliseconds: 50));
      }
    } finally {
      _iconsLoading = false;
    }
  }

  void _showBlockedAppsDialog() {
    _loadInstalledApps();

    final searchCtrl = TextEditingController();

    showModalBottomSheet(
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
            initialChildSize: 0.75,
            maxChildSize: 0.95,
            minChildSize: 0.4,
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
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Исключить из VPN',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (_blockedApps.isNotEmpty)
                            Text(
                              '${_blockedApps.length} прил. обходят VPN',
                              style: const TextStyle(
                                color: Color(0xFF2ED573),
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                      TextButton(
                        onPressed: () async {
                          await _save();
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                        child: const Text('Готово'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: searchCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    onChanged: (_) => setSheet(() {}),
                    decoration: InputDecoration(
                      hintText: 'Поиск приложений...',
                      hintStyle: TextStyle(color: Colors.grey[500]),
                      prefixIcon: const Icon(
                        Icons.search,
                        size: 20,
                        color: Colors.grey,
                      ),
                      filled: true,
                      fillColor: const Color(0xFF0F0F1A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 10),
                      suffixIcon: searchCtrl.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                searchCtrl.clear();
                                setSheet(() {});
                              },
                            )
                          : null,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Divider(height: 1),
                Expanded(
                  child: ValueListenableBuilder<int>(
                    valueListenable: _iconCacheNotifier,
                    builder: (_, __, ___) {
                      if (_appsLoading && _installedApps.isEmpty) {
                        return const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(),
                              SizedBox(height: 12),
                              Text(
                                'Загрузка приложений...',
                                style: TextStyle(color: Colors.grey),
                              ),
                            ],
                          ),
                        );
                      }

                      final query =
                          searchCtrl.text.trim().toLowerCase();

                      final allApps = query.isEmpty
                          ? _installedApps
                          : _installedApps
                              .where((a) =>
                                  a.appName
                                      .toLowerCase()
                                      .contains(query) ||
                                  a.packageName
                                      .toLowerCase()
                                      .contains(query))
                              .toList();

                      final sorted = [
                        ...allApps.where(
                            (a) => _blockedApps.contains(a.packageName)),
                        ...allApps.where(
                            (a) => !_blockedApps.contains(a.packageName)),
                      ];

                      if (sorted.isEmpty) {
                        return Center(
                          child: Text(
                            query.isNotEmpty
                                ? 'Приложения не найдены'
                                : 'Нет установленных приложений',
                            style: TextStyle(color: Colors.grey[500]),
                          ),
                        );
                      }
                      return ListView.builder(
                        controller: scrollCtrl,
                        itemCount: sorted.length,
                        itemBuilder: (_, i) {
                          final app = sorted[i];
                          final pkg = app.packageName;
                          final isBlocked = _blockedApps.contains(pkg);
                          final icon = _iconCache[pkg];

                          Widget? divider;
                          if (i > 0) {
                            final prev = sorted[i - 1];
                            final prevBlocked =
                                _blockedApps.contains(prev.packageName);
                            if (prevBlocked && !isBlocked) {
                              divider = const Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 4,
                                ),
                                child: Divider(color: Colors.white12),
                              );
                            }
                          }

                          final tile = ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 2,
                            ),
                            leading: SizedBox(
                              width: 38,
                              height: 38,
                              child: icon != null
                                  ? ClipRRect(
                                      borderRadius:
                                          BorderRadius.circular(8),
                                      child: Image.memory(
                                        icon,
                                        fit: BoxFit.cover,
                                        gaplessPlayback: true,
                                      ),
                                    )
                                  : Container(
                                      decoration: BoxDecoration(
                                        color: Colors.white10,
                                        borderRadius:
                                            BorderRadius.circular(8),
                                      ),
                                      child: const Icon(
                                        Icons.android,
                                        size: 22,
                                        color: Colors.white38,
                                      ),
                                    ),
                            ),
                            title: Text(
                              app.appName,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: isBlocked
                                    ? const Color(0xFF2ED573)
                                    : Colors.white,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              pkg,
                              style: TextStyle(
                                fontSize: 10,
                                fontFamily: 'monospace',
                                color: Colors.grey[600],
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Icon(
                              isBlocked
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              color: isBlocked
                                  ? const Color(0xFF2ED573)
                                  : Colors.white24,
                              size: 22,
                            ),
                            onTap: () {
                              setState(() {
                                if (isBlocked) {
                                  _blockedApps.remove(pkg);
                                } else {
                                  _blockedApps.add(pkg);
                                }
                              });
                              setSheet(() {});
                              _save();
                            },
                          );

                          if (divider != null) {
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [divider, tile],
                            );
                          }
                          return tile;
                        },
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


  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF2D2D44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
