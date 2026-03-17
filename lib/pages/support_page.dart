import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart' show DS;
import '../services/app_logger.dart';
import '../services/support_api_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

String _p(int n) => n.toString().padLeft(2, '0');

String _fmtTs(int ts) {
  if (ts == 0) return '—';
  final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000).toLocal();
  return '${_p(dt.day)}.${_p(dt.month)}.${dt.year.toString().substring(2)} ${_p(dt.hour)}:${_p(dt.minute)}';
}

String _fmtTsShort(int ts) {
  if (ts == 0) return '—';
  final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000).toLocal();
  final now = DateTime.now();
  if (dt.day == now.day && dt.month == now.month && dt.year == now.year) {
    return '${_p(dt.hour)}:${_p(dt.minute)}';
  }
  return '${_p(dt.day)}.${_p(dt.month)} ${_p(dt.hour)}:${_p(dt.minute)}';
}

Color _statusColor(String s) {
  switch (s) {
    case 'open':     return DS.emerald;
    case 'answered': return DS.violet;
    case 'pending':  return DS.amber;
    case 'closed':   return DS.textMuted;
    default:         return DS.textSecondary;
  }
}

String _statusLabel(String s) {
  switch (s) {
    case 'open':     return 'Открыт';
    case 'answered': return 'Ответили';
    case 'pending':  return 'Ожидает';
    case 'closed':   return 'Закрыт';
    default:         return s;
  }
}

IconData _statusIcon(String s) {
  switch (s) {
    case 'open':     return Icons.radio_button_on_rounded;
    case 'answered': return Icons.mark_chat_read_rounded;
    case 'pending':  return Icons.hourglass_empty_rounded;
    case 'closed':   return Icons.check_circle_rounded;
    default:         return Icons.help_outline_rounded;
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

class _SupportPageState extends State<SupportPage> with WidgetsBindingObserver {
  List<SupportTicket> _tickets = [];
  bool _loading = true;
  String? _error;

  // Периодическое обновление списка тикетов (пока страница активна)
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _startTimer();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load();
      _startTimer();
    } else if (state == AppLifecycleState.paused) {
      _refreshTimer?.cancel();
    }
  }

  void _startTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) => _load(silent: true));
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() { _loading = true; _error = null; });
    try {
      final tickets = await SupportApiService.getTickets();
      if (mounted) setState(() { _tickets = tickets; _loading = false; });
    } catch (e) {
      if (mounted && !silent) setState(() { _error = e.toString(); _loading = false; });
      if (mounted && silent) setState(() => _loading = false);
    }
  }

  void _openCreate() async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const _CreateTicketPage()),
    );
    if (created == true && mounted) _load();
  }

  void _openDetail(SupportTicket ticket) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _TicketDetailPage(ticket: ticket)),
    );
    if (mounted) _load(silent: true);
  }

  // Количество тикетов, ожидающих ответа
  int get _pendingCount => _tickets.where((t) => t.status == 'answered').length;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: DS.surface0,
      body: RefreshIndicator(
        color: DS.violet,
        backgroundColor: DS.surface2,
        onRefresh: () => _load(),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // ── Header ───────────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, top + 20, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Back button
                        GestureDetector(
                          onTap: () => Navigator.maybePop(context),
                          child: Container(
                            width: 36, height: 36,
                            margin: const EdgeInsets.only(right: 12),
                            decoration: BoxDecoration(
                              color: DS.surface2,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: DS.border),
                            ),
                            child: const Icon(Icons.arrow_back_ios_new_rounded,
                                color: DS.textSecondary, size: 16),
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Поддержка', style: TextStyle(
                                color: DS.textPrimary, fontSize: 28,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5, height: 1,
                              )),
                              const SizedBox(height: 4),
                              Text(
                                _loading
                                    ? 'Загрузка…'
                                    : _tickets.isEmpty
                                    ? 'Обращений пока нет'
                                    : '${_tickets.length} ${_plural(_tickets.length)}',
                                style: const TextStyle(
                                    color: DS.textSecondary, fontSize: 14),
                              ),
                            ],
                          ),
                        ),
                        // Telegram button
                        _IconChip(
                          icon: Icons.telegram,
                          color: DS.telegramBlue,
                          onTap: () async {
                            final uri = Uri.parse('https://t.me/ulya_tech');
                            if (await canLaunchUrl(uri)) {
                              await launchUrl(uri,
                                  mode: LaunchMode.externalApplication);
                            }
                          },
                        ),
                        const SizedBox(width: 8),
                        // New ticket button
                        _GradientBtn(
                          label: 'Новое',
                          icon: Icons.add_rounded,
                          onTap: _openCreate,
                          fullWidth: false,
                        ),
                      ],
                    ),

                    // ── Ответы ожидают баннер ──────────────────────────
                    if (_pendingCount > 0) ...[
                      const SizedBox(height: 16),
                      _AnsweredBanner(
                        count: _pendingCount,
                        onTap: () {
                          final t = _tickets.firstWhere(
                                  (t) => t.status == 'answered',
                              orElse: () => _tickets.first);
                          _openDetail(t);
                        },
                      ),
                    ],

                    // ── Инфо-плашка (только когда список пустой и не загружается) ──
                    if (_tickets.isEmpty && !_loading && _error == null) ...[
                      const SizedBox(height: 16),
                      _InfoBanner(),
                    ],
                  ],
                ),
              ),
            ),

            const SliverPadding(padding: EdgeInsets.only(top: 20)),

            // ── Content ──────────────────────────────────────────────────
            if (_loading && _tickets.isEmpty)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator(
                    color: DS.violet, strokeWidth: 2.5)),
              )
            else if (_error != null && _tickets.isEmpty)
              SliverFillRemaining(
                  child: _ErrorView(message: _error!, onRetry: _load))
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

  String _plural(int n) {
    final m = n % 10, m100 = n % 100;
    if (m100 >= 11 && m100 <= 19) return 'обращений';
    if (m == 1) return 'обращение';
    if (m >= 2 && m <= 4) return 'обращения';
    return 'обращений';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Answered banner — «Новый ответ от поддержки»
// ─────────────────────────────────────────────────────────────────────────────

class _AnsweredBanner extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _AnsweredBanner({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: DS.violet.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(DS.radiusSm),
          border: Border.all(color: DS.violet.withValues(alpha: 0.30)),
        ),
        child: Row(children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [DS.violet, DS.violetDim],
                begin: Alignment.topLeft, end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.mark_chat_read_rounded,
                color: Colors.white, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  count == 1
                      ? 'Получен ответ от поддержки'
                      : 'Получено $count ответа от поддержки',
                  style: const TextStyle(
                    color: DS.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                const Text('Нажмите, чтобы прочитать',
                    style: TextStyle(color: DS.textSecondary, fontSize: 11)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded,
              color: DS.violet, size: 18),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Info banner — среднее время ответа
// ─────────────────────────────────────────────────────────────────────────────

class _InfoBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radiusSm),
        border: Border.all(color: DS.border),
      ),
      child: Row(children: [
        const Icon(Icons.schedule_rounded, color: DS.textMuted, size: 16),
        const SizedBox(width: 10),
        const Expanded(
          child: Text(
            'Обычно отвечаем в течение нескольких часов. '
                'Для срочных вопросов напишите в Telegram.',
            style: TextStyle(
                color: DS.textSecondary, fontSize: 12, height: 1.45),
          ),
        ),
      ]),
    );
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
    final icon  = _statusIcon(ticket.status);
    final hasNewAnswer = ticket.status == 'answered';

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: hasNewAnswer
              ? DS.violet.withValues(alpha: 0.06)
              : DS.surface1,
          borderRadius: BorderRadius.circular(DS.radiusSm),
          border: Border.all(
            color: hasNewAnswer
                ? DS.violet.withValues(alpha: 0.30)
                : DS.border,
          ),
        ),
        child: Row(children: [
          // Status icon circle
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 12),

          // Content
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(ticket.title,
                    style: const TextStyle(
                      color: DS.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (hasNewAnswer) ...[
                  const SizedBox(width: 6),
                  Container(
                    width: 8, height: 8,
                    decoration: const BoxDecoration(
                        color: DS.violet, shape: BoxShape.circle),
                  ),
                ],
              ]),
              const SizedBox(height: 4),
              Text(
                '#${ticket.id} · ${_fmtTs(ticket.updatedAt)}',
                style: const TextStyle(color: DS.textMuted, fontSize: 11),
              ),
            ]),
          ),
          const SizedBox(width: 10),

          // Status pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withValues(alpha: 0.28)),
            ),
            child: Text(label,
                style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
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
            width: 76, height: 76,
            decoration: BoxDecoration(
              color: DS.violet.withValues(alpha: 0.09),
              shape: BoxShape.circle,
              border: Border.all(color: DS.violet.withValues(alpha: 0.20)),
            ),
            child: const Icon(Icons.support_agent_rounded,
                color: DS.violet, size: 36),
          ),
          const SizedBox(height: 20),
          const Text('Обращений пока нет',
              style: TextStyle(
                  color: DS.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const Text(
              'Создайте обращение — мы поможем\nв течение нескольких часов.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: DS.textSecondary, fontSize: 14, height: 1.5)),
          const SizedBox(height: 28),
          _GradientBtn(
            label: 'Создать обращение',
            icon: Icons.add_rounded,
            onTap: onNew,
            fullWidth: false,
          ),
          const SizedBox(height: 16),
          // Quick Telegram link
          GestureDetector(
            onTap: () async {
              final uri = Uri.parse('https://t.me/ulya_tech');
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.telegram, color: DS.telegramBlue, size: 16),
              const SizedBox(width: 6),
              const Text('Написать в Telegram',
                  style: TextStyle(
                    color: DS.telegramBlue,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  )),
            ]),
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
                  color: DS.rose.withValues(alpha: 0.1),
                  shape: BoxShape.circle),
              child: const Icon(Icons.wifi_off_rounded,
                  color: DS.rose, size: 28)),
          const SizedBox(height: 16),
          const Text('Не удалось загрузить',
              style: TextStyle(
                  color: DS.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: DS.textSecondary, fontSize: 13)),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: onRetry,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                  color: DS.surface2,
                  borderRadius: BorderRadius.circular(DS.radiusXs),
                  border: Border.all(color: DS.border)),
              child: const Text('Повторить',
                  style: TextStyle(
                      color: DS.violet, fontWeight: FontWeight.w600)),
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
  String _diagPreview = '';

  @override
  void initState() {
    super.initState();
    _buildPreview();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _msgCtrl.dispose();
    super.dispose();
  }

  Future<void> _buildPreview() async {
    final p = await _collectDiag(previewOnly: true);
    if (mounted) setState(() => _diagPreview = p);
  }

  Future<String> _collectDiag({bool previewOnly = false}) async {
    final buf = StringBuffer();
    try {
      final pi = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final d = await pi.androidInfo;
        buf.writeln('=== Device ===');
        buf.writeln('Android ${d.version.release} (SDK ${d.version.sdkInt})');
        buf.writeln('${d.manufacturer} ${d.model}');
      } else if (Platform.isIOS) {
        final d = await pi.iosInfo;
        buf.writeln('=== Device ===');
        buf.writeln('iOS ${d.systemVersion}');
        buf.writeln(d.utsname.machine);
      } else {
        buf.writeln('=== Device ===');
        buf.writeln(Platform.operatingSystem);
      }
    } catch (_) {
      buf.writeln('=== Device ===\nunavailable');
    }
    if (previewOnly) return buf.toString().trim();
    final logs = appLogger.exportText();
    if (logs.isNotEmpty) {
      buf.writeln('\n=== App Logs ===');
      buf.write(logs);
    }
    return buf.toString().trim();
  }

  Future<void> _send() async {
    final title = _titleCtrl.text.trim();
    final msg   = _msgCtrl.text.trim();
    if (title.isEmpty) { _snack('Укажите тему обращения'); return; }
    if (msg.isEmpty)   { _snack('Опишите проблему'); return; }
    setState(() => _sending = true);
    final logs = _attachDiag ? await _collectDiag() : null;
    final ticket = await SupportApiService.createTicket(
        title: title, message: msg, logs: logs);
    if (!mounted) return;
    setState(() => _sending = false);
    if (ticket != null) {
      Navigator.pop(context, true);
    } else {
      _snack('Не удалось отправить. Попробуйте позже.');
    }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16)));

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: DS.surface0,
      body: Column(children: [
        // Header
        _PageHeader(
          title: 'Новое обращение',
          onBack: () => Navigator.pop(context),
          trailing: _sending
              ? const SizedBox(width: 18, height: 18,
              child: CircularProgressIndicator(
                  color: DS.violet, strokeWidth: 2))
              : GestureDetector(
            onTap: _send,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [DS.violet, DS.violetDim],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(DS.radiusXs),
              ),
              child: const Text('Отправить',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ),
          ),
          topPad: top,
        ),

        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _FieldLabel(text: 'ТЕМА', icon: Icons.title_rounded),
              const SizedBox(height: 8),
              _FormField(ctrl: _titleCtrl,
                  hint: 'Кратко опишите проблему', maxLines: 1),
              const SizedBox(height: 16),
              _FieldLabel(text: 'ОПИСАНИЕ', icon: Icons.notes_rounded),
              const SizedBox(height: 8),
              _FormField(ctrl: _msgCtrl,
                  hint: 'Подробно опишите ситуацию…', maxLines: 7),
              const SizedBox(height: 20),
              _DiagToggle(
                value: _attachDiag,
                preview: _diagPreview,
                onChanged: (v) => setState(() => _attachDiag = v),
              ),
              const SizedBox(height: 24),
              // Submit
              GestureDetector(
                onTap: _sending ? null : _send,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: 54,
                  decoration: BoxDecoration(
                    gradient: _sending
                        ? null
                        : const LinearGradient(
                      colors: [DS.violet, DS.violetDim],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    color: _sending ? DS.surface2 : null,
                    borderRadius: BorderRadius.circular(DS.radiusSm),
                    boxShadow: _sending
                        ? null
                        : [BoxShadow(
                        color: DS.violet.withValues(alpha: 0.35),
                        blurRadius: 16,
                        offset: const Offset(0, 5))],
                  ),
                  child: Center(
                    child: _sending
                        ? const SizedBox(width: 22, height: 22,
                        child: CircularProgressIndicator(
                            color: DS.violet, strokeWidth: 2.5))
                        : const Text('Отправить обращение',
                        style: TextStyle(
                            color: Colors.white, fontSize: 15,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2)),
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
// Ticket detail page — chat with realtime polling
// ─────────────────────────────────────────────────────────────────────────────

class _TicketDetailPage extends StatefulWidget {
  final SupportTicket ticket;
  const _TicketDetailPage({required this.ticket});

  @override
  State<_TicketDetailPage> createState() => _TicketDetailPageState();
}

class _TicketDetailPageState extends State<_TicketDetailPage>
    with WidgetsBindingObserver {
  SupportTicketDetail? _detail;
  bool _loading  = true;
  bool _closing  = false;
  bool _sending  = false;
  String _ticketStatus = '';

  // Realtime
  Timer? _pollTimer;
  int _lastMsgCount = 0;
  bool _hasNewMessages = false; // показать баннер «новое сообщение»
  bool _userScrolledUp = false; // не скроллить вниз если пользователь листает

  final _replyCtrl  = TextEditingController();
  final _scrollCtrl = ScrollController();

  static const _pollInterval = Duration(seconds: 8);

  @override
  void initState() {
    super.initState();
    _ticketStatus = widget.ticket.status;
    WidgetsBinding.instance.addObserver(this);
    _scrollCtrl.addListener(_onScroll);
    _load(initial: true);
    _startPoll();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _replyCtrl.dispose();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load(silent: true);
      _startPoll();
    } else if (state == AppLifecycleState.paused) {
      _pollTimer?.cancel();
    }
  }

  void _startPoll() {
    _pollTimer?.cancel();
    if (_ticketStatus == 'closed') return; // не поллим закрытые
    _pollTimer = Timer.periodic(_pollInterval, (_) => _load(silent: true));
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final atBottom = _scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 60;
    if (atBottom && _hasNewMessages) {
      setState(() => _hasNewMessages = false);
    }
    _userScrolledUp = !atBottom;
  }

  Future<void> _load({bool initial = false, bool silent = false}) async {
    if (initial) setState(() => _loading = true);
    final detail = await SupportApiService.getTicket(widget.ticket.id);
    if (!mounted) return;

    final newCount = detail?.messages.length ?? 0;
    final hadNew   = newCount > _lastMsgCount && _lastMsgCount > 0;

    setState(() {
      _detail       = detail;
      _loading      = false;
      _lastMsgCount = newCount;
      if (detail != null) _ticketStatus = detail.status;
      // Показываем баннер только если пользователь листает вверх
      if (hadNew && _userScrolledUp) _hasNewMessages = true;
    });

    // Рестартуем поллинг если тикет закрыли
    if (_ticketStatus == 'closed') _pollTimer?.cancel();

    // Скроллим вниз если пользователь не листает вверх
    if (!_userScrolledUp || initial) {
      _scrollToBottom();
      if (_hasNewMessages) setState(() => _hasNewMessages = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
        );
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
      _userScrolledUp = false;
      await _load(silent: true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось отправить сообщение')));
    }
  }

  Future<void> _closeTicket() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DS.surface1,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: const Text('Закрыть тикет?',
            style: TextStyle(
                color: DS.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700)),
        content: const Text(
            'Переписка будет завершена.',
            style: TextStyle(color: DS.textSecondary, fontSize: 14)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена',
                  style: TextStyle(color: DS.textMuted))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Закрыть',
                  style: TextStyle(color: DS.rose))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _closing = true);
    final result = await SupportApiService.closeTicket(widget.ticket.id);
    if (!mounted) return;
    setState(() {
      _closing = false;
      if (result != null) _ticketStatus = result.status;
    });
    _pollTimer?.cancel();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result != null ? 'Тикет закрыт' : 'Не удалось закрыть'),
      backgroundColor: result != null ? DS.emerald : DS.rose,
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final top      = MediaQuery.of(context).padding.top;
    final isClosed = _ticketStatus == 'closed';
    final color    = _statusColor(_ticketStatus);
    final label    = _statusLabel(_ticketStatus);

    return Scaffold(
      backgroundColor: DS.surface0,
      body: Column(children: [
        // ── Header ──────────────────────────────────────────────────
        _PageHeader(
          topPad: top,
          title: widget.ticket.title,
          subtitle: '#${widget.ticket.id}',
          onBack: () => Navigator.pop(context),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            // Close button
            if (!isClosed)
              GestureDetector(
                onTap: _closing ? null : _closeTicket,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: DS.rose.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: DS.rose.withValues(alpha: 0.28)),
                  ),
                  child: _closing
                      ? const SizedBox(width: 14, height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: DS.rose))
                      : const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.close_rounded,
                        color: DS.rose, size: 14),
                    SizedBox(width: 4),
                    Text('Закрыть',
                        style: TextStyle(
                            color: DS.rose,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            if (!isClosed) const SizedBox(width: 8),
            // Status pill
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: color.withValues(alpha: 0.28)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                    width: 6, height: 6,
                    decoration: BoxDecoration(
                        color: color, shape: BoxShape.circle)),
                const SizedBox(width: 5),
                Text(label,
                    style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ]),
            ),
          ]),
        ),

        // ── Messages ────────────────────────────────────────────────
        Expanded(
          child: Stack(
            children: [
              _loading
                  ? const Center(child: CircularProgressIndicator(
                  color: DS.violet, strokeWidth: 2.5))
                  : (_detail == null || _detail!.messages.isEmpty)
                  ? const Center(child: Text('Нет сообщений',
                  style: TextStyle(
                      color: DS.textMuted, fontSize: 14)))
                  : ListView.builder(
                controller: _scrollCtrl,
                padding: const EdgeInsets.fromLTRB(
                    16, 12, 16, 12),
                itemCount: _detail!.messages.length,
                itemBuilder: (_, i) {
                  final msg = _detail!.messages[i];
                  final prev = i > 0
                      ? _detail!.messages[i - 1]
                      : null;
                  final showDate = prev == null ||
                      !_sameDay(
                          prev.createdAt, msg.createdAt);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showDate)
                        _DateDivider(ts: msg.createdAt),
                      Padding(
                        padding: const EdgeInsets.only(
                            bottom: 6),
                        child: _Bubble(msg: msg),
                      ),
                    ],
                  );
                },
              ),

              // «Новое сообщение» баннер
              if (_hasNewMessages)
                Positioned(
                  bottom: 12,
                  left: 0, right: 0,
                  child: Center(
                    child: GestureDetector(
                      onTap: () {
                        _userScrolledUp = false;
                        _scrollToBottom();
                        setState(() => _hasNewMessages = false);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [DS.violet, DS.violetDim],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [BoxShadow(
                            color: DS.violet.withValues(alpha: 0.4),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          )],
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.arrow_downward_rounded,
                                color: Colors.white, size: 14),
                            SizedBox(width: 6),
                            Text('Новое сообщение',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),

        // ── Reply / Closed ───────────────────────────────────────────
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
          _ReplyBar(
              ctrl: _replyCtrl,
              sending: _sending,
              onSend: _reply),
      ]),
    );
  }

  bool _sameDay(int ts1, int ts2) {
    final d1 = DateTime.fromMillisecondsSinceEpoch(ts1 * 1000).toLocal();
    final d2 = DateTime.fromMillisecondsSinceEpoch(ts2 * 1000).toLocal();
    return d1.day == d2.day &&
        d1.month == d2.month &&
        d1.year == d2.year;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Date divider
// ─────────────────────────────────────────────────────────────────────────────

class _DateDivider extends StatelessWidget {
  final int ts;
  const _DateDivider({required this.ts});

  @override
  Widget build(BuildContext context) {
    final dt  = DateTime.fromMillisecondsSinceEpoch(ts * 1000).toLocal();
    final now = DateTime.now();
    final isToday = dt.day == now.day &&
        dt.month == now.month &&
        dt.year == now.year;
    final label = isToday
        ? 'Сегодня'
        : '${_p(dt.day)}.${_p(dt.month)}.${dt.year}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(children: [
        const Expanded(child: Divider(color: DS.border, height: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(label,
              style: const TextStyle(
                  color: DS.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500)),
        ),
        const Expanded(child: Divider(color: DS.border, height: 1)),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Message bubble
// ─────────────────────────────────────────────────────────────────────────────

class _Bubble extends StatelessWidget {
  final SupportTicketMessage msg;
  const _Bubble({required this.msg});

  @override
  Widget build(BuildContext context) {
    final isAdmin = msg.isFromAdmin;
    return Align(
      alignment: isAdmin ? Alignment.centerLeft : Alignment.centerRight,
      child: GestureDetector(
        onLongPress: () {
          Clipboard.setData(ClipboardData(text: msg.messageText));
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('Скопировано'),
                  duration: Duration(seconds: 1)));
        },
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.75),
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isAdmin
                  ? DS.surface2
                  : DS.violet.withValues(alpha: 0.88),
              border: isAdmin
                  ? Border.all(color: DS.border)
                  : null,
              borderRadius: BorderRadius.only(
                topLeft:     const Radius.circular(16),
                topRight:    const Radius.circular(16),
                bottomLeft:  Radius.circular(isAdmin ? 4 : 16),
                bottomRight: Radius.circular(isAdmin ? 16 : 4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isAdmin) ...[
                  Row(children: [
                    Container(
                        width: 6, height: 6,
                        decoration: const BoxDecoration(
                            color: DS.emerald, shape: BoxShape.circle)),
                    const SizedBox(width: 5),
                    const Text('Поддержка',
                        style: TextStyle(
                            color: DS.emerald,
                            fontSize: 11,
                            fontWeight: FontWeight.w700)),
                  ]),
                  const SizedBox(height: 5),
                ],
                if (msg.hasMedia) ...[
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.attach_file_rounded,
                        size: 13,
                        color: isAdmin
                            ? DS.textMuted
                            : Colors.white70),
                    const SizedBox(width: 4),
                    Text('Логи прикреплены',
                        style: TextStyle(
                            color: isAdmin
                                ? DS.textMuted
                                : Colors.white70,
                            fontSize: 11,
                            fontStyle: FontStyle.italic)),
                  ]),
                  const SizedBox(height: 4),
                ],
                Text(msg.messageText,
                    style: TextStyle(
                        color: isAdmin ? DS.textPrimary : Colors.white,
                        fontSize: 14,
                        height: 1.4)),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.bottomRight,
                  child: Text(_fmtTsShort(msg.createdAt),
                      style: TextStyle(
                          color: isAdmin
                              ? DS.textMuted
                              : Colors.white54,
                          fontSize: 10)),
                ),
              ],
            ),
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
  const _ReplyBar(
      {required this.ctrl, required this.sending, required this.onSend});

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
                style: const TextStyle(
                    color: DS.textPrimary, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: 'Ваш ответ…',
                  hintStyle: TextStyle(color: DS.textMuted),
                  contentPadding: EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  border: InputBorder.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: sending ? null : onSend,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 42, height: 42,
              decoration: BoxDecoration(
                gradient: sending
                    ? null
                    : const LinearGradient(
                  colors: [DS.violet, DS.violetDim],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                color: sending ? DS.surface2 : null,
                borderRadius: BorderRadius.circular(DS.radiusSm),
              ),
              child: Center(
                child: sending
                    ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(
                        color: DS.violet, strokeWidth: 2))
                    : const Icon(Icons.send_rounded,
                    color: Colors.white, size: 18),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared form widgets
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

class _FormField extends StatelessWidget {
  final TextEditingController ctrl;
  final String hint;
  final int maxLines;
  const _FormField(
      {required this.ctrl, required this.hint, required this.maxLines});

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

class _DiagToggle extends StatelessWidget {
  final bool value;
  final String preview;
  final ValueChanged<bool> onChanged;
  const _DiagToggle(
      {required this.value, required this.preview, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radiusSm),
        border: Border.all(
          color: value
              ? DS.violet.withValues(alpha: 0.35)
              : DS.border,
        ),
      ),
      child: Column(children: [
        GestureDetector(
          onTap: () => onChanged(!value),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 38, height: 38,
                decoration: BoxDecoration(
                  color: (value ? DS.violet : DS.textMuted)
                      .withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.bug_report_rounded,
                    color: value ? DS.violet : DS.textMuted, size: 19),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Прикрепить диагностику',
                        style: TextStyle(
                            color: DS.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                    SizedBox(height: 2),
                    Text('Логи приложения и информация об устройстве',
                        style: TextStyle(
                            color: DS.textSecondary, fontSize: 11)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch(value: value, onChanged: onChanged),
            ]),
          ),
        ),
        if (value && preview.isNotEmpty) ...[
          const Divider(height: 1, color: DS.border),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.preview_rounded,
                      size: 12, color: DS.textMuted),
                  const SizedBox(width: 5),
                  const Text('ПРЕДПРОСМОТР',
                      style: TextStyle(
                          color: DS.textMuted, fontSize: 9,
                          fontWeight: FontWeight.w700, letterSpacing: 1)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: preview));
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Скопировано'),
                              duration: Duration(seconds: 1)));
                    },
                    child: const Icon(Icons.copy_rounded,
                        size: 13, color: DS.textMuted),
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
                  child: Text(preview,
                      style: const TextStyle(
                          color: DS.textSecondary, fontSize: 11,
                          fontFamily: 'monospace', height: 1.5),
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
        ],
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared UI primitives
// ─────────────────────────────────────────────────────────────────────────────

/// Стандартный header страницы с кнопкой назад
class _PageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback onBack;
  final Widget? trailing;
  final double topPad;

  const _PageHeader({
    required this.title,
    required this.onBack,
    required this.topPad,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(16, topPad + 12, 16, 12),
      decoration: const BoxDecoration(
        color: DS.surface1,
        border: Border(bottom: BorderSide(color: DS.border)),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: onBack,
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
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: DS.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1),
              if (subtitle != null)
                Text(subtitle!,
                    style: const TextStyle(
                        color: DS.textMuted, fontSize: 11)),
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          trailing!,
        ],
      ]),
    );
  }
}

/// Gradient кнопка с иконкой
class _GradientBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool fullWidth;

  const _GradientBtn({
    required this.label,
    required this.icon,
    required this.onTap,
    this.fullWidth = true,
  });

  @override
  Widget build(BuildContext context) {
    final inner = Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: Colors.white, size: 16),
      const SizedBox(width: 6),
      Text(label,
          style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700)),
    ]);

    Widget box = Container(
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
              color: DS.violet.withValues(alpha: 0.30),
              blurRadius: 12,
              offset: const Offset(0, 4)),
        ],
      ),
      child: inner,
    );

    if (fullWidth) box = SizedBox(width: double.infinity, child: box);
    return GestureDetector(onTap: onTap, child: box);
  }
}

/// Иконка-чип для header
class _IconChip extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _IconChip(
      {required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38, height: 38,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Icon(icon, color: color, size: 20),
      ),
    );
  }
}