import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_v2ray_plus/flutter_v2ray.dart';

/// Редактор JSON-конфига с возможностью подключиться напрямую.
/// flutter_v2ray_plus не имеет checkConfigJson, поэтому валидация
/// выполняется локально (парсинг JSON) + пинг через getServerDelay.
class ConfigEditorPage extends StatefulWidget {
  final String configJson;
  final String configName;

  const ConfigEditorPage({
    super.key,
    required this.configJson,
    required this.configName,
  });

  @override
  State<ConfigEditorPage> createState() => _ConfigEditorPageState();
}

class _ConfigEditorPageState extends State<ConfigEditorPage> {
  late TextEditingController _ctrl;
  bool _isValid = true;
  String _validationMsg = '';
  bool _isValidating = false;
  bool _isConnecting = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _formatJson(widget.configJson));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _formatJson(String json) {
    try {
      return const JsonEncoder.withIndent('  ')
          .convert(jsonDecode(json));
    } catch (_) {
      return json;
    }
  }

  String? _compact() {
    try {
      return jsonEncode(jsonDecode(_ctrl.text));
    } catch (e) {
      _snack('Неверный JSON: $e');
      return null;
    }
  }

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

  // ── Actions ────────────────────────────────────────────────────────────────

  /// Валидация: проверяем JSON-синтаксис + пинг через getServerDelay.
  Future<void> _validate() async {
    final compact = _compact();
    if (compact == null) return;
    setState(() {
      _isValidating = true;
      _validationMsg = '';
    });
    try {
      final ms =
      await FlutterV2ray().getServerDelay(config: compact);
      if (!mounted) return;
      setState(() {
        _isValid = ms >= 0;
        _validationMsg = ms >= 0
            ? 'Конфиг рабочий ✅  (пинг: ${ms}ms)'
            : 'Сервер недоступен ❌';
        _isValidating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isValid = false;
        _validationMsg = 'Ошибка валидации: $e';
        _isValidating = false;
      });
    }
  }

  Future<void> _connect() async {
    final compact = _compact();
    if (compact == null) return;

    if (!await FlutterV2ray().requestPermission()) {
      _snack('VPN permission denied');
      return;
    }

    setState(() => _isConnecting = true);
    try {
      await FlutterV2ray().startVless(
        remark: widget.configName,
        config: compact,
        notificationDisconnectButtonName: 'Отключить',
        proxyOnly: false,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _snack('Ошибка: $e');
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  void _copyJson() {
    Clipboard.setData(ClipboardData(text: _ctrl.text));
    _snack('JSON скопирован');
  }

  void _format() {
    final f = _formatJson(_ctrl.text);
    _ctrl.text = f;
    _ctrl.selection =
        TextSelection.fromPosition(TextPosition(offset: f.length));
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.configName, overflow: TextOverflow.ellipsis),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
              icon: const Icon(Icons.format_align_left),
              onPressed: _format,
              tooltip: 'Форматировать'),
          IconButton(
              icon: const Icon(Icons.copy),
              onPressed: _copyJson,
              tooltip: 'Копировать'),
          IconButton(
            icon: _isValidating
                ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check_circle_outline),
            onPressed: _isValidating ? null : _validate,
            tooltip: 'Валидировать (пинг)',
          ),
        ],
      ),
      body: Column(
        children: [
          if (_validationMsg.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 8),
              color: _isValid
                  ? const Color(0xFF2ED573).withValues(alpha: 0.15)
                  : const Color(0xFFE74C3C).withValues(alpha: 0.15),
              child: Row(children: [
                Icon(
                  _isValid ? Icons.check_circle : Icons.error,
                  color: _isValid
                      ? const Color(0xFF2ED573)
                      : const Color(0xFFE74C3C),
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_validationMsg,
                      style: TextStyle(
                          color: _isValid
                              ? const Color(0xFF2ED573)
                              : const Color(0xFFE74C3C),
                          fontSize: 13)),
                ),
              ]),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: TextField(
                controller: _ctrl,
                maxLines: null,
                expands: true,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.5),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.all(8),
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _isConnecting ? null : _connect,
            icon: _isConnecting
                ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.play_arrow),
            label: Text(_isConnecting
                ? 'Подключение…'
                : 'Подключить с этим конфигом'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF6C5CE7),
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
      ),
    );
  }
}