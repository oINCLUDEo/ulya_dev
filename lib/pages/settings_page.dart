import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_v2ray_plus/flutter_v2ray.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../services/apps_repository.dart';
import '../utils/core_info_parser.dart';
import '../main.dart' show DS;

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _proxyOnly = false;
  List<String> _dnsServers = ['8.8.8.8', '114.114.114.114'];
  bool _useCustomDns = false;
  Set<String> _blockedApps = {};
  bool _fragmentEnabled = false;
  String _pingTestUrl = 'https://www.gstatic.com/generate_204';
  CoreInfo _coreInfo = CoreInfo(
      name: 'Xray', version: '…',
      architecture: '', goVersion: '', fullString: '');
  bool _loading = true;

  late final FlutterV2ray _v2ray;

  static const _kProxyOnly   = 'settings_proxy_only';
  static const _kCustomDns   = 'settings_custom_dns_enabled';
  static const _kDnsServers  = 'settings_dns_servers';
  static const _kBlockedApps = 'settings_blocked_apps';
  static const _kFragment    = 'tls_fragment_enabled';
  static const _kPingUrl     = 'settings_ping_url';

  @override
  void initState() {
    super.initState();
    _v2ray = FlutterV2ray();
    _load();
    _loadCoreInfo();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      AppsRepository.instance.preload();
    }
  }

  Future<void> _loadCoreInfo() async {
    try {
      final v = await _v2ray.getCoreVersion();
      if (mounted) setState(() => _coreInfo = CoreInfo.fromString(v));
    } catch (_) {}
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    _proxyOnly      = p.getBool(_kProxyOnly)  ?? false;
    _useCustomDns   = p.getBool(_kCustomDns)  ?? false;
    _fragmentEnabled = p.getBool(_kFragment)  ?? false;
    _pingTestUrl    = p.getString(_kPingUrl)  ?? 'https://www.gstatic.com/generate_204';

    final dnsRaw = p.getString(_kDnsServers);
    if (dnsRaw != null) {
      try { _dnsServers = List<String>.from(jsonDecode(dnsRaw) as List); } catch (_) {}
    }
    final blockedRaw = p.getString(_kBlockedApps);
    if (blockedRaw != null) {
      try { _blockedApps = Set<String>.from(jsonDecode(blockedRaw) as List); } catch (_) {}
    } else {
      _blockedApps = Set<String>.from(AppConfig.defaultBlockedApps);
      await p.setString(_kBlockedApps, jsonEncode(_blockedApps.toList()));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kProxyOnly, _proxyOnly);
    await p.setBool(_kCustomDns, _useCustomDns);
    await p.setBool(_kFragment, _fragmentEnabled);
    await p.setString(_kPingUrl, _pingTestUrl);
    await p.setString(_kDnsServers, jsonEncode(_dnsServers));
    await p.setString(_kBlockedApps, jsonEncode(_blockedApps.toList()));
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
          backgroundColor: DS.surface0,
          body: Center(child: CircularProgressIndicator(color: DS.violet)));
    }
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: DS.surface0,
      body: CustomScrollView(
        slivers: [
          // Header
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, top + 20, 20, 24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Настройки', style: TextStyle(
                    color: DS.textPrimary, fontSize: 32,
                    fontWeight: FontWeight.w800, letterSpacing: -0.5, height: 1)),
                const SizedBox(height: 6),
                const Text('Параметры приложения',
                    style: TextStyle(color: DS.textSecondary, fontSize: 15)),
              ]),
            ),
          ),

          // Core card
          _pad(_CoreCard(info: _coreInfo)),
          _gap,

          // Connection mode
          _pad(_Section(
            title: 'Режим подключения',
            icon: Icons.vpn_lock_rounded,
            child: Column(children: [
              _RadioTile<bool>(
                  value: false, groupValue: _proxyOnly,
                  label: 'VPN-туннель',
                  subtitle: 'Весь трафик проходит через VPN',
                  onChanged: (v) async { setState(() => _proxyOnly = v!); await _save(); }),
              const Divider(height: 1, color: DS.border),
              _RadioTile<bool>(
                  value: true, groupValue: _proxyOnly,
                  label: 'Только прокси',
                  subtitle: 'SOCKS5/HTTP без VPN-туннеля. Порт: 10808',
                  onChanged: (v) async { setState(() => _proxyOnly = v!); await _save(); }),
            ]),
          )),
          _gap,

          // Excluded apps (Android only)
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) ...[
            _pad(_Section(
              title: 'Исключение приложений',
              icon: Icons.apps_rounded,
              child: _SettingsTile(
                icon: Icons.android_rounded,
                label: 'Приложения, обходящие VPN',
                value: _blockedApps.isEmpty
                    ? 'Все приложения проходят через VPN'
                    : '${_blockedApps.length} приложений исключено',
                onTap: _showBlockedAppsSheet,
              ),
            )),
            _gap,
          ],

          // DPI bypass
          _pad(_Section(
            title: 'Обход фильтрации',
            icon: Icons.security_rounded,
            child: _SwitchTile(
              icon: Icons.shield_rounded,
              label: 'TLS Fragment',
              subtitle: 'Разбивает TLS ClientHello на фрагменты',
              value: _fragmentEnabled,
              onChanged: (v) async {
                setState(() => _fragmentEnabled = v);
                await _save();
                _snack(v ? 'TLS Fragment включён' : 'TLS Fragment выключен');
              },
            ),
          )),
          _gap,

          // DNS
          _pad(_Section(
            title: 'DNS-серверы',
            icon: Icons.dns_rounded,
            child: Column(children: [
              _SwitchTile(
                icon: Icons.tune_rounded,
                label: 'Свои DNS-серверы',
                subtitle: 'По умолчанию: 8.8.8.8, 114.114.114.114',
                value: _useCustomDns,
                onChanged: (v) async { setState(() => _useCustomDns = v); await _save(); },
              ),
              if (_useCustomDns) ...[
                const Divider(height: 1, color: DS.border),
                ..._dnsServers.asMap().entries.map((e) => Column(children: [
                  _DnsTile(index: e.key, server: e.value,
                      onEdit: () => _editDns(e.key, e.value)),
                  if (e.key < _dnsServers.length - 1)
                    const Divider(height: 1, indent: 16, endIndent: 16, color: DS.border),
                ])),
                const Divider(height: 1, color: DS.border),
                // Add button
                GestureDetector(
                  onTap: () => _editDns(null, ''),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    child: Row(children: [
                      Container(width: 36, height: 36,
                          decoration: BoxDecoration(
                              color: DS.emerald.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(10)),
                          child: const Icon(Icons.add_rounded, color: DS.emerald, size: 18)),
                      const SizedBox(width: 12),
                      const Text('Добавить DNS-сервер',
                          style: TextStyle(color: DS.emerald, fontSize: 14, fontWeight: FontWeight.w500)),
                    ]),
                  ),
                ),
                const Divider(height: 1, color: DS.border),
                // Presets
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('БЫСТРЫЙ ВЫБОР', style: TextStyle(
                        color: DS.textMuted, fontSize: 10,
                        fontWeight: FontWeight.w700, letterSpacing: 1.0)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 6, children: [
                      _dnsPreset('Google',     ['8.8.8.8', '8.8.4.4']),
                      _dnsPreset('Cloudflare', ['1.1.1.1', '1.0.0.1']),
                      _dnsPreset('AdGuard',    ['94.140.14.14', '94.140.15.15']),
                      _dnsPreset('Quad9',      ['9.9.9.9', '149.112.112.112']),
                    ]),
                  ]),
                ),
              ],
            ]),
          )),
          _gap,

          // Advanced
          _pad(_Section(
            title: 'Дополнительно',
            icon: Icons.tune_rounded,
            child: _SettingsTile(
              icon: Icons.network_ping_rounded,
              label: 'URL для проверки пинга',
              value: _pingTestUrl,
              onTap: _showPingUrlDialog,
            ),
          )),

          const SliverPadding(padding: EdgeInsets.only(bottom: 110)),
        ],
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  SliverToBoxAdapter _pad(Widget child) => SliverToBoxAdapter(
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: child));

  static const _gap = SliverPadding(padding: EdgeInsets.only(top: 12));

  Widget _dnsPreset(String label, List<String> servers) => GestureDetector(
    onTap: () async {
      setState(() => _dnsServers = List.from(servers));
      await _save();
      _snack('DNS: $label (${servers.join(', ')})');
    },
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
          color: DS.surface2, borderRadius: BorderRadius.circular(20),
          border: Border.all(color: DS.border)),
      child: Text(label, style: const TextStyle(
          color: DS.textSecondary, fontSize: 12, fontWeight: FontWeight.w500)),
    ),
  );

  // ── Dialogs ────────────────────────────────────────────────────────────────
  void _showPingUrlDialog() {
    final ctrl = TextEditingController(text: _pingTestUrl);
    _dialog(
      title: 'URL для проверки пинга',
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: ctrl, keyboardType: TextInputType.url,
            style: const TextStyle(color: DS.textPrimary)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 6, children: [
          ActionChip(label: const Text('gstatic'),
              onPressed: () => ctrl.text = 'https://www.gstatic.com/generate_204'),
          ActionChip(label: const Text('Cloudflare'),
              onPressed: () => ctrl.text = 'http://cp.cloudflare.com'),
          ActionChip(label: const Text('Google'),
              onPressed: () => ctrl.text = 'http://www.google.com/generate_204'),
        ]),
      ]),
      onSave: () async {
        final url = ctrl.text.trim();
        if (url.isNotEmpty) { setState(() => _pingTestUrl = url); await _save(); }
      },
    );
  }

  void _editDns(int? index, String initial) {
    final ctrl = TextEditingController(text: initial);
    _dialog(
      title: index == null ? 'Добавить DNS' : 'Изменить DNS',
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: DS.textPrimary, fontFamily: 'monospace'),
          decoration: const InputDecoration(
              hintText: '1.1.1.1',
              prefixIcon: Icon(Icons.dns_rounded, color: DS.textMuted)),
        ),
        if (index != null) ...[
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () async {
              setState(() => _dnsServers.removeAt(index));
              await _save();
              if (mounted) Navigator.pop(context);
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(
                  color: DS.rose.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(DS.radiusSm),
                  border: Border.all(color: DS.rose.withValues(alpha: 0.28))),
              child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.delete_outline_rounded, color: DS.rose, size: 16),
                SizedBox(width: 6),
                Text('Удалить', style: TextStyle(
                    color: DS.rose, fontWeight: FontWeight.w600, fontSize: 13)),
              ]),
            ),
          ),
        ],
      ]),
      onSave: () async {
        final val = ctrl.text.trim();
        if (val.isNotEmpty) {
          setState(() { index == null ? _dnsServers.add(val) : _dnsServers[index] = val; });
          await _save();
        }
      },
    );
  }

  void _dialog({required String title, required Widget content,
    required Future<void> Function() onSave}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(
            color: DS.textPrimary, fontWeight: FontWeight.w700)),
        content: content,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена', style: TextStyle(color: DS.textSecondary))),
          TextButton(
              onPressed: () async { await onSave(); if (ctx.mounted) Navigator.pop(ctx); },
              child: const Text('Сохранить',
                  style: TextStyle(color: DS.violet, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }

  void _showBlockedAppsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => BlockedAppsSheet(
        initialBlocked: Set<String>.from(_blockedApps),
        onSave: (updated) { setState(() => _blockedApps = updated); _save(); },
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16)));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section container
// ─────────────────────────────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  const _Section({required this.title, required this.icon, required this.child});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 8),
        child: Row(children: [
          Icon(icon, size: 13, color: DS.textMuted),
          const SizedBox(width: 5),
          Text(title.toUpperCase(), style: const TextStyle(
              color: DS.textMuted, fontSize: 10,
              fontWeight: FontWeight.w700, letterSpacing: 1.0)),
        ]),
      ),
      Container(
        decoration: BoxDecoration(
          color: DS.surface1,
          borderRadius: BorderRadius.circular(DS.radius),
          border: Border.all(color: DS.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Row widgets
// ─────────────────────────────────────────────────────────────────────────────

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;
  const _SettingsTile({required this.icon, required this.label, required this.value, this.onTap});

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(children: [
          Container(width: 36, height: 36,
              decoration: BoxDecoration(
                  color: DS.violet.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: DS.violet, size: 18)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(
                color: DS.textPrimary, fontSize: 14, fontWeight: FontWeight.w500)),
            const SizedBox(height: 2),
            Text(value, style: const TextStyle(color: DS.textSecondary, fontSize: 12),
                overflow: TextOverflow.ellipsis, maxLines: 1),
          ])),
          if (onTap != null)
            const Icon(Icons.chevron_right_rounded, color: DS.textMuted, size: 18),
        ]),
      ),
    ),
  );
}

class _SwitchTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _SwitchTile({required this.icon, required this.label, required this.subtitle,
    required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(children: [
      AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 36, height: 36,
          decoration: BoxDecoration(
              color: (value ? DS.violet : DS.textMuted).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: value ? DS.violet : DS.textMuted, size: 18)),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(
            color: DS.textPrimary, fontSize: 14, fontWeight: FontWeight.w500)),
        Text(subtitle, style: const TextStyle(color: DS.textSecondary, fontSize: 12)),
      ])),
      Switch(value: value, onChanged: onChanged),
    ]),
  );
}

class _RadioTile<T> extends StatelessWidget {
  final T value;
  final T groupValue;
  final String label;
  final String subtitle;
  final ValueChanged<T?> onChanged;
  const _RadioTile({required this.value, required this.groupValue,
    required this.label, required this.subtitle, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final sel = value == groupValue;
    return GestureDetector(
      onTap: () => onChanged(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 20, height: 20,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: sel ? DS.violet : DS.border,
                    width: sel ? 5.5 : 1.5),
                color: sel ? DS.surface0 : Colors.transparent),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(
                color: sel ? DS.textPrimary : DS.textSecondary,
                fontSize: 14, fontWeight: sel ? FontWeight.w600 : FontWeight.w400)),
            Text(subtitle, style: const TextStyle(color: DS.textSecondary, fontSize: 12)),
          ])),
        ]),
      ),
    );
  }
}

class _DnsTile extends StatelessWidget {
  final int index;
  final String server;
  final VoidCallback onEdit;
  const _DnsTile({required this.index, required this.server, required this.onEdit});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(children: [
      Container(width: 24, height: 24,
          decoration: BoxDecoration(
              color: DS.violet.withValues(alpha: 0.12), shape: BoxShape.circle),
          child: Center(child: Text('${index + 1}', style: const TextStyle(
              color: DS.violet, fontSize: 11, fontWeight: FontWeight.w700)))),
      const SizedBox(width: 12),
      Expanded(child: Text(server, style: const TextStyle(
          color: DS.textPrimary, fontSize: 14, fontFamily: 'monospace'))),
      GestureDetector(
        onTap: onEdit,
        child: Container(
            width: 32, height: 32,
            decoration: BoxDecoration(color: DS.surface2,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: DS.border)),
            child: const Icon(Icons.edit_rounded, size: 14, color: DS.textSecondary)),
      ),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Core card
// ─────────────────────────────────────────────────────────────────────────────

class _CoreCard extends StatelessWidget {
  final CoreInfo info;
  const _CoreCard({required this.info});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: DS.surface1,
      borderRadius: BorderRadius.circular(DS.radius),
      border: Border.all(color: DS.border),
    ),
    child: Row(children: [
      Container(width: 44, height: 44,
          decoration: BoxDecoration(
              color: DS.violet.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12)),
          child: const Icon(Icons.memory_rounded, color: DS.violet, size: 22)),
      const SizedBox(width: 14),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('${info.name}-core', style: const TextStyle(
              color: DS.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
          if (info.architecture.isNotEmpty) ...[
            const SizedBox(width: 6),
            Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: DS.surface2,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: DS.border)),
                child: Text(info.shortArch, style: const TextStyle(
                    color: DS.textMuted, fontSize: 9, fontWeight: FontWeight.w600))),
          ],
        ]),
        const SizedBox(height: 5),
        Row(children: [
          Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                  color: DS.emerald.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20)),
              child: Text('v${info.version}', style: const TextStyle(
                  color: DS.emerald, fontSize: 11, fontWeight: FontWeight.w600))),
          if (info.goVersion.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(info.goVersionShort,
                style: const TextStyle(color: DS.textMuted, fontSize: 11)),
          ],
        ]),
      ])),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Blocked apps bottom sheet
// ─────────────────────────────────────────────────────────────────────────────

class BlockedAppsSheet extends StatefulWidget {
  final Set<String> initialBlocked;
  final void Function(Set<String>) onSave;
  const BlockedAppsSheet({super.key, required this.initialBlocked, required this.onSave});

  @override
  State<BlockedAppsSheet> createState() => _BlockedAppsSheetState();
}

class _BlockedAppsSheetState extends State<BlockedAppsSheet> {
  late Set<String> _blocked;
  List<Map<String, dynamic>> _apps = [];
  List<Map<String, dynamic>> _filtered = [];
  final _searchCtrl = TextEditingController();
  bool _appsLoading = true;

  @override
  void initState() {
    super.initState();
    _blocked = Set.from(widget.initialBlocked);
    _loadApps();
  }

  Future<void> _loadApps() async {
    await AppsRepository.instance.preload();
    if (!mounted) return;
    _apps = AppsRepository.instance.apps ?? [];
    _filtered = _sort(_apps);
    setState(() => _appsLoading = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppsRepository.instance.loadIconsGradually(_blocked);
    });
  }

  @override
  void dispose() {
    AppsRepository.instance.cancelIconLoading();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _search(String q) {
    final l = q.toLowerCase();
    final base = l.isEmpty ? _apps : _apps.where((a) =>
    (a['appName'] as String).toLowerCase().contains(l) ||
        (a['packageName'] as String).toLowerCase().contains(l)).toList();
    setState(() => _filtered = _sort(base));
  }

  List<Map<String, dynamic>> _sort(List<Map<String, dynamic>> list) {
    final blocked = list.where((a) => _blocked.contains(a['packageName']));
    final rest    = list.where((a) => !_blocked.contains(a['packageName']));
    return [...blocked, ...rest];
  }

  void _toggle(String pkg) {
    setState(() {
      _blocked.contains(pkg) ? _blocked.remove(pkg) : _blocked.add(pkg);
      _filtered = _sort(_filtered);
    });
    widget.onSave(_blocked);
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (_, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: DS.surface1,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(children: [
          const SizedBox(height: 12),
          Container(width: 40, height: 4,
              decoration: BoxDecoration(color: DS.border, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 16),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Исключить приложения', style: TextStyle(
                    color: DS.textPrimary, fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text('${_blocked.length} исключено',
                    style: const TextStyle(color: DS.textSecondary, fontSize: 12)),
              ])),
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(
                      backgroundColor: DS.violet.withValues(alpha: 0.08),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                  child: const Text('Готово', style: TextStyle(fontWeight: FontWeight.w600))),
            ]),
          ),
          const SizedBox(height: 12),

          // Search
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _searchCtrl,
              onChanged: _search,
              style: const TextStyle(color: DS.textPrimary),
              decoration: const InputDecoration(
                  hintText: 'Поиск…',
                  prefixIcon: Icon(Icons.search_rounded, color: DS.textMuted),
                  contentPadding: EdgeInsets.symmetric(vertical: 10)),
            ),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1, color: DS.border),

          // App list
          Expanded(
            child: Stack(children: [
              ValueListenableBuilder<int>(
                valueListenable: AppsRepository.instance.iconsVersion,
                builder: (_, __, ___) => ListView.builder(
                  controller: scrollCtrl,
                  itemCount: _filtered.length,
                  itemBuilder: (_, i) {
                    final app = _filtered[i];
                    final pkg = app['packageName'] as String;
                    final name = app['appName'] as String;
                    final isBlocked = _blocked.contains(pkg);
                    final icon = AppsRepository.instance.icons[pkg];
                    return ListTile(
                      onTap: () => _toggle(pkg),
                      leading: icon != null
                          ? Image.memory(icon, width: 32, height: 32, gaplessPlayback: true)
                          : Container(width: 32, height: 32,
                          decoration: BoxDecoration(
                              color: DS.surface2,
                              borderRadius: BorderRadius.circular(8)),
                          child: const Icon(Icons.android_rounded, size: 20, color: DS.textMuted)),
                      title: Text(name,
                          style: const TextStyle(color: DS.textPrimary, fontSize: 14)),
                      subtitle: Text(pkg, style: const TextStyle(
                          color: DS.textMuted, fontSize: 11, fontFamily: 'monospace')),
                      trailing: Checkbox(value: isBlocked, onChanged: (_) => _toggle(pkg)),
                    );
                  },
                ),
              ),
              if (_appsLoading)
                const Align(alignment: Alignment.bottomCenter,
                    child: Padding(padding: EdgeInsets.only(bottom: 20),
                        child: CircularProgressIndicator(strokeWidth: 2, color: DS.violet))),
            ]),
          ),
        ]),
      ),
    );
  }
}
