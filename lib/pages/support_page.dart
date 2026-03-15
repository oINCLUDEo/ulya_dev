import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';

import '../main.dart' show DS;
import '../services/app_logger.dart';
import '../services/support_api_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

String _pad(int n) => n.toString().padLeft(2, '0');

String _fmtTs(int ts) {
  if (ts == 0) return '—';
  final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000).toLocal();
  return '${_pad(dt.day)}.${_pad(dt.month)}.${dt.year.toString().substring(2)} ${_pad(dt.hour)}:${_pad(dt.minute)}';
}

String _fmtTsShort(int ts) {
  if (ts == 0) return '—';
  final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000).toLocal();
  return '${_pad(dt.day)}.${_pad(dt.month)} ${_pad(dt.hour)}:${_pad(dt.minute)}';
}

Color _statusColor(String status) {
  switch (status) {
    case 'open':    return DS.emerald;
    case 'pending': return DS.amber;
    case 'closed':  return DS.textMuted;
    default:        return DS.textSecondary;
  }
}

String _statusLabel(String status) {
  switch (status) {
    case 'open':    return 'Открыт';
    case 'pending': return 'Ожидает';
    case 'closed':  return 'Закрыт';
    default:        return status;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SupportPage — ticket list
// ─────────────────────────────────────────────────────────────────────────────

class SupportPage extends StatefulWidget {
  const SupportPage({super.key});

  @override
  State<SupportPage> createState() => _SupportPageState();
}

class _SupportPageState extends State<SupportPage> {
  List<SupportTicket> _tickets = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final tickets = await SupportApiService.getTickets();
      if (mounted) setState(() { _tickets = tickets; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  void _openCreate() async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const _CreateTicketPage()),
    );
    if (created == true) _load();
  }

  void _openDetail(SupportTicket ticket) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _TicketDetailPage(ticket: ticket)),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: DS.surface0,
      body: RefreshIndicator(
        color: DS.violet,
        backgroundColor: DS.surface2,
        onRefresh: _load,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // ── Header ───────────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, top + 20, 20, 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Поддержка', style: TextStyle(
                            color: DS.textPrimary, fontSize: 32,
                            fontWeight: FontWeight.w800, letterSpacing: -0.5, height: 1,
                          )),
                          const SizedBox(height: 6),
                          Text(
                            _tickets.isEmpty && !_loading
                                ? 'Обращений пока нет'
                                : '${_tickets.length} ${_pluralTickets(_tickets.length)}',
                            style: const TextStyle(color: DS.textSecondary, fontSize: 15),
                          ),
                        ],
                      ),
                    ),
                    // New ticket button
                    GestureDetector(
                      onTap: _openCreate,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [DS.violet, DS.violetDim],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(DS.radiusSm),
                          boxShadow: [
                            BoxShadow(
                              color: DS.violet.withValues(alpha: 0.3),
                              blurRadius: 12, offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.add_rounded, color: Colors.white, size: 16),
                          SizedBox(width: 5),
                          Text('Новое', style: TextStyle(
                              color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                        ]),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SliverPadding(padding: EdgeInsets.only(top: 20)),

            // ── Content ──────────────────────────────────────────────────
            if (_loading)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator(
                    color: DS.violet, strokeWidth: 2.5)),
              )
            else if (_error != null)
              SliverFillRemaining(child: _ErrorView(message: _error!, onRetry: _load))
            else if (_tickets.isEmpty)
                SliverFillRemaining(child: _EmptyView(onNew: _openCreate))
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                          (_, i) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _TicketCard(
                          ticket: _tickets[i],
                          onTap: () => _openDetail(_tickets[i]),
                        ),
                      ),
                      childCount: _tickets.length,
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  String _pluralTickets(int n) {
    final m = n % 10, m100 = n % 100;
    if (m100 >= 11 && m100 <= 19) return 'обращений';
    if (m == 1) return 'обращение';
    if (m >= 2 && m <= 4) return 'обращения';
    return 'обращений';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Ticket card
// ─────────────────────────────────────────────────────────────────────────────

class _TicketCard extends StatelessWidget {
  final SupportTicket ticket;
  final VoidCallback onTap;
  const _TicketCard({required this.ticket, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(ticket.status);
    final label = _statusLabel(ticket.status);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: DS.surface1,
          borderRadius: BorderRadius.circular(DS.radiusSm),
          border: Border.all(color: DS.border),
        ),
        child: Row(children: [
          // Status indicator bar
          Container(
            width: 3, height: 44,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 14),
          // Content
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(ticket.title,
                  style: const TextStyle(
                      color: DS.textPrimary, fontWeight: FontWeight.w600, fontSize: 14),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Text('#${ticket.id} · ${_fmtTs(ticket.updatedAt)}',
                  style: const TextStyle(color: DS.textMuted, fontSize: 11)),
            ]),
          ),
          const SizedBox(width: 10),
          // Status pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withValues(alpha: 0.3)),
            ),
            child: Text(label, style: TextStyle(
                color: color, fontSize: 11, fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Empty / Error views
// ─────────────────────────────────────────────────────────────────────────────

class _EmptyView extends StatelessWidget {
  final VoidCallback onNew;
  const _EmptyView({required this.onNew});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72, height: 72,
            decoration: BoxDecoration(
              color: DS.violet.withValues(alpha: 0.1),
              shape: BoxShape.circle,
              border: Border.all(color: DS.violet.withValues(alpha: 0.2)),
            ),
            child: const Icon(Icons.support_agent_rounded,
                color: DS.violet, size: 34),
          ),
          const SizedBox(height: 20),
          const Text('Обращений пока нет',
              style: TextStyle(
                  color: DS.textPrimary, fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const Text('Создайте обращение и мы поможем вам\nв течение нескольких часов.',
              textAlign: TextAlign.center,
              style: TextStyle(color: DS.textSecondary, fontSize: 14, height: 1.5)),
          const SizedBox(height: 28),
          GestureDetector(
            onTap: onNew,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [DS.violet, DS.violetDim],
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(DS.radiusSm),
                boxShadow: [
                  BoxShadow(color: DS.violet.withValues(alpha: 0.35),
                      blurRadius: 16, offset: const Offset(0, 5)),
                ],
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.add_rounded, color: Colors.white, size: 18),
                SizedBox(width: 8),
                Text('Создать обращение',
                    style: TextStyle(color: Colors.white,
                        fontSize: 14, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 60, height: 60,
              decoration: BoxDecoration(
                  color: DS.rose.withValues(alpha: 0.1), shape: BoxShape.circle),
              child: const Icon(Icons.wifi_off_rounded, color: DS.rose, size: 28)),
          const SizedBox(height: 16),
          const Text('Не удалось загрузить',
              style: TextStyle(color: DS.textPrimary, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(message, textAlign: TextAlign.center,
              style: const TextStyle(color: DS.textSecondary, fontSize: 13)),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: onRetry,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                  color: DS.surface2, borderRadius: BorderRadius.circular(DS.radiusXs),
                  border: Border.all(color: DS.border)),
              child: const Text('Повторить',
                  style: TextStyle(color: DS.violet, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Create ticket page
// ─────────────────────────────────────────────────────────────────────────────

class _CreateTicketPage extends StatefulWidget {
  const _CreateTicketPage();

  @override
  State<_CreateTicketPage> createState() => _CreateTicketPageState();
}

class _CreateTicketPageState extends State<_CreateTicketPage> {
  final _titleCtrl = TextEditingController();
  final _msgCtrl   = TextEditingController();
  bool _sending    = false;
  bool _attachDiag = false;

  // Preview of what will be attached
  String _diagPreview = '';

  @override
  void initState() {
    super.initState();
    _buildDiagPreview();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _msgCtrl.dispose();
    super.dispose();
  }

  // ── Diagnostics — same source as "Журнал логов" in settings ───────────────

  Future<void> _buildDiagPreview() async {
    final preview = await _collectDiagnostics(previewOnly: true);
    if (mounted) setState(() => _diagPreview = preview);
  }

  /// Collects diagnostics identical to settings → "Отправить диагностику":
  ///   1. Device info header
  ///   2. Full appLogger.exportText() — same as LogsPage
  Future<String> _collectDiagnostics({bool previewOnly = false}) async {
    final buf = StringBuffer();

    // Device info (same as before, but now prepended to real logs)
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final d = await plugin.androidInfo;
        buf.writeln('=== Device ===');
        buf.writeln('Android ${d.version.release} (SDK ${d.version.sdkInt})');
        buf.writeln('${d.manufacturer} ${d.model}');
      } else if (Platform.isIOS) {
        final d = await plugin.iosInfo;
        buf.writeln('=== Device ===');
        buf.writeln('iOS ${d.systemVersion}');
        buf.writeln(d.utsname.machine);
      } else {
        buf.writeln('=== Device ===');
        buf.writeln(Platform.operatingSystem);
      }
    } catch (_) {
      buf.writeln('=== Device ===');
      buf.writeln('unavailable');
    }

    if (previewOnly) return buf.toString().trim();

    // App logs — identical to appLogger.exportText() used in settings
    final logs = appLogger.exportText();
    if (logs.isNotEmpty) {
      buf.writeln('\n=== App Logs ===');
      buf.write(logs);
    }

    return buf.toString().trim();
  }

  Future<void> _send() async {
    final title   = _titleCtrl.text.trim();
    final message = _msgCtrl.text.trim();

    if (title.isEmpty)   { _snack('Укажите тему обращения'); return; }
    if (message.isEmpty) { _snack('Опишите проблему'); return; }

    setState(() => _sending = true);

    String? logs;
    if (_attachDiag) {
      logs = await _collectDiagnostics();
    }

    final ticket = await SupportApiService.createTicket(
        title: title, message: message, logs: logs);

    if (!mounted) return;
    setState(() => _sending = false);

    if (ticket != null) {
      Navigator.pop(context, true);
    } else {
      _snack('Не удалось отправить обращение. Попробуйте позже.');
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16)));
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: DS.surface0,
      body: Column(children: [
        // ── Header ────────────────────────────────────────────────────
        Container(
          padding: EdgeInsets.fromLTRB(16, top + 12, 16, 12),
          decoration: const BoxDecoration(
            color: DS.surface1,
            border: Border(bottom: BorderSide(color: DS.border)),
          ),
          child: Row(children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: DS.surface2,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: DS.border),
                ),
                child: const Icon(Icons.arrow_back_ios_new_rounded,
                    color: DS.textSecondary, size: 16),
              ),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Text('Новое обращение', style: TextStyle(
                  color: DS.textPrimary, fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            // Send button in header
            GestureDetector(
              onTap: _sending ? null : _send,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  gradient: _sending ? null : const LinearGradient(
                    colors: [DS.violet, DS.violetDim],
                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                  ),
                  color: _sending ? DS.surface2 : null,
                  borderRadius: BorderRadius.circular(DS.radiusXs),
                ),
                child: _sending
                    ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(color: DS.violet, strokeWidth: 2))
                    : const Text('Отправить', style: TextStyle(
                    color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),

        // ── Form ──────────────────────────────────────────────────────
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Subject
              _FieldLabel(text: 'ТЕМА', icon: Icons.title_rounded),
              const SizedBox(height: 8),
              _TextField(ctrl: _titleCtrl, hint: 'Кратко опишите проблему', maxLines: 1),
              const SizedBox(height: 16),

              // Message
              _FieldLabel(text: 'ОПИСАНИЕ', icon: Icons.notes_rounded),
              const SizedBox(height: 8),
              _TextField(ctrl: _msgCtrl, hint: 'Подробно опишите ситуацию…', maxLines: 7),
              const SizedBox(height: 20),

              // Diagnostics toggle
              _DiagnosticsToggle(
                value: _attachDiag,
                preview: _diagPreview,
                onChanged: (v) => setState(() => _attachDiag = v),
              ),
              const SizedBox(height: 24),

              // Submit button
              GestureDetector(
                onTap: _sending ? null : _send,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: 54,
                  decoration: BoxDecoration(
                    gradient: _sending ? null : const LinearGradient(
                      colors: [DS.violet, DS.violetDim],
                      begin: Alignment.topLeft, end: Alignment.bottomRight,
                    ),
                    color: _sending ? DS.surface2 : null,
                    borderRadius: BorderRadius.circular(DS.radiusSm),
                    boxShadow: _sending ? null : [
                      BoxShadow(color: DS.violet.withValues(alpha: 0.35),
                          blurRadius: 16, offset: const Offset(0, 5)),
                    ],
                  ),
                  child: Center(
                    child: _sending
                        ? const SizedBox(width: 22, height: 22,
                        child: CircularProgressIndicator(
                            color: DS.violet, strokeWidth: 2.5))
                        : const Text('Отправить обращение', style: TextStyle(
                        color: Colors.white, fontSize: 15,
                        fontWeight: FontWeight.w700, letterSpacing: 0.2)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Form sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

class _FieldLabel extends StatelessWidget {
  final String text;
  final IconData icon;
  const _FieldLabel({required this.text, required this.icon});

  @override
  Widget build(BuildContext context) => Row(children: [
    Icon(icon, size: 13, color: DS.textMuted),
    const SizedBox(width: 5),
    Text(text, style: const TextStyle(
        color: DS.textMuted, fontSize: 10,
        fontWeight: FontWeight.w700, letterSpacing: 1.0)),
  ]);
}

class _TextField extends StatelessWidget {
  final TextEditingController ctrl;
  final String hint;
  final int maxLines;
  const _TextField({required this.ctrl, required this.hint, required this.maxLines});

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: DS.surface1,
      borderRadius: BorderRadius.circular(DS.radiusSm),
      border: Border.all(color: DS.border),
    ),
    child: TextField(
      controller: ctrl,
      maxLines: maxLines,
      style: const TextStyle(color: DS.textPrimary, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: DS.textMuted),
        contentPadding: const EdgeInsets.all(14),
        border: InputBorder.none,
      ),
    ),
  );
}

class _DiagnosticsToggle extends StatelessWidget {
  final bool value;
  final String preview;
  final ValueChanged<bool> onChanged;
  const _DiagnosticsToggle({
    required this.value, required this.preview, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radiusSm),
        border: Border.all(
          color: value ? DS.violet.withValues(alpha: 0.35) : DS.border,
        ),
      ),
      child: Column(children: [
        // Toggle row
        GestureDetector(
          onTap: () => onChanged(!value),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 38, height: 38,
                decoration: BoxDecoration(
                  color: (value ? DS.violet : DS.textMuted).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.bug_report_rounded,
                    color: value ? DS.violet : DS.textMuted, size: 19),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Прикрепить диагностику', style: TextStyle(
                    color: DS.textPrimary, fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                    'Логи приложения и информация об устройстве',
                    style: const TextStyle(color: DS.textSecondary, fontSize: 11)),
              ])),
              const SizedBox(width: 8),
              Switch(value: value, onChanged: onChanged),
            ]),
          ),
        ),

        // Preview when enabled
        if (value && preview.isNotEmpty) ...[
          const Divider(height: 1, color: DS.border),
          Container(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.preview_rounded, size: 12, color: DS.textMuted),
                const SizedBox(width: 5),
                const Text('ПРЕДПРОСМОТР', style: TextStyle(
                    color: DS.textMuted, fontSize: 9,
                    fontWeight: FontWeight.w700, letterSpacing: 1)),
                const Spacer(),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: preview));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Скопировано'),
                        duration: Duration(seconds: 1)));
                  },
                  child: const Icon(Icons.copy_rounded, size: 13, color: DS.textMuted),
                ),
              ]),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: DS.surface0,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  preview,
                  style: const TextStyle(
                      color: DS.textSecondary, fontSize: 11,
                      fontFamily: 'monospace', height: 1.5),
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
          ),
        ],
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Ticket detail page (chat view)
// ─────────────────────────────────────────────────────────────────────────────

class _TicketDetailPage extends StatefulWidget {
  final SupportTicket ticket;
  const _TicketDetailPage({required this.ticket});

  @override
  State<_TicketDetailPage> createState() => _TicketDetailPageState();
}

class _TicketDetailPageState extends State<_TicketDetailPage> {
  SupportTicketDetail? _detail;
  bool _loading = true;
  final _replyCtrl  = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _replyCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final detail = await SupportApiService.getTicket(widget.ticket.id);
    if (mounted) setState(() { _detail = detail; _loading = false; });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _reply() async {
    final text = _replyCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    final msg = await SupportApiService.replyToTicket(
        ticketId: widget.ticket.id, message: text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (msg != null) {
      _replyCtrl.clear();
      await _load();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось отправить сообщение')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final top      = MediaQuery.of(context).padding.top;
    final isClosed = widget.ticket.status == 'closed';
    final color    = _statusColor(widget.ticket.status);
    final label    = _statusLabel(widget.ticket.status);

    return Scaffold(
      backgroundColor: DS.surface0,
      body: Column(children: [
        // ── Header ────────────────────────────────────────────────────
        Container(
          padding: EdgeInsets.fromLTRB(16, top + 12, 16, 12),
          decoration: const BoxDecoration(
            color: DS.surface1,
            border: Border(bottom: BorderSide(color: DS.border)),
          ),
          child: Row(children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: DS.surface2,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: DS.border),
                ),
                child: const Icon(Icons.arrow_back_ios_new_rounded,
                    color: DS.textSecondary, size: 16),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.ticket.title,
                  style: const TextStyle(
                      color: DS.textPrimary, fontSize: 15, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis, maxLines: 1),
              const SizedBox(height: 2),
              Text('#${widget.ticket.id}',
                  style: const TextStyle(color: DS.textMuted, fontSize: 11)),
            ])),
            const SizedBox(width: 10),
            // Status pill
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: color.withValues(alpha: 0.3)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 6, height: 6,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                const SizedBox(width: 5),
                Text(label, style: TextStyle(
                    color: color, fontSize: 11, fontWeight: FontWeight.w600)),
              ]),
            ),
          ]),
        ),

        // ── Messages ──────────────────────────────────────────────────
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(
              color: DS.violet, strokeWidth: 2.5))
              : (_detail == null || _detail!.messages.isEmpty)
              ? const Center(child: Text('Нет сообщений',
              style: TextStyle(color: DS.textMuted, fontSize: 14)))
              : ListView.builder(
            controller: _scrollCtrl,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            itemCount: _detail!.messages.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _MessageBubble(
                msg: _detail!.messages[i],
              ),
            ),
          ),
        ),

        // ── Reply bar / Closed notice ──────────────────────────────────
        if (isClosed)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: const BoxDecoration(
              color: DS.surface1,
              border: Border(top: BorderSide(color: DS.border)),
            ),
            child: const Center(
                child: Text('Тикет закрыт',
                    style: TextStyle(color: DS.textMuted, fontSize: 13))),
          )
        else
          _ReplyBar(ctrl: _replyCtrl, sending: _sending, onSend: _reply),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Message bubble
// ─────────────────────────────────────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final SupportTicketMessage msg;
  const _MessageBubble({required this.msg});

  @override
  Widget build(BuildContext context) {
    final isAdmin = msg.isFromAdmin;
    return Align(
      alignment: isAdmin ? Alignment.centerLeft : Alignment.centerRight,
      child: GestureDetector(
        onLongPress: () {
          Clipboard.setData(ClipboardData(text: msg.messageText));
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Скопировано'),
              duration: Duration(seconds: 1)));
        },
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.76),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isAdmin ? DS.surface2 : DS.violet.withValues(alpha: 0.85),
              border: isAdmin ? Border.all(color: DS.border) : null,
              borderRadius: BorderRadius.only(
                topLeft:     const Radius.circular(16),
                topRight:    const Radius.circular(16),
                bottomLeft:  Radius.circular(isAdmin ? 4 : 16),
                bottomRight: Radius.circular(isAdmin ? 16 : 4),
              ),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (isAdmin) ...[
                Row(children: [
                  Container(
                    width: 6, height: 6,
                    decoration: const BoxDecoration(
                        color: DS.emerald, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 5),
                  const Text('Поддержка', style: TextStyle(
                      color: DS.emerald, fontSize: 11, fontWeight: FontWeight.w700)),
                ]),
                const SizedBox(height: 5),
              ],
              Text(msg.messageText,
                  style: TextStyle(
                      color: isAdmin ? DS.textPrimary : Colors.white,
                      fontSize: 14, height: 1.4)),
              const SizedBox(height: 5),
              Text(_fmtTsShort(msg.createdAt),
                  style: TextStyle(
                      color: isAdmin ? DS.textMuted : Colors.white54,
                      fontSize: 10)),
            ]),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reply bar
// ─────────────────────────────────────────────────────────────────────────────

class _ReplyBar extends StatelessWidget {
  final TextEditingController ctrl;
  final bool sending;
  final VoidCallback onSend;
  const _ReplyBar({required this.ctrl, required this.sending, required this.onSend});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: DS.surface1,
        border: Border(top: BorderSide(color: DS.border)),
      ),
      padding: EdgeInsets.only(
        left: 12, right: 8, top: 8,
        bottom: 8 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          // Input
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 42),
              decoration: BoxDecoration(
                color: DS.surface2,
                borderRadius: BorderRadius.circular(DS.radiusSm),
                border: Border.all(color: DS.border),
              ),
              child: TextField(
                controller: ctrl,
                maxLines: 4, minLines: 1,
                style: const TextStyle(color: DS.textPrimary, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: 'Ваш ответ…',
                  hintStyle: TextStyle(color: DS.textMuted),
                  contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  border: InputBorder.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Send button
          GestureDetector(
            onTap: sending ? null : onSend,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 42, height: 42,
              decoration: BoxDecoration(
                gradient: sending ? null : const LinearGradient(
                  colors: [DS.violet, DS.violetDim],
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                ),
                color: sending ? DS.surface2 : null,
                borderRadius: BorderRadius.circular(DS.radiusSm),
              ),
              child: Center(
                child: sending
                    ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(color: DS.violet, strokeWidth: 2))
                    : const Icon(Icons.send_rounded, color: Colors.white, size: 18),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
