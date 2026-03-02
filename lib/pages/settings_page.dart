import 'dart:convert';

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

  void _showBlockedAppsDialog() {
    final ctrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.92,
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
                    Text(
                      'Исключить приложения',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
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
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  'Приложения из этого списка будут обходить VPN-туннель '
                  '(параметр blockedApps).',
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
              ),
              // Поле добавления пакета
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: ctrl,
                        decoration: InputDecoration(
                          hintText: 'com.example.app',
                          filled: true,
                          fillColor: const Color(0xFF0F0F1A),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(
                        Icons.add_circle,
                        color: Color(0xFF2ED573),
                      ),
                      onPressed: () {
                        final pkg = ctrl.text.trim();
                        if (pkg.isNotEmpty && !_blockedApps.contains(pkg)) {
                          setState(() => _blockedApps.add(pkg));
                          setSheet(() {});
                          ctrl.clear();
                        }
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              // Кнопка выбора из установленных приложений
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.apps, size: 18),
                    label: const Text('Выбрать из установленных'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF2ED573),
                      side: const BorderSide(color: Color(0xFF2ED573)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: () async {
                      final added =
                          await _showInstalledAppsPicker(ctx);
                      if (added != null && added.isNotEmpty) {
                        setState(() => _blockedApps.addAll(added));
                        setSheet(() {});
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Divider(height: 1),
              Expanded(
                child: _blockedApps.isEmpty
                    ? Center(
                        child: Text(
                          'Список пуст — все приложения идут через VPN',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 13,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView(
                        controller: scrollCtrl,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        children: _blockedApps.map((pkg) {
                          return Card(
                            margin: const EdgeInsets.only(bottom: 4),
                            child: ListTile(
                              dense: true,
                              leading: const Icon(
                                Icons.android,
                                size: 18,
                                color: Colors.white38,
                              ),
                              title: Text(
                                pkg,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                ),
                              ),
                              trailing: IconButton(
                                icon: const Icon(
                                  Icons.remove_circle_outline,
                                  size: 18,
                                  color: Color(0xFFE74C3C),
                                ),
                                onPressed: () {
                                  setState(() => _blockedApps.remove(pkg));
                                  setSheet(() {});
                                },
                              ),
                            ),
                          );
                        }).toList(),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Shows a picker dialog for installed user apps.
  ///
  /// Returns the set of package names that the user chose to add,
  /// or `null` if the dialog was dismissed.
  Future<Set<String>?> _showInstalledAppsPicker(BuildContext ctx) async {
    // Load the list of installed user apps.
    List<Application> apps;
    try {
      apps = await DeviceApps.getInstalledApplications(
        onlyAppsWithLaunchIntent: true,
        includeSystemApps: false,
        includeAppIcons: true,
      );
      apps.sort((a, b) => a.appName.compareTo(b.appName));
    } catch (e) {
      debugPrint('_showInstalledAppsPicker: $e');
      apps = [];
    }

    if (!ctx.mounted) return null;

    // Track the user's selections (pre-mark already-blocked apps).
    final selected = <String>{..._blockedApps};
    final filterCtrl = TextEditingController();

    return showDialog<Set<String>>(
      context: ctx,
      builder: (dCtx) => StatefulBuilder(
        builder: (dCtx, setDlg) {
          final query = filterCtrl.text.trim().toLowerCase();
          final visible = query.isEmpty
              ? apps
              : apps
                  .where((a) =>
                      a.appName.toLowerCase().contains(query) ||
                      a.packageName.toLowerCase().contains(query))
                  .toList();

          return AlertDialog(
            backgroundColor: const Color(0xFF1A1A2E),
            title: const Text('Установленные приложения'),
            content: SizedBox(
              width: double.maxFinite,
              height: 480,
              child: Column(
                children: [
                  TextField(
                    controller: filterCtrl,
                    onChanged: (_) => setDlg(() {}),
                    decoration: InputDecoration(
                      hintText: 'Поиск по названию или пакету',
                      filled: true,
                      fillColor: const Color(0xFF0F0F1A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                      prefixIcon: const Icon(Icons.search, size: 18),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: apps.isEmpty
                        ? const Center(
                            child: Text(
                              'Список приложений пуст',
                              style: TextStyle(color: Colors.grey),
                            ),
                          )
                        : ListView.builder(
                            itemCount: visible.length,
                            itemBuilder: (_, i) {
                              final app = visible[i];
                              final alreadyAdded =
                                  _blockedApps.contains(app.packageName);
                              final isChecked =
                                  selected.contains(app.packageName);
                              return CheckboxListTile(
                                dense: true,
                                value: isChecked,
                                onChanged: alreadyAdded
                                    ? null
                                    : (v) {
                                        setDlg(() {
                                          if (v == true) {
                                            selected.add(app.packageName);
                                          } else {
                                            selected.remove(app.packageName);
                                          }
                                        });
                                      },
                                secondary: app is ApplicationWithIcon
                                    ? ClipRRect(
                                        borderRadius:
                                            BorderRadius.circular(6),
                                        child: Image.memory(
                                          app.icon,
                                          width: 32,
                                          height: 32,
                                          gaplessPlayback: true,
                                        ),
                                      )
                                    : const Icon(Icons.android,
                                        size: 32,
                                        color: Colors.white38),
                                title: Text(
                                  app.appName,
                                  style: const TextStyle(fontSize: 13),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  app.packageName,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 10,
                                    color: Colors.grey[500],
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dCtx),
                child: const Text('Отмена'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(dCtx, selected),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2ED573),
                  foregroundColor: Colors.black,
                ),
                child: const Text('Добавить'),
              ),
            ],
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
