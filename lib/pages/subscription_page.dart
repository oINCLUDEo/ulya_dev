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
// Design tokens
// ─────────────────────────────────────────────────────────────────────────────

class _DS {
  static const violet      = Color(0xFF7C6FF7);
  static const violetDim   = Color(0xFF4A44AA);
  // Itten complementary to violet — premium membership status.
  static const gold        = Color(0xFFD4A84B);
  static const emerald     = Color(0xFF34D399);
  static const amber       = Color(0xFFFBBF24);
  static const rose        = Color(0xFFF87171);
  static const sky         = Color(0xFF38BDF8);
  static const telegramBlue = Color(0xFF229ED9);

  static const surface0 = Color(0xFF0F0F14);
  static const surface1 = Color(0xFF17171F);
  static const surface2 = Color(0xFF1E1E2A);
  static const surface3 = Color(0xFF26263A);

  static const textPrimary   = Color(0xFFEEEEF8);
  static const textSecondary = Color(0xFF8888AA);
  static const textMuted     = Color(0xFF55556A);
  static const border        = Color(0xFF2A2A3D);

  static const radius   = 20.0;
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

class _SubscriptionPageState extends State<SubscriptionPage>
    with WidgetsBindingObserver {
  bool _loading = false;
  SubscriptionInfo? _trafficInfo;
  DateTime? _lastRefresh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    authStateNotifier.addListener(_onAuthChanged);
    meNotifier.addListener(_onMeChanged);
    globalRefreshNotifier.addListener(_onGlobalRefresh);
    _loadCachedMe();
    _refresh();
  }

  Future<void> _loadCachedMe() async => MeService.loadFromCache();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    authStateNotifier.removeListener(_onAuthChanged);
    meNotifier.removeListener(_onMeChanged);
    globalRefreshNotifier.removeListener(_onGlobalRefresh);
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

  void _onGlobalRefresh() {
    if (!mounted) return;
    if (!_loading) {
      setState(() => _trafficInfo = RemnawaveService.lastSubscriptionInfo);
    } else {
      _trafficInfo = RemnawaveService.lastSubscriptionInfo;
    }
  }

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
      await MeService.refreshAll();
      if (mounted) setState(() => _trafficInfo = RemnawaveService.lastSubscriptionInfo);
    } catch (e, st) {
      debugPrint('SubscriptionPage refresh error: $e\n$st');
    }
    if (mounted) setState(() => _loading = false);
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final auth = authStateNotifier.value;
    final me   = meNotifier.value;

    return Scaffold(
      backgroundColor: _DS.surface0,
      body: RefreshIndicator(
        color: _DS.violet,
        backgroundColor: _DS.surface2,
        onRefresh: () => _refresh(force: true),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: _SubHeader(
                me: me,
                auth: auth,
                isRefreshing: _loading,
                onRefresh: () => _refresh(force: true),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  if (!auth.isLoggedIn) ...[
                    _WelcomeCard(onLoginTap: () => showAuthBottomSheet(context)),
                    const SizedBox(height: 12),
                    _GoPremiumBanner(onTap: _onPremiumTap),
                  ] else if (_loading && me == null) ...[
                    const SizedBox(height: 140),
                    const Center(
                        child: CircularProgressIndicator(
                            color: _DS.violet, strokeWidth: 2.5)),
                  ] else ...[
                    // ── Hero subscription status card ─────────────────────
                    _HeroSubCard(me: me, trafficInfo: _trafficInfo),
                    const SizedBox(height: 20),

                    // ── Traffic ───────────────────────────────────────────
                    if (me?.subscription != null) ...[
                      const _SectionLabel(text: 'ИСПОЛЬЗОВАНИЕ'),
                      const SizedBox(height: 10),
                      _TrafficCard(
                          sub: me!.subscription!, trafficInfo: _trafficInfo),
                      const SizedBox(height: 20),
                    ],

                    // ── Balance + devices ─────────────────────────────────
                    const _SectionLabel(text: 'ФИНАНСЫ'),
                    const SizedBox(height: 10),
                    _QuickInfoRow(
                      me: me,
                      onTopup: () => _showTopupSheet(context),
                    ),
                    const SizedBox(height: 20),

                    // ── Autopay + URL ─────────────────────────────────────
                    if (me?.subscription != null) ...[
                      const _SectionLabel(text: 'НАСТРОЙКИ'),
                      const SizedBox(height: 10),
                      _AutopayCard(
                          sub: me!.subscription!, onToggle: _onAutopayToggle),
                      if (me.subscription!.subscriptionUrl != null) ...[
                        const SizedBox(height: 10),
                        _SubUrlCard(url: me.subscription!.subscriptionUrl!),
                      ],
                      const SizedBox(height: 20),
                    ],

                    // ── Manage plan ───────────────────────────────────────
                    const _SectionLabel(text: 'УПРАВЛЕНИЕ'),
                    const SizedBox(height: 10),
                    _ManagePlanButton(onTap: _onPremiumTap),
                    const SizedBox(height: 10),

                    // ── Logout ────────────────────────────────────────────
                    _LogoutButton(onTap: _onLogout),
                  ],
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Actions ───────────────────────────────────────────────────────────────

  Future<void> _onLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _DS.surface2,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_DS.radius)),
        title: const Text('Выйти из аккаунта?',
            style: TextStyle(
                color: _DS.textPrimary, fontWeight: FontWeight.w700)),
        content: const Text('Данные подписки будут сброшены.',
            style: TextStyle(color: _DS.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Выйти',
                style: TextStyle(color: _DS.rose)),
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
        content: Text('Откройте вкладку «Тарифы» для управления подпиской'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

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
// Header — editorial: большой заголовок + имя пользователя
// ─────────────────────────────────────────────────────────────────────────────

class _SubHeader extends StatelessWidget {
  final MeResponse? me;
  final AuthState   auth;
  final bool        isRefreshing;
  final VoidCallback onRefresh;

  const _SubHeader({
    required this.me,
    required this.auth,
    required this.isRefreshing,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final top  = MediaQuery.of(context).padding.top;
    final name = me?.displayName ??
        (auth.isLoggedIn ? auth.displayName : null);

    return Padding(
      padding: EdgeInsets.fromLTRB(20, top + 18, 20, 18),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text(
              'ПОДПИСКА',
              style: TextStyle(
                color: _DS.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 2.5,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Мой аккаунт',
              style: TextStyle(
                color: _DS.textPrimary,
                fontSize: 30,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.8,
                height: 1,
              ),
            ),
            if (name != null && name.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(children: [
                Container(
                  width: 6, height: 6,
                  decoration: const BoxDecoration(
                    color: _DS.violet, shape: BoxShape.circle),
                ),
                const SizedBox(width: 7),
                Text(name,
                    style: const TextStyle(
                        color: _DS.textSecondary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500)),
              ]),
            ],
          ]),
        ),
        const SizedBox(width: 12),
        _RefreshButton(isRefreshing: isRefreshing, onTap: onRefresh),
      ]),
    );
  }
}

// Animated refresh button extracted for proper dispose
class _RefreshButton extends StatefulWidget {
  final bool isRefreshing;
  final VoidCallback onTap;
  const _RefreshButton({required this.isRefreshing, required this.onTap});

  @override
  State<_RefreshButton> createState() => _RefreshButtonState();
}

class _RefreshButtonState extends State<_RefreshButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotCtrl;

  @override
  void initState() {
    super.initState();
    _rotCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700));
    if (widget.isRefreshing) _rotCtrl.repeat();
  }

  @override
  void didUpdateWidget(_RefreshButton old) {
    super.didUpdateWidget(old);
    if (widget.isRefreshing && !old.isRefreshing) {
      _rotCtrl.repeat();
    } else if (!widget.isRefreshing && old.isRefreshing) {
      final remaining = 1.0 - (_rotCtrl.value % 1.0);
      if (remaining > 0 && remaining < 1.0) {
        _rotCtrl
            .animateTo(_rotCtrl.value + remaining,
                duration: Duration(
                    milliseconds:
                        (remaining * 700).round().clamp(1, 700)))
            .then((_) { if (mounted) _rotCtrl.reset(); });
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
        onTap: widget.isRefreshing ? null : widget.onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: _DS.surface2,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _DS.border),
          ),
          child: RotationTransition(
            turns: _rotCtrl,
            child: const Icon(Icons.refresh_rounded,
                color: _DS.textSecondary, size: 20),
          ),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Welcome card (not logged in)
// ─────────────────────────────────────────────────────────────────────────────

class _WelcomeCard extends StatelessWidget {
  final VoidCallback onLoginTap;
  const _WelcomeCard({required this.onLoginTap});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF1A1730), Color(0xFF11101A)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: _DS.violet.withValues(alpha: 0.25)),
        ),
        child: Column(children: [
          Container(
            width: 82,
            height: 82,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [_DS.violet, _DS.violetDim],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: _DS.violet.withValues(alpha: 0.40),
                  blurRadius: 28,
                  offset: const Offset(0, 8),
                )
              ],
            ),
            child: const Icon(Icons.person_rounded,
                color: Colors.white, size: 38),
          ),
          const SizedBox(height: 22),
          const Text(
            'Войдите в аккаунт',
            style: TextStyle(
              color: _DS.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'Управляйте подпиской, следите\nза трафиком и балансом',
            style: TextStyle(
                color: _DS.textSecondary, fontSize: 14, height: 1.55),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 26),
          TelegramLoginButton(onTap: onLoginTap),
        ]),
      );
}

class _GoPremiumBanner extends StatelessWidget {
  final VoidCallback onTap;
  const _GoPremiumBanner({required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            color: _DS.surface1,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _DS.border),
          ),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: _DS.gold.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Icon(Icons.workspace_premium_rounded,
                  color: _DS.gold, size: 22),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Посмотреть тарифы',
                        style: TextStyle(
                            color: _DS.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    SizedBox(height: 3),
                    Text('Быстрый и надёжный VPN',
                        style: TextStyle(
                            color: _DS.textSecondary, fontSize: 12)),
                  ]),
            ),
            const Icon(Icons.arrow_forward_ios_rounded,
                color: _DS.textMuted, size: 15),
          ]),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// Hero subscription card
//
// Design language — Itten colour wheel:
//   • Base: deep indigo-violet (#0D0A26) — analogous cool palette
//   • Accent: gold (#D4A84B) — Itten complementary to violet (opposite on wheel)
//   • Support: sky-blue (analogous) for traffic, violet (analogous) for devices
//   • Urgency degradation: gold → amber → rose as expiry nears
//
// Layout: membership-card silhouette with a thin gradient top stripe,
// a three-column stat grid (ДНЕЙ / УСТРОЙСТВ / ТРАФИК) and a time bar.
// ─────────────────────────────────────────────────────────────────────────────

// Gold — Itten complementary to the brand's indigo/violet.
const _gold = Color(0xFFD4A84B);

class _HeroSubCard extends StatelessWidget {
  final MeResponse? me;
  final SubscriptionInfo? trafficInfo;
  const _HeroSubCard({required this.me, this.trafficInfo});

  // Russian day-word declension
  static String _dayLabel(int n) {
    final abs = n.abs() % 100;
    final last = abs % 10;
    if (abs >= 11 && abs <= 19) return 'дней';
    if (last == 1) return 'день';
    if (last >= 2 && last <= 4) return 'дня';
    return 'дней';
  }


  @override
  Widget build(BuildContext context) {
    final sub = me?.subscription;

    // ── State → visual tokens ────────────────────────────────────────────
    final Color accent;
    final List<Color> bgGrad;
    final String badgeText;
    final bool   isLive;
    final String daysValue;
    final String daysUnit;
    final String? expiryHint;
    // Traffic bar data (populated only for limited active plans)
    double trafficFrac     = 0.0;
    String trafficUsedLbl  = '';
    String trafficTotalLbl = '';
    Color  trafficBarColor = _DS.sky;
    bool   hasTrafficBar   = false;

    if (sub == null) {
      accent      = _DS.textMuted;
      bgGrad      = [const Color(0xFF111118), const Color(0xFF0C0C10)];
      badgeText   = 'НЕТ ПОДПИСКИ';
      isLive      = false;
      daysValue   = '—';
      daysUnit    = 'нет данных';
      expiryHint  = null;
    } else if (sub.isExpired) {
      final diff = sub.expireDate != null
          ? DateTime.now().difference(sub.expireDate!).inDays
          : 0;
      accent      = _DS.rose;
      bgGrad      = [const Color(0xFF1E0A0C), const Color(0xFF150809)];
      badgeText   = 'ИСТЕКЛА';
      isLive      = false;
      daysValue   = '$diff';
      daysUnit    = '${_dayLabel(diff)} назад';
      expiryHint  = sub.expireDate != null
          ? 'истекла ${sub.formattedExpiry}'
          : null;
    } else {
      final days = sub.expireDate?.difference(DateTime.now()).inDays;
      // Itten urgency: gold (safe) → amber (caution) → rose (critical)
      if (days == null || days > 7) {
        accent = _gold;
        bgGrad = [const Color(0xFF0D0B26), const Color(0xFF0A0820)];
      } else if (days > 3) {
        accent = _DS.amber;
        bgGrad = [const Color(0xFF1A1306), const Color(0xFF120E04)];
      } else {
        accent = _DS.rose;
        bgGrad = [const Color(0xFF1E0A0C), const Color(0xFF150809)];
      }
      badgeText   = sub.isTrial ? 'ПРОБНЫЙ' : 'АКТИВНА';
      isLive      = true;
      daysValue   = days != null ? '$days' : '∞';
      daysUnit    = days == null
          ? 'бессрочно'
          : sub.isTrial
              ? '${_dayLabel(days)} пробного'
              : _dayLabel(days);
      expiryHint  = sub.expireDate != null ? 'до ${sub.formattedExpiry}' : null;

      // Compute traffic data for limited plans
      if (sub.trafficLimitGb > 0) {
        hasTrafficBar = true;
        final usedBytes = trafficInfo?.usedBytes ??
            (sub.trafficUsedGb * 1024 * 1024 * 1024).round();
        final totalBytes = (trafficInfo != null && trafficInfo!.totalBytes > 0)
            ? trafficInfo!.totalBytes
            : (sub.trafficLimitGb * 1024 * 1024 * 1024).round();
        trafficFrac = totalBytes > 0
            ? (usedBytes / totalBytes).clamp(0.0, 1.0)
            : 0.0;
        trafficUsedLbl = trafficInfo?.formattedUsed ??
            '${sub.trafficUsedGb.toStringAsFixed(1)} ГБ';
        trafficTotalLbl = (trafficInfo != null && trafficInfo!.totalBytes > 0)
            ? trafficInfo!.formattedTotal
            : '${sub.trafficLimitGb} ГБ';
        trafficBarColor = trafficFrac >= 0.9
            ? _DS.rose
            : trafficFrac >= 0.7
                ? _DS.amber
                : _DS.sky;
      }
    }

    final planLabel = sub?.planName ?? (sub?.isTrial == true ? 'Пробный' : null);
    final bool showBottomRow = sub != null;

    // Badge colour: emerald for a healthy active sub (intuitive "all OK" signal).
    // Urgency states (trial/expiring/expired) stay with the urgency accent colour.
    final Color badgeColor = (isLive && !sub!.isTrial && accent == _gold)
        ? _DS.emerald
        : accent;

    return Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: bgGrad,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: accent.withValues(alpha: 0.28), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.10),
            blurRadius: 36,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── Top accent stripe: animated shimmer (Itten pair gold ↔ violet) ─
          _ShimmerStripe(leading: accent, trailing: _DS.violet),

          Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, showBottomRow ? 16 : 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [

                // ── Status badge + plan name ──────────────────────────────
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: badgeColor.withValues(alpha: 0.30)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (isLive) ...[
                        _PulsingDot(color: badgeColor),
                        const SizedBox(width: 6),
                      ] else ...[
                        Icon(Icons.timer_off_rounded,
                            color: badgeColor, size: 11),
                        const SizedBox(width: 5),
                      ],
                      Text(
                        badgeText,
                        style: TextStyle(
                          color: badgeColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ]),
                  ),

                  const Spacer(),

                  if (planLabel != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: _DS.surface2,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: accent.withValues(alpha: 0.18)),
                      ),
                      child: Text(
                        planLabel,
                        style: const TextStyle(
                          color: _DS.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ]),

                const SizedBox(height: 22),

                // ── Three-column stat grid ────────────────────────────────
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _StatCell(
                        value: daysValue,
                        unit: daysUnit,
                        color: accent,
                        heroSize: true,
                      ),

                      if (sub != null) ...[
                        _StatDivider(color: accent),
                        _StatCell(
                          value: '${sub.deviceLimit}',
                          unit: 'УСТРОЙСТВ',
                          color: _DS.violet,
                        ),
                        _StatDivider(color: accent),
                        _StatCell(
                          value: sub.trafficLimitGb == 0
                              ? '∞'
                              : '${sub.trafficLimitGb}',
                          unit: sub.trafficLimitGb == 0 ? 'ГБ БЕЗЛИМ' : 'ГБ',
                          color: _DS.sky,
                        ),
                      ],
                    ],
                  ),
                ),

                // ── Traffic usage bar (limited active plans only) ─────────
                if (hasTrafficBar) ...[
                  const SizedBox(height: 16),
                  Row(children: [
                    Icon(Icons.storage_rounded,
                        color: _DS.textMuted, size: 12),
                    const SizedBox(width: 5),
                    RichText(text: TextSpan(children: [
                      TextSpan(
                        text: trafficUsedLbl,
                        style: TextStyle(
                          color: trafficBarColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(
                        text: ' / $trafficTotalLbl',
                        style: const TextStyle(
                          color: _DS.textMuted, fontSize: 12,
                        ),
                      ),
                    ])),
                    const Spacer(),
                    Text(
                      '${(trafficFrac * 100).toStringAsFixed(0)}%',
                      style: TextStyle(
                        color: trafficBarColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: Stack(children: [
                      Container(height: 4, color: _DS.surface3),
                      FractionallySizedBox(
                        widthFactor: trafficFrac,
                        child: Container(
                          height: 4,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: [
                              trafficBarColor,
                              Color.lerp(trafficBarColor, Colors.white, 0.2)!,
                            ]),
                            boxShadow: [BoxShadow(
                              color: trafficBarColor.withValues(alpha: 0.5),
                              blurRadius: 6,
                            )],
                          ),
                        ),
                      ),
                    ]),
                  ),
                ],
              ],
            ),
          ),

          // ── Bottom info row: expiry + autopay ─────────────────────────
          if (showBottomRow) ...[
            Container(
                height: 1,
                color: _DS.border.withValues(alpha: 0.5)),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
              child: Row(children: [
                if (expiryHint != null) ...[
                  Icon(Icons.calendar_today_outlined,
                      color: accent, size: 13),
                  const SizedBox(width: 6),
                  Text(
                    expiryHint,
                    style: TextStyle(
                      color: accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const Spacer(),
                Icon(
                  Icons.autorenew_rounded,
                  color: sub.autopayEnabled
                      ? _DS.emerald
                      : _DS.textMuted,
                  size: 13,
                ),
                const SizedBox(width: 5),
                Text(
                  sub.autopayEnabled
                      ? 'Автопродление'
                      : 'Без автопродления',
                  style: TextStyle(
                    color: sub.autopayEnabled
                        ? _DS.emerald
                        : _DS.textMuted,
                    fontSize: 12,
                  ),
                ),
              ]),
            ),
          ],
        ],
      ),
    );
  }
}

// Single stat cell used in the three-column grid
class _StatCell extends StatelessWidget {
  final String value;
  final String unit;
  final Color  color;
  final bool   heroSize; // larger font for the "days" cell

  const _StatCell({
    required this.value,
    required this.unit,
    required this.color,
    this.heroSize = false,
  });

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: heroSize ? 46 : 26,
            fontWeight: FontWeight.w900,
            height: 1,
            letterSpacing: heroSize ? -2 : -0.5,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          unit,
          style: const TextStyle(
            color: _DS.textSecondary,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      ],
    ),
  );
}

// Thin vertical divider between stat cells
class _StatDivider extends StatelessWidget {
  final Color color;
  const _StatDivider({required this.color});

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    margin: const EdgeInsets.fromLTRB(14, 0, 14, 0),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: 0.20),
          color.withValues(alpha: 0.06),
        ],
      ),
    ),
  );
}


// ── Animated shimmer stripe (sweeping white flash left → right) ──────────────

class _ShimmerStripe extends StatefulWidget {
  final Color leading;   // accent colour (gold / amber / rose)
  final Color trailing;  // brand colour (violet)
  const _ShimmerStripe({required this.leading, required this.trailing});

  @override
  State<_ShimmerStripe> createState() => _ShimmerStripeState();
}

class _ShimmerStripeState extends State<_ShimmerStripe>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 3,
    child: Stack(children: [
      // Base: static colour band (always visible)
      Positioned.fill(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [widget.leading, widget.trailing],
            ),
          ),
        ),
      ),
      // Sweep: a diagonal white flash that glides left → right.
      // x goes −1.6 → +1.6, so the beam is fully off-screen at both
      // endpoints and the loop restart is seamless (no jump).
      AnimatedBuilder(
        animation: _ctrl,
        builder: (_, child) {
          final x = -1.6 + _ctrl.value * 3.2;
          return Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment(x - 0.4, -1),
                  end:   Alignment(x + 0.4,  1),
                  colors: [
                    Colors.transparent,
                    Colors.white.withValues(alpha: 0.55),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ]),
  );
}


class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double>   _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat(reverse: true);
    _scale = Tween<double>(begin: 0.7, end: 1.3)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(
        scale: _scale,
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                  color: widget.color.withValues(alpha: 0.6), blurRadius: 8)
            ],
          ),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Section label — editorial разделитель секций
// ─────────────────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel({required this.text});

  @override
  Widget build(BuildContext context) => Row(children: [
    Text(text, style: const TextStyle(
        color: _DS.textMuted, fontSize: 10,
        fontWeight: FontWeight.w700, letterSpacing: 2.0)),
    const SizedBox(width: 10),
    Expanded(child: Container(height: 1, color: _DS.border)),
  ]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Traffic card — editorial: крупный процент + прогресс-бар
// ─────────────────────────────────────────────────────────────────────────────

class _TrafficCard extends StatelessWidget {
  final MeSubscription  sub;
  final SubscriptionInfo? trafficInfo;
  const _TrafficCard({required this.sub, required this.trafficInfo});

  @override
  Widget build(BuildContext context) {
    final unlimited = sub.trafficLimitGb == 0 &&
        (trafficInfo == null || trafficInfo!.totalBytes == 0);
    final usedBytes = trafficInfo?.usedBytes ??
        (sub.trafficUsedGb * 1024 * 1024 * 1024).round();
    final totalBytes =
        (trafficInfo != null && trafficInfo!.totalBytes > 0)
            ? trafficInfo!.totalBytes
            : (sub.trafficLimitGb == 0
                ? 0
                : (sub.trafficLimitGb * 1024 * 1024 * 1024));
    final fraction =
        totalBytes > 0 ? (usedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;
    final usedLabel = trafficInfo?.formattedUsed ??
        '${sub.trafficUsedGb.toStringAsFixed(1)} ГБ';
    final totalLabel = unlimited
        ? '∞'
        : (trafficInfo != null && trafficInfo!.totalBytes > 0
            ? trafficInfo!.formattedTotal
            : '${sub.trafficLimitGb} ГБ');
    final remainingBytes = totalBytes - usedBytes;

    final Color barColor;
    if (unlimited) {
      barColor = _DS.violet;
    } else if (fraction >= 0.9) {
      barColor = _DS.rose;
    } else if (fraction >= 0.7) {
      barColor = _DS.amber;
    } else {
      barColor = _DS.emerald;
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        color: _DS.surface1,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _DS.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ── Header ────────────────────────────────────────────────────────
        Row(children: [
          Text(
            unlimited ? '∞' : '${(fraction * 100).toStringAsFixed(0)}%',
            style: TextStyle(
              color: barColor,
              fontSize: 44, fontWeight: FontWeight.w800, letterSpacing: -2, height: 1,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(unlimited ? 'Безлимит' : 'использовано',
                style: const TextStyle(
                    color: _DS.textSecondary, fontSize: 13, fontWeight: FontWeight.w500)),
            if (!unlimited) ...[
              const SizedBox(height: 2),
              RichText(
                text: TextSpan(children: [
                  TextSpan(text: usedLabel, style: TextStyle(
                      color: barColor, fontSize: 14, fontWeight: FontWeight.w700)),
                  TextSpan(text: ' / $totalLabel', style: const TextStyle(
                      color: _DS.textMuted, fontSize: 13)),
                ]),
              ),
            ],
          ])),
          if (!unlimited)
            Text('осталось\n${_fmtBytes(remainingBytes)}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                  color: _DS.textSecondary, fontSize: 12, height: 1.4)),
        ]),

        if (!unlimited) ...[
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(children: [
              Container(height: 7, color: _DS.surface3),
              FractionallySizedBox(
                widthFactor: fraction,
                child: Container(
                  height: 7,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [
                      barColor,
                      Color.lerp(barColor, Colors.white, 0.22)!,
                    ]),
                    boxShadow: [BoxShadow(
                        color: barColor.withValues(alpha: 0.5), blurRadius: 8)],
                  ),
                ),
              ),
            ]),
          ),
        ] else ...[
          const SizedBox(height: 12),
          Row(children: [
            const Icon(Icons.all_inclusive_rounded, color: _DS.violet, size: 16),
            const SizedBox(width: 7),
            const Text('Трафик без ограничений',
                style: TextStyle(color: _DS.textSecondary, fontSize: 13)),
          ]),
        ],
      ]),
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

// ─────────────────────────────────────────────────────────────────────────────
// Quick info row — balance tile + devices tile side by side
// ─────────────────────────────────────────────────────────────────────────────

class _QuickInfoRow extends StatelessWidget {
  final MeResponse?  me;
  final VoidCallback onTopup;
  const _QuickInfoRow({required this.me, required this.onTopup});

  @override
  Widget build(BuildContext context) {
    final balanceRub  = me?.balanceRub ?? 0.0;
    final currency    = me?.balanceCurrency ?? 'RUB';
    final devices     = me?.subscription?.deviceLimit;

    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: _InfoTile(
            icon: Icons.account_balance_wallet_rounded,
            iconColor: _DS.emerald,
            label: 'БАЛАНС',
            value: '${balanceRub.toStringAsFixed(0)} $currency',
            actionLabel: 'Пополнить',
            onAction: onTopup,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _InfoTile(
            icon: Icons.devices_rounded,
            iconColor: _DS.violet,
            label: 'УСТРОЙСТВА',
            value: devices != null ? '$devices ${_devWord(devices)}' : '—',
          ),
        ),
      ]),
    );
  }

  String _devWord(int n) {
    if (n % 10 == 1 && n % 100 != 11) return 'устройство';
    if (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 10 || n % 100 >= 20))
      return 'устройства';
    return 'устройств';
  }
}

class _InfoTile extends StatelessWidget {
  final IconData     icon;
  final Color        iconColor;
  final String       label;
  final String       value;
  final String?      actionLabel;
  final VoidCallback? onAction;

  const _InfoTile({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: _DS.surface1,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _DS.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 16),
            ),
            const Spacer(),
            if (actionLabel != null && onAction != null)
              GestureDetector(
                onTap: onAction,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: iconColor.withValues(alpha: 0.18)),
                  ),
                  child: Text(actionLabel!,
                      style: TextStyle(
                          color: iconColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ),
              ),
          ]),
          const SizedBox(height: 10),
          Text(label, style: TextStyle(
              color: _DS.textMuted, fontSize: 9,
              fontWeight: FontWeight.w700, letterSpacing: 1.5)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(
              color: _DS.textPrimary, fontSize: 20,
              fontWeight: FontWeight.w800, height: 1.05)),
        ]),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Autopay card
// ─────────────────────────────────────────────────────────────────────────────

class _AutopayCard extends StatefulWidget {
  final MeSubscription                sub;
  final Future<void> Function(bool)   onToggle;
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
        child: Row(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _enabled
                  ? _DS.violet.withValues(alpha: 0.15)
                  : _DS.surface3,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(Icons.autorenew_rounded,
                color: _enabled ? _DS.violet : _DS.textMuted, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Автопродление',
                  style: TextStyle(
                      color: _DS.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                _enabled
                    ? 'Подписка продлевается автоматически'
                    : 'Автопродление отключено',
                style: const TextStyle(
                    color: _DS.textSecondary, fontSize: 12),
              ),
            ]),
          ),
          if (_loading)
            const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: _DS.violet))
          else
            Switch(
              value: _enabled,
              onChanged: _toggle,
              activeColor: _DS.violet,
            ),
        ]),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Subscription URL card
// ─────────────────────────────────────────────────────────────────────────────

class _SubUrlCard extends StatefulWidget {
  final String url;
  const _SubUrlCard({required this.url});

  @override
  State<_SubUrlCard> createState() => _SubUrlCardState();
}

class _SubUrlCardState extends State<_SubUrlCard> {
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
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _DS.sky.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.link_rounded, color: _DS.sky, size: 17),
            ),
            const SizedBox(width: 12),
            const Text('URL подписки',
                style: TextStyle(
                    color: _DS.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            const Spacer(),
            GestureDetector(
              onTap: _copy,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: _copied
                      ? _DS.emerald.withValues(alpha: 0.12)
                      : _DS.violet.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                      _copied
                          ? Icons.check_rounded
                          : Icons.copy_rounded,
                      size: 13,
                      color: _copied ? _DS.emerald : _DS.violet),
                  const SizedBox(width: 5),
                  Text(
                      _copied ? 'Скопировано' : 'Копировать',
                      style: TextStyle(
                          color: _copied ? _DS.emerald : _DS.violet,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: _DS.surface2,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _DS.border),
            ),
            child: Text(
              widget.url,
              style: const TextStyle(
                color: _DS.textSecondary,
                fontSize: 11,
                fontFamily: 'monospace',
                height: 1.4,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Manage plan button — big, violet, prominent CTA
// ─────────────────────────────────────────────────────────────────────────────

class _ManagePlanButton extends StatelessWidget {
  final VoidCallback? onTap;
  const _ManagePlanButton({required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 60,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [_DS.violet, _DS.violetDim],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                  color: _DS.violet.withValues(alpha: 0.38),
                  blurRadius: 22,
                  offset: const Offset(0, 6))
            ],
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.workspace_premium_rounded,
                color: Colors.white, size: 20),
            const SizedBox(width: 10),
            const Text('Управление тарифом',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(7)),
              child: const Icon(Icons.arrow_forward_rounded,
                  color: Colors.white, size: 13),
            ),
          ]),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Logout button — subtle, red border
// ─────────────────────────────────────────────────────────────────────────────

class _LogoutButton extends StatelessWidget {
  final VoidCallback onTap;
  const _LogoutButton({required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            color: _DS.surface1,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _DS.rose.withValues(alpha: 0.30)),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.logout_rounded, color: _DS.rose, size: 18),
            const SizedBox(width: 8),
            const Text('Выйти из аккаунта',
                style: TextStyle(
                    color: _DS.rose,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
          ]),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared card container
// ─────────────────────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: _DS.surface1,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _DS.border),
        ),
        child: child,
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
  static const _amounts    = [100, 200, 300, 500, 1000, 2000];
  static const _minAmount  = 50;
  static const _maxAmount  = 100000;

  int? _selected = 300;
  bool _loading  = false;

  final _customController = TextEditingController();
  final _focusNode        = FocusNode();

  int? get _resolvedAmount {
    if (_selected != null) return _selected;
    final raw = _customController.text.trim();
    return int.tryParse(raw.replaceAll(RegExp(r'[^\d]'), ''));
  }

  @override
  void initState() {
    super.initState();
    _customController.addListener(() {
      if (_customController.text.isNotEmpty) {
        if (mounted) setState(() => _selected = null);
      }
    });
  }

  @override
  void dispose() {
    _customController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _onTopup() async {
    final amount = _resolvedAmount;
    if (amount == null || amount < _minAmount) {
      _snack('Минимальная сумма — $_minAmount ₽', isError: true);
      return;
    }
    if (amount > _maxAmount) {
      _snack('Максимальная сумма — $_maxAmount ₽', isError: true);
      return;
    }
    setState(() => _loading = true);
    final result =
        await SubscriptionApiService.topupBalance(amountKopeks: amount * 100);
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
    final amount   = _resolvedAmount;
    final canSubmit =
        amount != null && amount >= _minAmount && amount <= _maxAmount;
    final buttonLabel =
        canSubmit ? 'Пополнить на $amount ₽' : 'Пополнить';

    return Container(
      margin:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      decoration: const BoxDecoration(
        color: _DS.surface1,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: _DS.border,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 20),

          const Text('Пополнить баланс',
              style: TextStyle(
                  color: _DS.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('Выберите сумму или введите свою',
              style:
                  TextStyle(color: _DS.textSecondary, fontSize: 14)),
          const SizedBox(height: 20),

          // Preset chips
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final a in _amounts)
              GestureDetector(
                onTap: () {
                  _focusNode.unfocus();
                  _customController.clear();
                  setState(() => _selected = a);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 10),
                  decoration: BoxDecoration(
                    color: _selected == a
                        ? _DS.violet.withValues(alpha: 0.18)
                        : _DS.surface2,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: _selected == a
                            ? _DS.violet.withValues(alpha: 0.6)
                            : _DS.border,
                        width: _selected == a ? 1.5 : 1),
                  ),
                  child: Text('$a ₽',
                      style: TextStyle(
                          color: _selected == a
                              ? _DS.violet
                              : _DS.textSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                ),
              ),
          ]),
          const SizedBox(height: 16),

          // Custom amount
          TextField(
            controller: _customController,
            focusNode: _focusNode,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: _DS.textPrimary, fontSize: 15),
            decoration: InputDecoration(
              hintText: 'Другая сумма, ₽',
              prefixIcon: const Icon(Icons.edit_rounded,
                  color: _DS.textMuted, size: 18),
              filled: true,
              fillColor: _DS.surface2,
              hintStyle: const TextStyle(color: _DS.textMuted),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 14),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(_DS.radiusSm),
                  borderSide: const BorderSide(color: _DS.border)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(_DS.radiusSm),
                  borderSide: const BorderSide(color: _DS.border)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(_DS.radiusSm),
                  borderSide:
                      const BorderSide(color: _DS.violet, width: 1.5)),
            ),
          ),
          const SizedBox(height: 20),

          // Submit button
          GestureDetector(
            onTap: (canSubmit && !_loading) ? _onTopup : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 56,
              width: double.infinity,
              decoration: BoxDecoration(
                gradient: canSubmit
                    ? const LinearGradient(
                        colors: [Color(0xFF7C6FF7), Color(0xFF4A44AA)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight)
                    : null,
                color: canSubmit ? null : _DS.surface2,
                borderRadius: BorderRadius.circular(16),
                boxShadow: canSubmit
                    ? [
                        BoxShadow(
                            color: _DS.violet.withValues(alpha: 0.35),
                            blurRadius: 20,
                            offset: const Offset(0, 6))
                      ]
                    : null,
              ),
              child: Center(
                child: _loading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: Colors.white))
                    : Text(buttonLabel,
                        style: TextStyle(
                            color: canSubmit
                                ? Colors.white
                                : _DS.textMuted,
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
