import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/me_response.dart';
import '../models/subscription_info.dart';
import '../services/auth_service.dart';
import '../services/auth_state.dart';
import '../services/me_service.dart';
import '../services/remnawave_service.dart';
import '../services/subscription_api_service.dart';
import '../widgets/telegram_login_button.dart';
import 'auth_bottom_sheet.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Design tokens (shared with premium_page — extract to a common file if needed)
// ─────────────────────────────────────────────────────────────────────────────

class _DS {
  static const violet = Color(0xFF7C6FF7);
  // ignore: unused_field
  static const violetDim = Color(0xFF5A52C0);
  static const emerald = Color(0xFF34D399);
  static const amber = Color(0xFFFBBF24);
  static const rose = Color(0xFFF87171);
  static const telegramBlue = Color(0xFF229ED9);

  static const surface0 = Color(0xFF0F0F14);
  static const surface1 = Color(0xFF17171F);
  static const surface2 = Color(0xFF1E1E2A);
  static const surface3 = Color(0xFF26263A);

  static const textPrimary = Color(0xFFEEEEF8);
  static const textSecondary = Color(0xFF8888AA);
  static const textMuted = Color(0xFF55556A);

  static const border = Color(0xFF2A2A3D);

  static const radius = 20.0;
  // ignore: unused_field
  static const radiusSm = 12.0;
  static const radiusXs = 8.0;
}

// ─────────────────────────────────────────────────────────────────────────────
// SubscriptionPage
// ─────────────────────────────────────────────────────────────────────────────

class SubscriptionPage extends StatefulWidget {
  const SubscriptionPage({super.key, this.onGoToPremium});
  final VoidCallback? onGoToPremium;

  @override
  State<SubscriptionPage> createState() => _SubscriptionPageState();
}

class _SubscriptionPageState extends State<SubscriptionPage> with WidgetsBindingObserver {
  bool _loading = false;
  SubscriptionInfo? _trafficInfo;
  DateTime? _lastRefresh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    authStateNotifier.addListener(_onAuthChanged);
    meNotifier.addListener(_onMeChanged);
    _loadCachedMe();
    _refresh();
  }

  Future<void> _loadCachedMe() async => MeService.loadFromCache();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    authStateNotifier.removeListener(_onAuthChanged);
    meNotifier.removeListener(_onMeChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  void _onAuthChanged() {
    if (!authStateNotifier.value.isLoggedIn) MeService.clear();
    _refresh();
  }

  void _onMeChanged() { if (mounted) setState(() {}); }

  Future<void> _refresh({bool force = false}) async {
    if (!mounted) return;
    if (!force &&
        _lastRefresh != null &&
        DateTime.now().difference(_lastRefresh!) < const Duration(seconds: 8)) {
      return;
    }

    _lastRefresh = DateTime.now();
    setState(() => _loading = true);

    try {
      await MeService.refresh();
      final subUrl = await RemnawaveService.getSubscriptionUrl();
      if (subUrl.isNotEmpty) {
        await RemnawaveService.fetchNodes();
        if (mounted) setState(() => _trafficInfo = RemnawaveService.lastSubscriptionInfo);
      } else {
        if (mounted) setState(() => _trafficInfo = null);
      }
    } catch (e, st) {
      debugPrint('SubscriptionPage refresh error: $e\n$st');
    }

    if (mounted) setState(() => _loading = false);
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final auth = authStateNotifier.value;
    final me = meNotifier.value;

    return Scaffold(
      backgroundColor: _DS.surface0,
      body: RefreshIndicator(
        color: _DS.violet,
        backgroundColor: _DS.surface2,
        onRefresh: () => _refresh(force: true),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _SubHeader(onRefresh: () => _refresh(force: true))),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  if (!auth.isLoggedIn) ...[
                    _NotLoggedInCard(onLoginTap: () => showAuthBottomSheet(context)),
                    const SizedBox(height: 12),
                    _GoPremiumBanner(onTap: _onPremiumTap),
                  ] else if (_loading && me == null) ...[
                    const SizedBox(height: 120),
                    const Center(child: CircularProgressIndicator(color: _DS.violet, strokeWidth: 2.5)),
                  ] else ...[
                    _UserCard(me: me, auth: auth),
                    const SizedBox(height: 12),
                    if (me != null) ...[
                      _BalanceCard(me: me),
                      const SizedBox(height: 12),
                    ],
                    _SubscriptionStatusCard(me: me),
                    const SizedBox(height: 12),
                    if (me?.subscription != null) ...[
                      _TrafficCard(sub: me!.subscription!, trafficInfo: _trafficInfo),
                      const SizedBox(height: 12),
                      _AutopayCard(sub: me.subscription!, onToggle: _onAutopayToggle),
                      const SizedBox(height: 12),
                      _SubscriptionDetailsCard(sub: me.subscription!),
                      const SizedBox(height: 12),
                      if (me.subscription!.subscriptionUrl != null) ...[
                        _SubscriptionUrlCard(url: me.subscription!.subscriptionUrl!),
                        const SizedBox(height: 12),
                      ],
                    ],
                    _QuickActionsCard(onLogout: _onLogout, onPremiumTap: _onPremiumTap),
                  ],
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _DS.surface2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_DS.radius)),
        title: const Text('Выйти из аккаунта?', style: TextStyle(color: _DS.textPrimary, fontWeight: FontWeight.w700)),
        content: const Text('Данные подписки будут сброшены.', style: TextStyle(color: _DS.textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Выйти', style: TextStyle(color: _DS.rose)),
          ),
        ],
      ),
    );
    if (confirm == true) await AuthService.logout();
  }

  Future<void> _onAutopayToggle(bool enabled) async {
    final result = await SubscriptionApiService.setAutopay(enabled: enabled);
    if (result != null && mounted) await MeService.refresh();
  }

  void _onPremiumTap() {
    if (widget.onGoToPremium != null) {
      widget.onGoToPremium!();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Откройте вкладку «Премиум» для управления подпиской'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Header
// ─────────────────────────────────────────────────────────────────────────────

class _SubHeader extends StatelessWidget {
  final VoidCallback onRefresh;
  const _SubHeader({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Container(
      padding: EdgeInsets.fromLTRB(20, top + 20, 20, 28),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF151525), _DS.surface0],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Подписка',
                  style: TextStyle(
                    color: _DS.textPrimary, fontSize: 32,
                    fontWeight: FontWeight.w800, letterSpacing: -0.5, height: 1,
                  ),
                ),
                const SizedBox(height: 6),
                const Text('Управляйте аккаунтом', style: TextStyle(color: _DS.textSecondary, fontSize: 15)),
              ],
            ),
          ),
          GestureDetector(
            onTap: onRefresh,
            child: Container(
              width: 42, height: 42,
              decoration: BoxDecoration(
                color: _DS.surface2,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _DS.border),
              ),
              child: const Icon(Icons.refresh_rounded, color: _DS.textSecondary, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Not logged in
// ─────────────────────────────────────────────────────────────────────────────

class _NotLoggedInCard extends StatelessWidget {
  final VoidCallback onLoginTap;
  const _NotLoggedInCard({required this.onLoginTap});

  @override
  Widget build(BuildContext context) => _Card(
    child: Column(
      children: [
        Container(
          width: 72, height: 72,
          decoration: BoxDecoration(
            color: _DS.violet.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.lock_person_outlined, color: _DS.violet, size: 34),
        ),
        const SizedBox(height: 18),
        const Text(
          'Нужна авторизация',
          style: TextStyle(color: _DS.textPrimary, fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          'Войдите через Telegram, чтобы увидеть данные подписки.',
          style: TextStyle(color: _DS.textSecondary, fontSize: 14, height: 1.5),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 22),
        TelegramLoginButton(onTap: onLoginTap),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Go premium banner
// ─────────────────────────────────────────────────────────────────────────────

class _GoPremiumBanner extends StatelessWidget {
  final VoidCallback onTap;
  const _GoPremiumBanner({required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_DS.violet.withValues(alpha: 0.2), _DS.surface1],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(_DS.radius),
        border: Border.all(color: _DS.violet.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: _DS.amber.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.workspace_premium_rounded, color: _DS.amber, size: 22),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Купить подписку', style: TextStyle(
                  color: _DS.textPrimary, fontSize: 15, fontWeight: FontWeight.w600,
                )),
                SizedBox(height: 3),
                Text('Выберите тариф и оплатите', style: TextStyle(
                  color: _DS.textSecondary, fontSize: 12,
                )),
              ],
            ),
          ),
          const Icon(Icons.arrow_forward_ios_rounded, color: _DS.textMuted, size: 15),
        ],
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// User card
// ─────────────────────────────────────────────────────────────────────────────

class _UserCard extends StatelessWidget {
  final MeResponse? me;
  final AuthState auth;
  const _UserCard({required this.me, required this.auth});

  @override
  Widget build(BuildContext context) {
    final name = me?.displayName ?? auth.displayName;
    final username = me?.username ?? auth.username;
    final initials = name.isNotEmpty ? name[0].toUpperCase() : '?';

    return _Card(
      child: Row(
        children: [
          // Avatar
          Container(
            width: 54, height: 54,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF7C6FF7), Color(0xFF4A44AA)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [BoxShadow(
                color: _DS.violet.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 3),
              )],
            ),
            child: Center(
              child: Text(initials, style: const TextStyle(
                color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700,
              )),
            ),
          ),
          const SizedBox(width: 14),
          // Name
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(
                  color: _DS.textPrimary, fontSize: 16, fontWeight: FontWeight.w700,
                )),
                if (username != null && username.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text('@$username', style: const TextStyle(color: _DS.textSecondary, fontSize: 13)),
                ],
              ],
            ),
          ),
          // Telegram badge
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: _DS.telegramBlue.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.telegram, color: _DS.telegramBlue, size: 20),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Subscription status
// ─────────────────────────────────────────────────────────────────────────────

class _SubscriptionStatusCard extends StatelessWidget {
  final MeResponse? me;
  const _SubscriptionStatusCard({required this.me});

  @override
  Widget build(BuildContext context) {
    final sub = me?.subscription;

    late final Color color;
    late final IconData icon;
    late final String label;
    late final String detail;

    if (sub == null) {
      color = _DS.textMuted; icon = Icons.remove_circle_outline_rounded;
      label = 'Нет подписки'; detail = 'Подписка не найдена';
    } else if (sub.isActive) {
      color = _DS.emerald; icon = Icons.verified_rounded;
      label = sub.isTrial ? 'Пробный период' : 'Активна';
      detail = 'Действует до ${sub.formattedExpiry}';
    } else if (sub.isExpired) {
      color = _DS.rose; icon = Icons.cancel_outlined;
      label = 'Истекла'; detail = 'Истекла ${sub.formattedExpiry}';
    } else {
      color = _DS.amber; icon = Icons.warning_amber_rounded;
      label = sub.status; detail = 'До ${sub.formattedExpiry}';
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _DS.surface1,
        borderRadius: BorderRadius.circular(_DS.radius),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(
                  color: color, fontSize: 16, fontWeight: FontWeight.w700,
                )),
                const SizedBox(height: 2),
                Text(detail, style: const TextStyle(color: _DS.textSecondary, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Balance card
// ─────────────────────────────────────────────────────────────────────────────

class _BalanceCard extends StatelessWidget {
  final MeResponse me;
  const _BalanceCard({required this.me});

  @override
  Widget build(BuildContext context) => _Card(
    child: Row(
      children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: _DS.emerald.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.account_balance_wallet_rounded, color: _DS.emerald, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Баланс', style: TextStyle(color: _DS.textSecondary, fontSize: 12)),
              const SizedBox(height: 2),
              Text(
                '${me.balanceRub.toStringAsFixed(2)} ${me.balanceCurrency}',
                style: const TextStyle(
                  color: _DS.textPrimary, fontSize: 20, fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        TextButton.icon(
          onPressed: () => _showTopupSheet(context),
          icon: const Icon(Icons.add_rounded, size: 16),
          label: const Text('Пополнить'),
          style: TextButton.styleFrom(
            foregroundColor: _DS.emerald,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            backgroundColor: _DS.emerald.withValues(alpha: 0.08),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ],
    ),
  );

  void _showTopupSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _TopupSheet(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Traffic card
// ─────────────────────────────────────────────────────────────────────────────

class _TrafficCard extends StatelessWidget {
  final MeSubscription sub;
  final SubscriptionInfo? trafficInfo;
  const _TrafficCard({required this.sub, required this.trafficInfo});

  @override
  Widget build(BuildContext context) {
    final unlimited = sub.trafficLimitGb == 0;
    final usedBytes = trafficInfo?.usedBytes ?? (sub.trafficUsedGb * 1024 * 1024 * 1024).round();
    final totalBytes = trafficInfo?.totalBytes ?? (sub.trafficLimitGb * 1024 * 1024 * 1024).round();
    final fraction = totalBytes > 0 ? (usedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;
    final usedLabel = trafficInfo?.formattedUsed ?? '${sub.trafficUsedGb.toStringAsFixed(1)} ГБ';
    final totalLabel = trafficInfo?.formattedTotal ?? (unlimited ? '∞' : '${sub.trafficLimitGb} ГБ');
    final remainingBytes = totalBytes - usedBytes;
    final remaining = _fmtBytes(remainingBytes);

    final Color barColor;
    if (unlimited) { barColor = _DS.violet; }
    else if (fraction >= 0.9) { barColor = _DS.rose; }
    else if (fraction >= 0.7) { barColor = _DS.amber; }
    else { barColor = _DS.emerald; }

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Трафик', style: TextStyle(
            color: _DS.textSecondary, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.8,
          )),
          const SizedBox(height: 14),

          // Main number
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(usedLabel, style: const TextStyle(
                color: _DS.textPrimary, fontSize: 34, fontWeight: FontWeight.w700, height: 1,
              )),
              const SizedBox(width: 8),
              Text('/ $totalLabel', style: const TextStyle(
                color: _DS.textMuted, fontSize: 18, fontWeight: FontWeight.w400,
              )),
            ],
          ),

          if (!unlimited) ...[
            const SizedBox(height: 16),
            // Progress bar
            Stack(
              children: [
                Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: _DS.surface3,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: fraction,
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: barColor,
                      borderRadius: BorderRadius.circular(3),
                      boxShadow: [BoxShadow(color: barColor.withValues(alpha: 0.4), blurRadius: 6)],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _StatChip(label: 'Осталось', value: remaining),
                _StatChip(label: 'Использовано', value: '${(fraction * 100).toStringAsFixed(1)}%', valueColor: barColor),
              ],
            ),
          ] else ...[
            const SizedBox(height: 14),
            Row(
              children: [
                const Icon(Icons.all_inclusive_rounded, color: _DS.violet, size: 20),
                const SizedBox(width: 8),
                const Text('Безлимитный трафик', style: TextStyle(
                  color: _DS.textPrimary, fontSize: 14, fontWeight: FontWeight.w500,
                )),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _fmtBytes(int bytes) {
    if (bytes <= 0) return '0 ГБ';
    final gb = bytes / (1024 * 1024 * 1024);
    if (gb >= 1) return '${gb.toStringAsFixed(1)} ГБ';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(0)} МБ';
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _StatChip({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: _DS.textMuted, fontSize: 12)),
      const SizedBox(height: 3),
      Text(value, style: TextStyle(
        color: valueColor ?? _DS.textPrimary,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      )),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Autopay card
// ─────────────────────────────────────────────────────────────────────────────

class _AutopayCard extends StatefulWidget {
  final MeSubscription sub;
  final Future<void> Function(bool) onToggle;
  const _AutopayCard({required this.sub, required this.onToggle});

  @override
  State<_AutopayCard> createState() => _AutopayCardState();
}

class _AutopayCardState extends State<_AutopayCard> {
  late bool _enabled;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _enabled = widget.sub.autopayEnabled;
  }

  @override
  void didUpdateWidget(_AutopayCard old) {
    super.didUpdateWidget(old);
    if (old.sub.autopayEnabled != widget.sub.autopayEnabled) {
      _enabled = widget.sub.autopayEnabled;
    }
  }

  Future<void> _toggle(bool value) async {
    setState(() { _enabled = value; _loading = true; });
    try { await widget.onToggle(value); }
    catch (_) { if (mounted) setState(() => _enabled = !value); }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) => _Card(
    child: Row(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: (_enabled ? _DS.violet : _DS.surface3).withValues(alpha: _enabled ? 0.15 : 1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(Icons.autorenew_rounded,
            color: _enabled ? _DS.violet : _DS.textMuted, size: 22,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Автопродление', style: TextStyle(
                color: _DS.textPrimary, fontSize: 14, fontWeight: FontWeight.w600,
              )),
              const SizedBox(height: 2),
              Text(
                _enabled ? 'Подписка продлевается автоматически' : 'Автопродление отключено',
                style: const TextStyle(color: _DS.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
        if (_loading)
          const SizedBox(width: 26, height: 26,
            child: CircularProgressIndicator(strokeWidth: 2, color: _DS.violet),
          )
        else
          Switch(
            value: _enabled,
            onChanged: _toggle,
            activeThumbColor: _DS.violet,
            inactiveThumbColor: _DS.textMuted,
            inactiveTrackColor: _DS.surface3,
          ),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Subscription details
// ─────────────────────────────────────────────────────────────────────────────

class _SubscriptionDetailsCard extends StatelessWidget {
  final MeSubscription sub;
  const _SubscriptionDetailsCard({required this.sub});

  @override
  Widget build(BuildContext context) {
    final isActive = sub.isActive && !sub.isExpired;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Детали', style: TextStyle(
            color: _DS.textSecondary, fontSize: 11, fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          )),
          const SizedBox(height: 16),

          _DetailRow(
            icon: sub.isTrial ? Icons.free_breakfast_rounded : Icons.workspace_premium_rounded,
            label: 'Тип',
            value: sub.isTrial ? 'Пробный' : 'Платный',
          ),
          _Divider(),
          _DetailRow(
            icon: Icons.devices_other_rounded,
            label: 'Устройства',
            value: '${sub.deviceLimit} ${_deviceWord(sub.deviceLimit)}',
          ),
          _Divider(),
          _DetailRow(
            icon: Icons.event_rounded,
            label: 'Действует до',
            value: sub.formattedExpiry,
            valueColor: sub.isExpired ? _DS.rose : null,
          ),
          if (sub.trafficLimitGb > 0) ...[
            _Divider(),
            _DetailRow(
              icon: Icons.compare_arrows_rounded,
              label: 'Лимит трафика',
              value: '${sub.trafficLimitGb} ГБ',
            ),
          ],
          const SizedBox(height: 16),

          // Status pill
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
            decoration: BoxDecoration(
              color: (isActive ? _DS.emerald : sub.isExpired ? _DS.rose : _DS.textMuted)
                  .withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(_DS.radiusXs),
              border: Border.all(
                color: (isActive ? _DS.emerald : sub.isExpired ? _DS.rose : _DS.textMuted)
                    .withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isActive ? Icons.check_circle_rounded
                      : sub.isExpired ? Icons.timer_off_outlined
                      : Icons.help_outline,
                  size: 15,
                  color: isActive ? _DS.emerald : sub.isExpired ? _DS.rose : _DS.textMuted,
                ),
                const SizedBox(width: 8),
                Text(
                  isActive ? 'Подписка активна'
                      : sub.isExpired ? 'Срок действия истёк'
                      : 'Статус неизвестен',
                  style: TextStyle(
                    color: isActive ? _DS.emerald : sub.isExpired ? _DS.rose : _DS.textMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _deviceWord(int n) {
    if (n % 10 == 1 && n % 100 != 11) return 'устройство';
    if (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 10 || n % 100 >= 20)) return 'устройства';
    return 'устройств';
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 0),
    child: Divider(color: _DS.border, height: 20),
  );
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  const _DetailRow({required this.icon, required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 16, color: _DS.textMuted),
      const SizedBox(width: 10),
      Text(label, style: const TextStyle(color: _DS.textSecondary, fontSize: 13)),
      const Spacer(),
      Text(value, style: TextStyle(
        color: valueColor ?? _DS.textPrimary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      )),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Subscription URL card
// ─────────────────────────────────────────────────────────────────────────────

class _SubscriptionUrlCard extends StatefulWidget {
  final String url;
  const _SubscriptionUrlCard({required this.url});

  @override
  State<_SubscriptionUrlCard> createState() => _SubscriptionUrlCardState();
}

class _SubscriptionUrlCardState extends State<_SubscriptionUrlCard> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.url));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) => _Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('URL подписки', style: TextStyle(
          color: _DS.textSecondary, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2,
        )),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _DS.surface2,
            borderRadius: BorderRadius.circular(_DS.radiusXs),
            border: Border.all(color: _DS.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.url,
                  style: const TextStyle(
                    color: _DS.textSecondary, fontSize: 12, fontFamily: 'monospace', height: 1.4,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _copy,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _copied
                        ? _DS.emerald.withValues(alpha: 0.12)
                        : _DS.violet.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    _copied ? Icons.check_rounded : Icons.copy_rounded,
                    size: 18,
                    color: _copied ? _DS.emerald : _DS.violet,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Quick actions
// ─────────────────────────────────────────────────────────────────────────────

class _QuickActionsCard extends StatelessWidget {
  final VoidCallback onLogout;
  final VoidCallback? onPremiumTap;
  const _QuickActionsCard({required this.onLogout, this.onPremiumTap});

  @override
  Widget build(BuildContext context) => _Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Действия', style: TextStyle(
          color: _DS.textSecondary, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2,
        )),
        const SizedBox(height: 12),
        _ActionTile(
          icon: Icons.workspace_premium_rounded,
          color: _DS.amber,
          label: 'Купить / продлить',
          subtitle: 'Перейти на страницу Премиум',
          onTap: onPremiumTap,
        ),
        const Divider(color: _DS.border, height: 16),
        _ActionTile(
          icon: Icons.logout_rounded,
          color: _DS.rose,
          label: 'Выйти из аккаунта',
          onTap: onLogout,
        ),
      ],
    ),
  );
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;
  const _ActionTile({
    required this.icon, required this.color, required this.label,
    this.subtitle, required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(
                    color: onTap != null ? _DS.textPrimary : _DS.textMuted,
                    fontSize: 14, fontWeight: FontWeight.w500,
                  )),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: const TextStyle(color: _DS.textMuted, fontSize: 12)),
                  ],
                ],
              ),
            ),
            if (onTap != null)
              const Icon(Icons.chevron_right_rounded, color: _DS.textMuted, size: 18),
          ],
        ),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Top-up sheet
// ─────────────────────────────────────────────────────────────────────────────

class _TopupSheet extends StatefulWidget {
  const _TopupSheet();

  @override
  State<_TopupSheet> createState() => _TopupSheetState();
}

class _TopupSheetState extends State<_TopupSheet> {
  static const _amounts = [100, 200, 300, 500, 1000, 2000];
  int _selected = 300;
  bool _loading = false;

  Future<void> _onTopup() async {
    setState(() => _loading = true);
    final result = await SubscriptionApiService.topupBalance(amountKopeks: _selected * 100);
    if (!mounted) return;

    if (result == null) {
      _snack('Ошибка соединения с сервером', isError: true);
    } else if (result.requiresPayment && result.paymentUrl != null) {
      Navigator.pop(context);
      final uri = Uri.parse(result.paymentUrl!);
      try {
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } else {
          _snack('Не удалось открыть страницу оплаты', isError: true);
        }
      } catch (_) {
        _snack('Ошибка при открытии оплаты', isError: true);
      }
    } else {
      _snack(result.message ?? 'Ошибка пополнения', isError: true);
    }
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String msg, {required bool isError}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? _DS.rose : _DS.emerald,
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      decoration: const BoxDecoration(
        color: _DS.surface1,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(color: _DS.surface3, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 20),
          const Text('Пополнить баланс', style: TextStyle(
            color: _DS.textPrimary, fontSize: 20, fontWeight: FontWeight.w700,
          )),
          const SizedBox(height: 4),
          const Text('Оплата через YooKassa', style: TextStyle(color: _DS.textSecondary, fontSize: 13)),
          const SizedBox(height: 22),

          Wrap(
            spacing: 8, runSpacing: 8,
            children: _amounts.map((a) {
              final isSel = a == _selected;
              return GestureDetector(
                onTap: () => setState(() => _selected = a),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                  decoration: BoxDecoration(
                    color: isSel ? _DS.emerald.withValues(alpha: 0.12) : _DS.surface2,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isSel ? _DS.emerald : _DS.border,
                      width: isSel ? 1.5 : 1,
                    ),
                  ),
                  child: Text('$a ₽', style: TextStyle(
                    color: isSel ? _DS.emerald : _DS.textPrimary,
                    fontSize: 15, fontWeight: FontWeight.w600,
                  )),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 24),

          SizedBox(
            width: double.infinity, height: 54,
            child: ElevatedButton(
              onPressed: _loading ? null : _onTopup,
              style: ElevatedButton.styleFrom(
                backgroundColor: _DS.emerald,
                foregroundColor: Colors.white,
                disabledBackgroundColor: _DS.emerald.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: _loading
                  ? const SizedBox(height: 22, width: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text('Пополнить на $_selected ₽', style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700,
              )),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Base card
// ─────────────────────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: _DS.surface1,
      borderRadius: BorderRadius.circular(_DS.radius),
      border: Border.all(color: _DS.border),
    ),
    child: child,
  );
}