import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:v2ray_box/v2ray_box.dart';

const _kTemplate = '''{
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "YOUR_SERVER_IP",
          "port": 443,
          "users": [{"id": "YOUR_UUID", "flow": "xtls-rprx-vision", "encryption": "none"}]
        }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "YOUR_SNI",
          "fingerprint": "chrome",
          "shortId": "",
          "spiderX": "/"
        }
      }
    },
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"domain": ["geosite:category-ru", "domain:ru", "domain:su"], "outboundTag": "direct"},
      {"ip": ["geoip:private"], "outboundTag": "block"}
    ]
  }
}''';

class JsonTesterPage extends StatefulWidget {
  final V2rayBox v2rayBox;

  const JsonTesterPage({super.key, required this.v2rayBox});

  @override
  State<JsonTesterPage> createState() => _JsonTesterPageState();
}

class _JsonTesterPageState extends State<JsonTesterPage> {
  late TextEditingController _ctrl;
  StreamSubscription<VpnStatus>? _statusSub;
  VpnStatus _status = VpnStatus.stopped;

  bool _isValidating = false;
  bool _isConnecting = false;
  bool _isValid = true;
  String _validationMsg = '';

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _kTemplate);
    _statusSub = widget.v2rayBox.watchStatus().listen((s) {
      if (mounted) setState(() => _status = s);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _statusSub?.cancel();
    super.dispose();
  }

  String _formatJson(String text) {
    try {
      final obj = jsonDecode(text);
      return const JsonEncoder.withIndent('  ').convert(obj);
    } catch (_) {
      return text;
    }
  }

  String? _compactJson() {
    try {
      return jsonEncode(jsonDecode(_ctrl.text));
    } catch (e) {
      _snack('Invalid JSON syntax: $e');
      return null;
    }
  }

  Future<void> _validate() async {
    final compact = _compactJson();
    if (compact == null) return;
    setState(() => _isValidating = true);
    try {
      final error = await widget.v2rayBox.checkConfigJson(compact);
      setState(() {
        _isValid = error.isEmpty;
        _validationMsg = error.isEmpty ? 'Config is valid ✅' : error;
      });
    } catch (e) {
      setState(() {
        _isValid = false;
        _validationMsg = 'Validation error: $e';
      });
    } finally {
      if (mounted) setState(() => _isValidating = false);
    }
  }

  Future<void> _connect() async {
    final compact = _compactJson();
    if (compact == null) return;
    setState(() => _isConnecting = true);
    try {
      final ok = await widget.v2rayBox.connectWithJson(compact, name: 'JSON Test');
      _snack(ok ? 'Connected ✅' : 'Failed to connect ❌');
    } catch (e) {
      _snack('Error: $e');
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  Future<void> _disconnect() async {
    try {
      await widget.v2rayBox.disconnect();
      _snack('Disconnected');
    } catch (e) {
      _snack('Error: $e');
    }
  }

  void _formatText() {
    final formatted = _formatJson(_ctrl.text);
    _ctrl.text = formatted;
    _ctrl.selection = TextSelection.fromPosition(TextPosition(offset: formatted.length));
  }

  void _clear() {
    _ctrl.clear();
    setState(() {
      _validationMsg = '';
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _ctrl.text = data!.text!;
      _ctrl.selection = TextSelection.fromPosition(TextPosition(offset: _ctrl.text.length));
    }
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

  Color get _statusColor {
    switch (_status) {
      case VpnStatus.connected:
        return const Color(0xFF2ED573);
      case VpnStatus.connecting:
        return const Color(0xFFFFBE76);
      case VpnStatus.stopped:
        return const Color(0xFFE74C3C);
    }
  }

  String get _statusLabel {
    switch (_status) {
      case VpnStatus.connected:
        return 'Connected';
      case VpnStatus.connecting:
        return 'Connecting…';
      case VpnStatus.stopped:
        return 'Stopped';
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _isValidating || _isConnecting;

    return Scaffold(
      appBar: AppBar(
        title: const Text('JSON Config Tester'),
        backgroundColor: Colors.transparent,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: _statusColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(_statusLabel, style: TextStyle(color: _statusColor, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_validationMsg.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: _isValid
                  ? const Color(0xFF2ED573).withOpacity(0.2)
                  : const Color(0xFFE74C3C).withOpacity(0.2),
              child: Row(
                children: [
                  Icon(
                    _isValid ? Icons.check_circle : Icons.error,
                    color: _isValid ? const Color(0xFF2ED573) : const Color(0xFFE74C3C),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _validationMsg,
                      style: TextStyle(
                        color: _isValid ? const Color(0xFF2ED573) : const Color(0xFFE74C3C),
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: TextField(
                controller: _ctrl,
                maxLines: null,
                expands: true,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.5),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.all(8),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: busy ? null : _paste,
                          icon: const Icon(Icons.content_paste, size: 18),
                          label: const Text('Paste'),
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: busy ? null : _formatText,
                          icon: const Icon(Icons.format_align_left, size: 18),
                          label: const Text('Format'),
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: busy ? null : _clear,
                          icon: const Icon(Icons.clear, size: 18),
                          label: const Text('Clear'),
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isValidating ? null : _validate,
                          icon: _isValidating
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.check_circle_outline, size: 18),
                          label: Text(_isValidating ? 'Validating…' : 'Validate'),
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: busy ? null : _disconnect,
                          icon: const Icon(Icons.stop_circle_outlined, size: 18),
                          label: const Text('Disconnect'),
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _isConnecting ? null : _connect,
                    icon: _isConnecting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.play_arrow),
                    label: Text(_isConnecting ? 'Connecting…' : 'Connect'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF6C5CE7),
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
