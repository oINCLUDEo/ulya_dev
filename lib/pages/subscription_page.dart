import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart' show DS;

import '../models/me_response.dart';
import '../models/subscription_info.dart';
import '../services/auth_service.dart';
import '../services/auth_state.dart';
import '../services/me_service.dart';
import '../services/remnawave_service.dart';
import '../services/subscription_api_service.dart';
import '../widgets/telegram_login_button.dart';
import 'auth_bottom_sheet.dart';
import 'change_tariff_page.dart';
import 'renew_page.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SubscriptionPage — экран «Аккаунт»
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
  bool _autopayEnabled = false;
  bool _autopayLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    authStateNotifier.addListener(_onAuthChanged);
    meNotifier.addListener(_onMeChanged);
    globalRefreshNotifier.addListener(_onGlobalRefresh);
    // Cache is loaded in main() before runApp — no per-page cache call needed.
    _refresh();
    _autopayEnabled = meNotifier.value?.subscription?.autopayEnabled ?? false;
  }

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

  void _onMeChanged() {
    if (mounted) {
      setState(() {
        _autopayEnabled =
            meNotifier.value?.subscription?.autopayEnabled ?? false;
      });
    }
  }

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
      if (mounted) {
        setState(() => _trafficInfo = RemnawaveService.lastSubscriptionInfo);
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
      backgroundColor: DS.surface0,
      body: RefreshIndicator(
        color: DS.violet,
        backgroundColor: DS.surface2,
        onRefresh: () => _refresh(force: true),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: _SubHeader(
                isRefreshing: _loading,
                onRefresh: () => _refresh(force: true),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  if (!auth.isLoggedIn) ...[
                    _WelcomeCard(
                        onLoginTap: () => showAuthBottomSheet(context)),
                    const SizedBox(height: 12),
                    _GoPremiumBanner(onTap: _onPremiumTap),
                  ] else if (me == null && _loading) ...[
                    // Only show full-screen spinner when there is absolutely no
                    // cached data yet (very first launch after install).
                    const SizedBox(height: 140),
                    const Center(
                      child: CircularProgressIndicator(
                          color: DS.violet, strokeWidth: 2.5),
                    ),
                  ] else ...[
                    _StatusCard(
                      me: me,
                      onRenew: _onRenewTap,
                      onChangePlan: _onChangePlanTap,
                    ),
                    const SizedBox(height: 12),
                    if (me?.subscription != null) ...[
                      _TrafficSectionCard(
                        sub: me!.subscription!,
                        trafficInfo: _trafficInfo,
                      ),
                      const SizedBox(height: 12),
                    ],
                    _BalanceRow(
                      me: me,
                      onTopup: () => _showTopupSheet(context),
                    ),
                    if (me?.subscription != null) ...[
                      const SizedBox(height: 12),
                      _AutopayCard(
                        enabled: _autopayEnabled,
                        loading: _autopayLoading,
                        onToggle: _onAutopayToggle,
                      ),
                      const SizedBox(height: 12),
                      const _DevicesCard(),
                    ],
                    const SizedBox(height: 24),
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
        backgroundColor: DS.surface2,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DS.radius)),
        title: const Text('Выйти из аккаунта?',
            style: TextStyle(
                color: DS.textPrimary, fontWeight: FontWeight.w700)),
        content: const Text('Данные подписки будут сброшены.',
            style: TextStyle(color: DS.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Выйти',
                style: TextStyle(color: DS.rose)),
          ),
        ],
      ),
    );
    if (confirm == true) await AuthService.logout();
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

  void _onRenewTap() {
    Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const RenewPage()),
    );
  }

  void _onChangePlanTap() {
    Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const ChangeTariffPage()),
    );
  }

  void _showTopupSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _TopupSheet(),
    );
  }

  Future<void> _onAutopayToggle(bool value) async {
    setState(() {
      _autopayEnabled = value;
      _autopayLoading = true;
    });
    try {
      await SubscriptionApiService.setAutopay(enabled: value);
      await MeService.refresh();
    } catch (_) {
      if (mounted) setState(() => _autopayEnabled = !value);
    }
    if (mounted) setState(() => _autopayLoading = false);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Header
// ─────────────────────────────────────────────────────────────────────────────

class _SubHeader extends StatelessWidget {
  final bool isRefreshing;
  final VoidCallback onRefresh;

  const _SubHeader({required this.isRefreshing, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final canPop = Navigator.canPop(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          canPop ? 8 : 20, top + 18, 20, 18),
      child: Row(
        children: [
          if (canPop) ...[
            IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.chevron_left_rounded,
                  color: DS.textPrimary, size: 28),
              splashRadius: 20,
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 2),
          ],
          const Expanded(
            child: Text(
              'Аккаунт',
              style: TextStyle(
                color: DS.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          _RefreshButton(isRefreshing: isRefreshing, onTap: onRefresh),
        ],
      ),
    );
  }
}

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
            .then((_) {
          if (mounted) _rotCtrl.reset();
        });
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
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: DS.surface1,
            shape: BoxShape.circle,
          ),
          child: RotationTransition(
            turns: _rotCtrl,
            child: const Icon(Icons.refresh_rounded,
                color: DS.textSecondary, size: 18),
          ),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Status card — два состояния: активна / истекла
// ─────────────────────────────────────────────────────────────────────────────

class _StatusCard extends StatelessWidget {
  final MeResponse? me;
  final VoidCallback onRenew;
  final VoidCallback onChangePlan;

  const _StatusCard({
    required this.me,
    required this.onRenew,
    required this.onChangePlan,
  });

  static const _months = [
    'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
    'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
  ];

  static String _monthRu(int m) => _months[(m - 1).clamp(0, 11)];

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

    // ── No subscription ───────────────────────────────────────────────────────
    if (sub == null) {
      return _CardShell(
        accentColor: DS.textMuted,
        gradientStart: const Color(0x00000000),
        gradientEnd: const Color(0x00000000),
        borderColor: DS.border,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                  width: 6, height: 6,
                  decoration: const BoxDecoration(
                      color: DS.textMuted, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              const Text('НЕТ ПОДПИСКИ',
                  style: TextStyle(
                      color: DS.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8)),
            ]),
            const SizedBox(height: 10),
            const Text('Подписка не активна',
                style: TextStyle(
                    color: DS.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('Подключение к VPN недоступно',
                style: TextStyle(color: DS.textSecondary, fontSize: 13)),
            const SizedBox(height: 16),
            _PrimaryButton(
                label: 'Продлить',
                icon: Icons.refresh_rounded,
                onTap: onRenew),
          ],
        ),
      );
    }

    // ── Expired ───────────────────────────────────────────────────────────────
    if (sub.isExpired) {
      final expDate = sub.expireDate;
      final badge = expDate != null
          ? 'Истекла ${expDate.day} ${_monthRu(expDate.month)}'.toUpperCase()
          : 'ИСТЕКЛА';
      final planTitle =
          sub.planName != null ? 'Тариф «${sub.planName}»' : 'Тариф истёк';

      return _CardShell(
        accentColor: DS.rose,
        gradientStart: DS.rose.withValues(alpha: 0.12),
        gradientEnd: DS.rose.withValues(alpha: 0.04),
        borderColor: DS.rose.withValues(alpha: 0.30),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                  width: 6, height: 6,
                  decoration: const BoxDecoration(
                      color: DS.rose, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(badge,
                  style: const TextStyle(
                      color: DS.rose,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8)),
            ]),
            const SizedBox(height: 10),
            Text(planTitle,
                style: const TextStyle(
                    color: DS.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('Подключение к VPN недоступно',
                style: TextStyle(color: DS.textSecondary, fontSize: 13)),
            const SizedBox(height: 16),
            _PrimaryButton(
                label: 'Продлить',
                icon: Icons.refresh_rounded,
                accentColor: DS.rose,
                onTap: onRenew),
          ],
        ),
      );
    }

    // ── Active ────────────────────────────────────────────────────────────────
    final days = sub.expireDate?.difference(DateTime.now()).inDays;
    final badge = days == null
        ? 'АКТИВНА'
        : 'АКТИВНА · $days ${_dayLabel(days)}'.toUpperCase();
    final expDate = sub.expireDate;
    final expHint = expDate != null
        ? 'До ${expDate.day} ${_monthRu(expDate.month)} ${expDate.year}'
        : null;
    final planTitle =
        sub.planName != null ? 'Тариф «${sub.planName}»' : 'Активный тариф';

    return _CardShell(
      accentColor: DS.emerald,
      gradientStart: DS.emerald.withValues(alpha: 0.10),
      gradientEnd: DS.emerald.withValues(alpha: 0.03),
      borderColor: DS.emerald.withValues(alpha: 0.30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _PulsingDot(color: DS.emerald),
            const SizedBox(width: 6),
            Text(badge,
                style: const TextStyle(
                    color: DS.emerald,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8)),
          ]),
          const SizedBox(height: 10),
          Text(planTitle,
              style: const TextStyle(
                  color: DS.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w600)),
          if (expHint != null) ...[
            const SizedBox(height: 4),
            Text(expHint,
                style:
                    const TextStyle(color: DS.textSecondary, fontSize: 13)),
          ],
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
                child: _GhostButton(label: 'Продлить', onTap: onRenew)),
            const SizedBox(width: 8),
            Expanded(
                child: _GhostButton(
                    label: 'Сменить тариф', onTap: onChangePlan)),
          ]),
        ],
      ),
    );
  }
}

class _CardShell extends StatelessWidget {
  final Color accentColor;
  final Color gradientStart;
  final Color gradientEnd;
  final Color borderColor;
  final Widget child;

  const _CardShell({
    required this.accentColor,
    required this.gradientStart,
    required this.gradientEnd,
    required this.borderColor,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [gradientStart, gradientEnd],
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: borderColor, width: 0.5),
        ),
        child: child,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Traffic section card
// ─────────────────────────────────────────────────────────────────────────────

class _TrafficSectionCard extends StatelessWidget {
  final MeSubscription sub;
  final SubscriptionInfo? trafficInfo;

  const _TrafficSectionCard({required this.sub, required this.trafficInfo});

  static String _fmtGb(double gb) {
    if (gb <= 0) return '0 ГБ';
    if (gb >= 1.0) {
      final s = gb.toStringAsFixed(1);
      return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s} ГБ';
    }
    return '${(gb * 1024).round()} МБ';
  }

  @override
  Widget build(BuildContext context) {
    final unlimited = sub.trafficLimitGb == 0 &&
        (trafficInfo == null || trafficInfo!.totalBytes == 0);
    final usedBytes = trafficInfo?.usedBytes ??
        (sub.trafficUsedGb * 1024 * 1024 * 1024).round();
    final totalBytes = (trafficInfo != null && trafficInfo!.totalBytes > 0)
        ? trafficInfo!.totalBytes
        : (sub.trafficLimitGb == 0
            ? 0
            : (sub.trafficLimitGb * 1024 * 1024 * 1024));
    final fraction =
        totalBytes > 0 ? (usedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;
    final usedLabel = trafficInfo?.formattedUsed ?? _fmtGb(sub.trafficUsedGb);
    final totalLabel = unlimited
        ? '∞'
        : (trafficInfo != null && trafficInfo!.totalBytes > 0
            ? trafficInfo!.formattedTotal
            : '${sub.trafficLimitGb} ГБ');

    final Color barColor;
    if (unlimited) {
      barColor = DS.violet;
    } else if (fraction >= 0.9) {
      barColor = DS.rose;
    } else if (fraction >= 0.7) {
      barColor = DS.amber;
    } else {
      barColor = DS.emerald;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ТРАФИК В ЭТОМ ПЕРИОДЕ',
            style: TextStyle(
              color: DS.textMuted,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              unlimited
                  ? const Text('∞',
                      style: TextStyle(
                          color: DS.textPrimary,
                          fontSize: 22,
                          fontWeight: FontWeight.w600))
                  : RichText(
                      text: TextSpan(children: [
                        TextSpan(
                          text: usedLabel,
                          style: const TextStyle(
                              color: DS.textPrimary,
                              fontSize: 22,
                              fontWeight: FontWeight.w600),
                        ),
                        TextSpan(
                          text: ' / $totalLabel',
                          style: const TextStyle(
                              color: DS.textSecondary, fontSize: 14),
                        ),
                      ]),
                    ),
              Text(
                '${sub.deviceLimit} ${_devWord(sub.deviceLimit)}',
                style: const TextStyle(
                    color: DS.textSecondary, fontSize: 12),
              ),
            ],
          ),
          if (!unlimited) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: Stack(children: [
                Container(height: 4, color: DS.surface3),
                FractionallySizedBox(
                  widthFactor: fraction,
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: barColor,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ]),
            ),
          ] else ...[
            const SizedBox(height: 8),
            const Text('Трафик без ограничений',
                style: TextStyle(color: DS.textMuted, fontSize: 12)),
          ],
        ],
      ),
    );
  }

  static String _devWord(int n) {
    if (n % 10 == 1 && n % 100 != 11) return 'устройство';
    if (n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 10 || n % 100 >= 20)) {
      return 'устройства';
    }
    return 'устройств';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Balance row
// ─────────────────────────────────────────────────────────────────────────────

class _BalanceRow extends StatelessWidget {
  final MeResponse? me;
  final VoidCallback onTopup;

  const _BalanceRow({required this.me, required this.onTopup});

  @override
  Widget build(BuildContext context) {
    final balance = me?.balanceRub ?? 0.0;
    final currency = me?.balanceCurrency ?? 'RUB';
    final symbol = currency == 'RUB' ? '₽' : currency;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Остаток на счёте',
                  style:
                      TextStyle(color: DS.textMuted, fontSize: 11)),
              const SizedBox(height: 2),
              Text(
                '${balance.toStringAsFixed(0)} $symbol',
                style: const TextStyle(
                    color: DS.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
          GestureDetector(
            onTap: onTopup,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Пополнить',
                    style: TextStyle(
                        color: DS.violet,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                SizedBox(width: 2),
                Icon(Icons.chevron_right_rounded,
                    color: DS.violet, size: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Buttons
// ─────────────────────────────────────────────────────────────────────────────

class _PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final Color accentColor;

  const _PrimaryButton({
    required this.label,
    required this.onTap,
    this.icon,
    this.accentColor = DS.violet,
  });

  /// Слегка осветляем акцентный цвет для текста — лучше читается на тёмном фоне.
  Color get _textColor => Color.lerp(accentColor, Colors.white, 0.28)!;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: accentColor.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: accentColor.withValues(alpha: 0.38),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, color: _textColor, size: 17),
                const SizedBox(width: 7),
              ],
              Text(label,
                  style: TextStyle(
                      color: _textColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      );
}

class _GhostButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _GhostButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: DS.border),
          ),
          child: Center(
            child: Text(label,
                style: const TextStyle(
                    color: DS.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500)),
          ),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Logout button
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
            color: DS.surface1,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: DS.rose.withValues(alpha: 0.30)),
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.logout_rounded, color: DS.rose, size: 18),
              SizedBox(width: 8),
              Text('Выйти из аккаунта',
                  style: TextStyle(
                      color: DS.rose,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ],
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
          border: Border.all(color: DS.violet.withValues(alpha: 0.25)),
        ),
        child: Column(children: [
          Container(
            width: 82,
            height: 82,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [DS.violet, DS.violetDim],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: DS.violet.withValues(alpha: 0.40),
                  blurRadius: 28,
                  offset: const Offset(0, 8),
                )
              ],
            ),
            child: const Icon(Icons.person_rounded,
                color: Colors.white, size: 38),
          ),
          const SizedBox(height: 22),
          const Text('Войдите в аккаунт',
              style: TextStyle(
                  color: DS.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3),
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          const Text(
            'Управляйте подпиской, следите\nза трафиком и балансом',
            style: TextStyle(
                color: DS.textSecondary, fontSize: 14, height: 1.55),
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
            color: DS.surface1,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: DS.border),
          ),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: DS.gold.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Icon(Icons.workspace_premium_rounded,
                  color: DS.gold, size: 22),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Посмотреть тарифы',
                        style: TextStyle(
                            color: DS.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    SizedBox(height: 3),
                    Text('Быстрый и надёжный VPN',
                        style: TextStyle(
                            color: DS.textSecondary, fontSize: 12)),
                  ]),
            ),
            const Icon(Icons.arrow_forward_ios_rounded,
                color: DS.textMuted, size: 15),
          ]),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Pulsing dot — используется в статус-карточке
// ─────────────────────────────────────────────────────────────────────────────

class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

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
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                  color: widget.color.withValues(alpha: 0.6),
                  blurRadius: 6)
            ],
          ),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Top-up sheet — без изменений
// ─────────────────────────────────────────────────────────────────────────────

class _TopupSheet extends StatefulWidget {
  const _TopupSheet();

  @override
  State<_TopupSheet> createState() => _TopupSheetState();
}

class _TopupSheetState extends State<_TopupSheet> {
  static const _amounts = [100, 200, 300, 500, 1000, 2000];
  static const _minAmount = 50;
  static const _maxAmount = 100000;

  int? _selected = 300;
  bool _loading = false;

  final _customController = TextEditingController();
  final _focusNode = FocusNode();

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
      backgroundColor: isError ? DS.rose : DS.emerald,
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final amount = _resolvedAmount;
    final canSubmit =
        amount != null && amount >= _minAmount && amount <= _maxAmount;
    final buttonLabel =
        canSubmit ? 'Пополнить на $amount ₽' : 'Пополнить';

    return Container(
      margin:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      decoration: const BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: DS.border,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 20),
          const Text('Пополнить баланс',
              style: TextStyle(
                  color: DS.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('Выберите сумму или введите свою',
              style: TextStyle(color: DS.textSecondary, fontSize: 14)),
          const SizedBox(height: 20),
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
                        ? DS.violet.withValues(alpha: 0.18)
                        : DS.surface2,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: _selected == a
                            ? DS.violet.withValues(alpha: 0.6)
                            : DS.border,
                        width: _selected == a ? 1.5 : 1),
                  ),
                  child: Text('$a ₽',
                      style: TextStyle(
                          color: _selected == a
                              ? DS.violet
                              : DS.textSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                ),
              ),
          ]),
          const SizedBox(height: 16),
          TextField(
            controller: _customController,
            focusNode: _focusNode,
            keyboardType: TextInputType.number,
            style:
                const TextStyle(color: DS.textPrimary, fontSize: 15),
            decoration: InputDecoration(
              hintText: 'Другая сумма, ₽',
              prefixIcon: const Icon(Icons.edit_rounded,
                  color: DS.textMuted, size: 18),
              filled: true,
              fillColor: DS.surface2,
              hintStyle: const TextStyle(color: DS.textMuted),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 14),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DS.radiusSm),
                  borderSide: const BorderSide(color: DS.border)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DS.radiusSm),
                  borderSide: const BorderSide(color: DS.border)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DS.radiusSm),
                  borderSide:
                      const BorderSide(color: DS.violet, width: 1.5)),
            ),
          ),
          const SizedBox(height: 20),
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
                color: canSubmit ? null : DS.surface2,
                borderRadius: BorderRadius.circular(16),
                boxShadow: canSubmit
                    ? [
                        BoxShadow(
                            color: DS.violet.withValues(alpha: 0.35),
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
                                : DS.textMuted,
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

// ─────────────────────────────────────────────────────────────────────────────
// Devices card
// ─────────────────────────────────────────────────────────────────────────────

class _DevicesCard extends StatefulWidget {
  const _DevicesCard();

  @override
  State<_DevicesCard> createState() => _DevicesCardState();
}

class _DevicesCardState extends State<_DevicesCard> {
  DevicesResult? _result;
  bool _loading = true;
  bool _resetting = false;
  // HWID → true when that row is being deleted
  final Map<String, bool> _deletingMap = {};

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final r = await SubscriptionApiService.listDevices();
      if (mounted) setState(() => _result = r);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _onResetTap() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: DS.surface2,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DS.radius)),
        title: const Text(
          'Сбросить устройства?',
          style: TextStyle(
              color: DS.textPrimary, fontWeight: FontWeight.w700),
        ),
        content: const Text(
          'Все подключённые устройства будут отвязаны. После этого вам нужно будет заново подключить каждое устройство.',
          style: TextStyle(color: DS.textSecondary, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Сбросить',
                style: TextStyle(color: DS.rose)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _resetting = true);
    try {
      final ok = await SubscriptionApiService.resetDevices();
      if (!mounted) return;
      if (ok) {
        _showSnack('Все устройства сброшены', ok: true);
        await _loadDevices();
      } else {
        _showSnack('Не удалось сбросить устройства');
      }
    } catch (_) {
      if (mounted) _showSnack('Ошибка соединения с сервером');
    }
    if (mounted) setState(() => _resetting = false);
  }

  Future<void> _onDeleteDevice(String hwid) async {
    if (_deletingMap[hwid] == true) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: DS.surface2,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DS.radius)),
        title: const Text('Отключить устройство?',
            style: TextStyle(
                color: DS.textPrimary, fontWeight: FontWeight.w700)),
        content: const Text(
          'Устройство будет отвязано. Для повторного подключения нужно будет переподключить VPN на этом устройстве.',
          style: TextStyle(color: DS.textSecondary, height: 1.5),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Отключить',
                  style: TextStyle(color: DS.rose))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deletingMap[hwid] = true);
    try {
      final ok = await SubscriptionApiService.deleteDevice(hwid: hwid);
      if (!mounted) return;
      if (ok) {
        _showSnack('Устройство отключено', ok: true);
        await _loadDevices();
      } else {
        _showSnack('Не удалось отключить устройство');
      }
    } catch (_) {
      if (mounted) _showSnack('Ошибка соединения с сервером');
    }
    if (mounted) setState(() => _deletingMap.remove(hwid));
  }

  void _showSnack(String msg, {bool ok = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: ok ? DS.emerald : DS.rose,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DS.radiusSm)),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final count = result?.count ?? 0;
    final limit = result?.deviceLimit ?? 0;

    return Container(
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radius),
        border: Border.all(color: DS.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header row ───────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                      color: DS.violet.withValues(alpha: 0.12),
                      borderRadius:
                          BorderRadius.circular(DS.radiusSm)),
                  child:
                      const Icon(Icons.devices_rounded, color: DS.violet, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Подключённые устройства',
                          style: TextStyle(
                              color: DS.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w500)),
                      if (!_loading && result != null)
                        Text(
                          limit > 0
                              ? '$count из $limit устр.'
                              : '$count ${_devWord(count)}',
                          style: const TextStyle(
                              color: DS.textSecondary, fontSize: 12),
                        ),
                    ],
                  ),
                ),
                // Refresh button
                GestureDetector(
                  onTap: _loading ? null : _loadDevices,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: _loading && result == null
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: DS.violet))
                        : Icon(Icons.refresh_rounded,
                            size: 18,
                            color: _loading ? DS.textMuted : DS.textSecondary),
                  ),
                ),
              ],
            ),
          ),

          // ── Divider ──────────────────────────────────────────────────────
          const Divider(height: 1, indent: 16, endIndent: 16),

          // ── Body ─────────────────────────────────────────────────────────
          if (_loading && result == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                  child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: DS.violet))),
            )
          else if (result == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18, horizontal: 16),
              child: Text('Не удалось загрузить список устройств',
                  style: TextStyle(color: DS.textSecondary, fontSize: 13)),
            )
          else if (count == 0)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18, horizontal: 16),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 15, color: DS.textMuted),
                  SizedBox(width: 8),
                  Text('Нет подключённых устройств',
                      style: TextStyle(
                          color: DS.textSecondary, fontSize: 13)),
                ],
              ),
            )
          else ...[
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              itemCount: count,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (_, i) {
                final device = result.devices[i];
                final hwid = device.hwid;
                final client = device.clientName;
                final platform = device.platformName;
                final model = device.deviceModel;
                final isDeleting = _deletingMap[hwid] == true;

                // Main title: hardware model → OS platform → app name → fallback
                final title = (model?.isNotEmpty == true)
                    ? model!
                    : platform.isNotEmpty
                        ? platform
                        : client.isNotEmpty
                            ? client
                            : 'Устройство ${i + 1}';

                // Chips shown below title (don't repeat what's already the title)
                final showPlatform = platform.isNotEmpty && platform != title;
                final showClient  = client.isNotEmpty  && client  != title;

                return Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: DS.surface2,
                    borderRadius: BorderRadius.circular(DS.radiusSm),
                  ),
                  child: Row(
                    children: [
                      // ── Platform icon ───────────────────────────────────
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: DS.violet.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Icon(
                          _deviceIcon(device.rawName),
                          size: 18,
                          color: DS.violet.withValues(alpha: 0.75),
                        ),
                      ),
                      const SizedBox(width: 10),
                      // ── Text + chips ────────────────────────────────────
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: DS.textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500),
                            ),
                            if (showPlatform || showClient) ...[
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  if (showPlatform)
                                    _DeviceChip(
                                        label: platform, isClient: false),
                                  if (showPlatform && showClient)
                                    const SizedBox(width: 4),
                                  if (showClient)
                                    _DeviceChip(
                                        label: client, isClient: true),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      // ── Delete button ───────────────────────────────────
                      GestureDetector(
                        onTap: isDeleting
                            ? null
                            : () => _onDeleteDevice(hwid),
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(10, 4, 0, 4),
                          child: isDeleting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: DS.rose))
                              : Icon(Icons.link_off_rounded,
                                  size: 18,
                                  color: DS.rose.withValues(alpha: 0.70)),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],

          // ── Reset button ─────────────────────────────────────────────────
          if (count > 0) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            GestureDetector(
              onTap: (_resetting || _loading) ? null : _onResetTap,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_resetting)
                      const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: DS.rose))
                    else
                      const Icon(Icons.link_off_rounded,
                          size: 16, color: DS.rose),
                    const SizedBox(width: 7),
                    Text(
                      _resetting ? 'Сброс...' : 'Сбросить все устройства',
                      style: TextStyle(
                          color: _resetting ? DS.textMuted : DS.rose,
                          fontSize: 14,
                          fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ),
          ] else
            const SizedBox(height: 8),
        ],
      ),
    );
  }

  static IconData _deviceIcon(String? name) {
    if (name == null) return Icons.devices_rounded;
    final n = name.toLowerCase();
    if (n.contains('android') || n.contains('pixel') || n.contains('samsung')) {
      return Icons.phone_android_rounded;
    }
    if (n.contains('iphone') || n.contains('ios') || n.contains('ipad')) {
      return Icons.phone_iphone_rounded;
    }
    if (n.contains('mac') || n.contains('windows') || n.contains('linux')) {
      return Icons.computer_rounded;
    }
    return Icons.devices_rounded;
  }

  static String _devWord(int n) {
    final abs = n.abs() % 100;
    final last = abs % 10;
    if (abs >= 11 && abs <= 19) return 'устройств';
    if (last == 1) return 'устройство';
    if (last >= 2 && last <= 4) return 'устройства';
    return 'устройств';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Device chip — маленький чип-бейдж в строке устройства
// ─────────────────────────────────────────────────────────────────────────────

class _DeviceChip extends StatelessWidget {
  final String label;
  /// true = VPN-приложение (фиолетовый акцент), false = OS/платформа (нейтральный)
  final bool isClient;

  const _DeviceChip({required this.label, required this.isClient});

  @override
  Widget build(BuildContext context) {
    final bg = isClient
        ? DS.violet.withValues(alpha: 0.13)
        : DS.surface3;
    final fg = isClient
        ? DS.violet.withValues(alpha: 0.90)
        : DS.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Autopay card
// ─────────────────────────────────────────────────────────────────────────────

class _AutopayCard extends StatelessWidget {
  final bool enabled;
  final bool loading;
  final Future<void> Function(bool) onToggle;

  const _AutopayCard({
    required this.enabled,
    required this.loading,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radius),
        border: Border.all(color: DS.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 36,
            height: 36,
            decoration: BoxDecoration(
                color: (enabled ? DS.violet : DS.textMuted)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(DS.radiusSm)),
            child: Icon(Icons.autorenew_rounded,
                color: enabled ? DS.violet : DS.textMuted, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Автопродление',
                      style: TextStyle(
                          color: DS.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                  Text(
                    enabled
                        ? 'Подписка продлевается автоматически'
                        : 'Автопродление отключено',
                    style: const TextStyle(
                        color: DS.textSecondary, fontSize: 12),
                  ),
                ]),
          ),
          if (loading)
            const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: DS.violet))
          else
            Switch(
              value: enabled,
              onChanged: (v) => onToggle(v),
            ),
        ]),
      ),
    );
  }
}
