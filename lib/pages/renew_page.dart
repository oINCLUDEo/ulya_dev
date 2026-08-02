import 'dart:async';
import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../main.dart' show DS;
import '../models/me_response.dart';
import '../services/app_logger.dart';
import '../services/me_service.dart';
import '../services/subscription_api_service.dart';
import '../widgets/payment_polling_card.dart';
import 'payment_webview_page.dart';

// ── Дизайн-токены (синхронизированы с premium_page) ─────────────────────────
const _surf = Color(0xFF111124);   // поверхность карточки
const _b1   = Color(0xFF1E1E38);   // бордер карточки
const _t0   = Color(0xFFF0F0FF);   // заголовки
const _t1   = Color(0xFF8892AA);   // вторичный текст
const _t2   = Color(0xFF454565);   // приглушённый текст

// ── Тарифные иконки (синхронизированы с premium_page._tariffStyle) ───────────
(PhosphorIconData, Color) _resolveTariffStyle(String name) {
  final n = name.toLowerCase();
  if (n.contains('семей') || n.contains('family')) {
    return (PhosphorIconsFill.usersThree, const Color(0xFF7C6FF7));
  }
  if (n.contains('безлим') || n.contains('unlimit') || n.contains('инфинит')) {
    return (PhosphorIconsFill.rocketLaunch, DS.gold);
  }
  if (n.contains('популяр') || n.contains('popular') ||
      n.contains('стандарт') || n.contains('standard')) {
    return (PhosphorIconsFill.fire, const Color(0xFFFF6B3D));
  }
  if (n.contains('базов') || n.contains('basic') || n.contains('lite')) {
    return (PhosphorIconsFill.shieldCheck, const Color(0xFFC0C0D0));
  }
  if (n.contains('бизнес') || n.contains('business')) {
    return (PhosphorIconsFill.crown, DS.gold);
  }
  return (PhosphorIconsFill.shieldCheck, DS.violet);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  RenewPage — экран «Продлить текущий тариф»
//  Открывается push-навигацией с экрана аккаунта.
// ═══════════════════════════════════════════════════════════════════════════════

class RenewPage extends StatefulWidget {
  const RenewPage({super.key});

  @override
  State<RenewPage> createState() => _RenewPageState();
}

class _RenewPageState extends State<RenewPage> with WidgetsBindingObserver {
  // ── Data ────────────────────────────────────────────────────────────────────
  SubscriptionOptions? _options;
  bool _loading = true;

  // ── Resolved current tariff (may stay null → legacy flow) ──────────────────
  TariffInfo? _currentTariff;

  // ── Periods to display (unified: either from tariff or converted from legacy)
  List<TariffPeriod> _displayPeriods = [];

  // ── true when we couldn't resolve a TariffInfo and fall back to PeriodOption
  bool _useLegacyFlow = false;

  // ── Selection ───────────────────────────────────────────────────────────────
  TariffPeriod? _selectedPeriod;
  bool _useBalance = true;

  // ── Payment ─────────────────────────────────────────────────────────────────
  bool _purchasing = false;
  bool _pendingPaymentPoll = false;
  Timer? _pollTimer;
  int _pollAttempt = 0;
  bool _pollingForPayment = false;
  // Pre-checkout expiry snapshot — renewal is confirmed only when it advances.
  DateTime? _payBaselineExpiry;

  static const int _maxPollAttempts = 30;
  static const Duration _pollInterval = Duration(seconds: 4);

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadData();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _pendingPaymentPoll) {
      _pendingPaymentPoll = false;
      _startPaymentPolling();
    }
  }

  // ── Data loading ──────────────────────────────────────────────────────────────
  //  Стратегии поиска текущего тарифа (в порядке приоритета):
  //   1. Точное совпадение planName
  //   2. Частичное совпадение planName (contains)
  //   3. tariff_id из currentSubscription
  //   4. period_id из currentSubscription → ищем тариф, у которого есть такой период
  //   Fallback: используем periods из SubscriptionOptions (legacy API)

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final results = await Future.wait<dynamic>([
        SubscriptionApiService.getTariffs(),
        SubscriptionApiService.getOptions(),
      ]);
      final tariffs = results[0] as List<TariffInfo>?;
      final options = results[1] as SubscriptionOptions?;

      if (!mounted) return;

      final sub = meNotifier.value?.subscription;
      TariffInfo? found;

      if (tariffs != null && tariffs.isNotEmpty) {
        // 1. Exact name match
        if (sub?.planName != null) {
          final name = sub!.planName!.toLowerCase().trim();
          found = tariffs.cast<TariffInfo?>().firstWhere(
                (t) => t!.name.toLowerCase().trim() == name,
                orElse: () => null,
              );
        }

        // 2. Partial name match (один содержит другой)
        if (found == null && sub?.planName != null) {
          final name = sub!.planName!.toLowerCase().trim();
          found = tariffs.cast<TariffInfo?>().firstWhere(
                (t) {
                  final tn = t!.name.toLowerCase().trim();
                  return tn.contains(name) || name.contains(tn);
                },
                orElse: () => null,
              );
        }

        // 3. tariff_id из currentSubscription
        if (found == null && options?.currentSubscription != null) {
          final rawId = options!.currentSubscription!['tariff_id'];
          if (rawId != null) {
            final tid =
                rawId is int ? rawId : int.tryParse(rawId.toString());
            if (tid != null) {
              found = tariffs.cast<TariffInfo?>().firstWhere(
                    (t) => t!.id == tid,
                    orElse: () => null,
                  );
            }
          }
        }

        // 4. period_id из currentSubscription → тариф, содержащий этот период
        if (found == null && options?.currentSubscription != null) {
          final periodId =
              options!.currentSubscription!['period_id'] as String?;
          if (periodId != null) {
            found = tariffs.cast<TariffInfo?>().firstWhere(
                  (t) => t!.periods.any((p) => p.id == periodId),
                  orElse: () => null,
                );
          }
        }
      }

      // Составляем список периодов для отображения
      List<TariffPeriod> displayPeriods = [];
      bool useLegacy = false;

      if (found != null && found.periods.isNotEmpty) {
        displayPeriods = [...found.periods]
          ..sort((a, b) => a.months.compareTo(b.months));
      } else if (options != null && options.periods.isNotEmpty) {
        // Fallback: конвертируем legacy PeriodOption → TariffPeriod
        useLegacy = true;
        displayPeriods = options.periods
            .map(_convertLegacyPeriod)
            .toList()
          ..sort((a, b) => a.months.compareTo(b.months));
      }

      setState(() {
        _options = options;
        _currentTariff = found;
        _displayPeriods = displayPeriods;
        _useLegacyFlow = useLegacy;
        if (displayPeriods.isNotEmpty) {
          _selectedPeriod = displayPeriods.first;
        }
        _loading = false;
      });
    } catch (e) {
      debugPrint('RenewPage._loadData: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  // Конвертирует legacy PeriodOption в TariffPeriod для единообразного UI
  static TariffPeriod _convertLegacyPeriod(PeriodOption p) {
    final months = _parseMonths(p.label) ?? 1;
    return TariffPeriod(
      id: p.id,
      days: months * 30,
      months: months,
      label: p.label,
      priceKopeks: p.basePriceKopeks,
      discountPercent: p.discountPercent,
    );
  }

  static int? _parseMonths(String label) {
    final lower = label.toLowerCase();
    final mMonth = RegExp(r'(\d+)\s*мес').firstMatch(lower);
    if (mMonth != null) return int.tryParse(mMonth.group(1)!);
    final mYear = RegExp(r'(\d+)\s*(год|лет)').firstMatch(lower);
    if (mYear != null) {
      final y = int.tryParse(mYear.group(1)!);
      if (y != null) return y * 12;
    }
    return null;
  }

  // ── Computed ──────────────────────────────────────────────────────────────────

  double get _balanceRub => _options?.balanceRub ?? 0.0;

  double get _finalPrice {
    final period = _selectedPeriod;
    if (period == null) return 0;
    final total = period.priceKopeks / 100;
    if (_useBalance && _balanceRub > 0) return max(0.0, total - _balanceRub);
    return total;
  }

  // ── Payment polling ────────────────────────────────────────────────────────────

  void _startPaymentPolling() {
    if (!mounted) return;
    _pollTimer?.cancel();
    setState(() {
      _pollingForPayment = true;
      _pollAttempt = 0;
    });
    _pollTimer = Timer.periodic(_pollInterval, _onPollTick);
  }

  void _cancelPaymentPolling() {
    appLogger.info('Payment', 'renew poll: cancelled by user at attempt=$_pollAttempt');
    _pollTimer?.cancel();
    _pollTimer = null;
    if (mounted) setState(() => _pollingForPayment = false);
  }

  Future<void> _onPollTick(Timer timer) async {
    _pollAttempt++;
    await MeService.refresh();
    if (!mounted) {
      timer.cancel();
      return;
    }
    final sub = meNotifier.value?.subscription;
    final active = sub != null && sub.isActive && !sub.isTrial;
    // Renewal confirmed only when the expiry actually advanced past the
    // pre-checkout baseline (the user already has an active sub here, so
    // "active" alone is not proof of payment).
    final confirmed = active &&
        (_payBaselineExpiry == null ||
            sub.expireDate == null ||
            sub.expireDate!.isAfter(_payBaselineExpiry!));
    if (confirmed || _pollAttempt >= _maxPollAttempts) {
      timer.cancel();
      _pollTimer = null;
      appLogger.info('Payment',
          'renew poll: finished attempt=$_pollAttempt confirmed=$confirmed');
      if (!mounted) return;
      setState(() => _pollingForPayment = false);
      if (confirmed) {
        globalRefreshNotifier.value++;
        _snack('Подписка продлена!', ok: true);
        await Future.delayed(const Duration(milliseconds: 900));
        if (mounted) Navigator.of(context).pop();
      } else {
        appLogger.warning('Payment',
            'renew poll: gave up after $_maxPollAttempts attempts without confirmation');
        _snack('Платёж ещё не подтверждён. Проверьте статус позже.',
            ok: true);
      }
    }
  }

  Future<void> _openPaymentUrl(String url) async {
    if (!mounted) return;
    // Snapshot expiry so polling can tell a real renewal from a cancel.
    _payBaselineExpiry = meNotifier.value?.subscription?.expireDate;
    // Embedded in-app payment window (own top bar, no browser UI); poll the
    // backend for the result once it closes.
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PaymentWebViewPage(url: url),
      fullscreenDialog: true,
    ));
    if (!mounted) return;
    _snack('Проверяем оплату…', color: DS.violet);
    _startPaymentPolling();
  }

  // ── Actions ────────────────────────────────────────────────────────────────────

  Future<void> _onPayTapped() async {
    final period = _selectedPeriod;
    if (period == null) return;

    setState(() => _purchasing = true);
    try {
      BuyResult? r;

      if (_useLegacyFlow) {
        // Legacy: используем buySubscription с оригинальным PeriodOption
        final opts = _options;
        if (opts == null || opts.periods.isEmpty) {
          _snack('Ошибка данных');
          setState(() => _purchasing = false);
          return;
        }
        final legacyPeriod = opts.periods.firstWhere(
          (p) => p.id == period.id,
          orElse: () => opts.periods.first,
        );
        final params = _resolveLegacyParams(legacyPeriod);
        r = await SubscriptionApiService.buySubscription(
          periodId: legacyPeriod.id,
          trafficValue: params.traffic,
          devices: params.devices,
        );
      } else {
        final tariff = _currentTariff!;
        r = await SubscriptionApiService.buyTariff(
          tariffId: tariff.id,
          periodDays: period.days,
        );
      }

      if (!mounted) return;
      if (r == null) {
        _snack('Ошибка соединения с сервером');
      } else if (r.isSuccess) {
        await MeService.refresh();
        globalRefreshNotifier.value++;
        _snack('Подписка продлена!', ok: true);
        await Future.delayed(const Duration(milliseconds: 900));
        if (mounted) Navigator.of(context).pop();
      } else if (r.requiresPayment && r.paymentUrl != null) {
        await _openPaymentUrl(r.paymentUrl!);
      } else {
        _snack(r.message ?? 'Ошибка при продлении');
      }
    } catch (e) {
      appLogger.error('Payment', 'renew: exception: $e');
      if (mounted) _snack('Ошибка: $e');
    }
    if (mounted) setState(() => _purchasing = false);
  }

  /// Разрешает traffic и devices для legacy PeriodOption
  ({int? traffic, int? devices}) _resolveLegacyParams(PeriodOption p) {
    int? traffic;
    final tCfg = p.traffic;
    if (tCfg != null && tCfg.options.isNotEmpty) {
      final cur = meNotifier.value?.subscription?.trafficLimitGb;
      final ok = cur != null && tCfg.options.any((o) => o.value == cur);
      traffic = ok
          ? cur
          : tCfg.options
              .firstWhere((o) => o.isDefault,
                  orElse: () => tCfg.options.first)
              .value;
    }
    int? devices;
    final dCfg = p.devices;
    if (dCfg != null) {
      final cur = meNotifier.value?.subscription?.deviceLimit ?? 1;
      devices = dCfg.options.contains(cur)
          ? cur
          : (dCfg.defaultValue ?? dCfg.minimum);
    }
    return (traffic: traffic, devices: devices);
  }

  void _snack(String msg, {bool ok = false, Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w500)),
      backgroundColor: color ?? (ok ? DS.emerald : DS.rose),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DS.radiusSm)),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ));
  }

  // ── Build ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF07070D),
      body: Stack(
        children: [
          // Aurora gradient — единый фон с premium_page
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xFF0D0A22),
                    Color(0xFF07070F),
                    Color(0xFF07070D),
                  ],
                  stops: [0.0, 0.50, 1.0],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _Header(onBack: () => Navigator.of(context).pop()),
                Expanded(
                  child: _loading
                      ? const Center(
                          child: CircularProgressIndicator(
                              color: DS.violet, strokeWidth: 2.5))
                      : _buildBody(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final sub = meNotifier.value?.subscription;

    if (_pollingForPayment) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: PaymentPollingCard(onCancel: _cancelPaymentPolling),
        ),
      );
    }

    // Показываем ошибку только если нет ни периодов тарифа, ни legacy-периодов
    if (_displayPeriods.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: _t2, size: 48),
              const SizedBox(height: 16),
              const Text(
                'Не удалось загрузить периоды.\nПопробуйте ещё раз.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _t1, fontSize: 15),
              ),
              const SizedBox(height: 20),
              _PrimaryButton(
                  label: 'Повторить',
                  onPressed: _loadData,
                  loading: false),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        // Карточка текущего тарифа — показываем всегда, даже если тариф не найден
        _CurrentTariffCard(tariff: _currentTariff, sub: sub),
        const SizedBox(height: 20),

        // Список периодов
        ..._displayPeriods.map((p) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _PeriodCard(
                period: p,
                isSelected: _selectedPeriod?.id == p.id,
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _selectedPeriod = p);
                },
              ),
            )),

        const SizedBox(height: 4),

        if (_balanceRub > 0) ...[
          _BalanceToggle(
            balanceRub: _balanceRub,
            enabled: _useBalance,
            onToggle: (v) {
              HapticFeedback.selectionClick();
              setState(() => _useBalance = v);
            },
          ),
          const SizedBox(height: 16),
        ] else
          const SizedBox(height: 12),

        _PrimaryButton(
          label: 'Оплатить ${_finalPrice.round()} ₽',
          onPressed: (_selectedPeriod != null && !_pollingForPayment)
              ? _onPayTapped
              : null,
          loading: _purchasing || _pollingForPayment,
        ),
        const SizedBox(height: 10),
        const _SecureCaption(),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _Header
// ─────────────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final VoidCallback onBack;
  const _Header({required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 16, 0),
      child: Row(
        children: [
          GestureDetector(
            onTap: onBack,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _surf,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _b1),
              ),
              child: const Center(
                child: Icon(Icons.arrow_back_ios_new_rounded,
                    color: _t1, size: 16),
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Text(
            'Продлить',
            style: TextStyle(
                color: _t0,
                fontSize: 20,
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _CurrentTariffCard
// ─────────────────────────────────────────────────────────────────────────────

class _CurrentTariffCard extends StatelessWidget {
  final TariffInfo? tariff;
  final MeSubscription? sub;

  const _CurrentTariffCard({this.tariff, this.sub});

  @override
  Widget build(BuildContext context) {
    final name = tariff?.name ?? sub?.planName ?? 'Текущий тариф';
    final trafficGb = tariff?.trafficLimitGb ?? sub?.trafficLimitGb ?? 0;
    final devices = tariff?.deviceLimit ?? sub?.deviceLimit ?? 1;

    final trafficLabel = trafficGb == 0 ? 'Без лимита' : '$trafficGb ГБ';
    final trafficIcon = trafficGb == 0
        ? Icons.all_inclusive_rounded
        : Icons.signal_cellular_alt_rounded;

    final (iconData, accent) = _resolveTariffStyle(name);

    // Строка срока — «до 23 мар · 45 дней» или «Истекла 10 янв»
    String? expiryLine;
    Color expiryColor = DS.emerald;
    if (sub?.expireDate != null) {
      final d = sub!.expireDate!;
      final dateStr = '${d.day} ${_monthShort(d.month)}';
      if (sub!.isExpired) {
        expiryLine = 'Истекла $dateStr';
        expiryColor = DS.rose;
      } else {
        final days = d.difference(DateTime.now()).inDays;
        expiryLine = 'до $dateStr · $days ${_pluralDays(days)}';
        expiryColor = days <= 7 ? DS.amber : DS.emerald;
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: _surf,
        border: Border.all(color: _b1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(child: PhosphorIcon(iconData, color: accent, size: 22)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: _t0,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _RenewInfoChip(icon: trafficIcon, label: trafficLabel),
                    const SizedBox(width: 6),
                    _RenewInfoChip(
                        icon: Icons.devices_rounded,
                        label: '$devices устр.'),
                  ],
                ),
                if (expiryLine != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.calendar_today_rounded,
                          size: 11,
                          color: expiryColor.withValues(alpha: 0.75)),
                      const SizedBox(width: 4),
                      Text(expiryLine,
                          style: TextStyle(
                              color: expiryColor,
                              fontSize: 11,
                              fontWeight: FontWeight.w500)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _monthShort(int m) {
    const months = [
      'янв', 'фев', 'мар', 'апр', 'мая', 'июн',
      'июл', 'авг', 'сен', 'окт', 'ноя', 'дек',
    ];
    return months[(m - 1).clamp(0, 11)];
  }

  static String _pluralDays(int n) {
    final abs = n.abs() % 100;
    final last = abs % 10;
    if (abs >= 11 && abs <= 19) return 'дней';
    if (last == 1) return 'день';
    if (last >= 2 && last <= 4) return 'дня';
    return 'дней';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _RenewInfoChip — мини-чип с иконкой (трафик / устройства)
// ─────────────────────────────────────────────────────────────────────────────

class _RenewInfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _RenewInfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 13, color: _t1),
      const SizedBox(width: 4),
      Text(label,
          style: const TextStyle(
              color: _t1,
              fontSize: 11,
              fontWeight: FontWeight.w500)),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
//  _PeriodCard
// ─────────────────────────────────────────────────────────────────────────────

class _PeriodCard extends StatelessWidget {
  final TariffPeriod period;
  final bool isSelected;
  final VoidCallback onTap;

  const _PeriodCard({
    required this.period,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final totalRub = (period.priceKopeks / 100).round();
    final perMonthRub = period.months > 1
        ? (period.priceKopeks / 100 / period.months).round()
        : null;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.symmetric(
            horizontal: 16, vertical: isSelected ? 13.5 : 14),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0x1A7C6BFF) : _surf,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? DS.violet : _b1,
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          children: [
            _RadioDot(selected: isSelected),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        _monthsLabel(period.months),
                        style: const TextStyle(
                            color: _t0,
                            fontSize: 15,
                            fontWeight: FontWeight.w600),
                      ),
                      if (period.discountPercent > 0) ...[
                        const SizedBox(width: 8),
                        _DiscountBadge(percent: period.discountPercent),
                      ],
                    ],
                  ),
                  if (perMonthRub != null)
                    Text('$perMonthRub ₽/мес',
                        style: const TextStyle(
                            color: _t1, fontSize: 12)),
                ],
              ),
            ),
            Text('$totalRub ₽',
                style: const TextStyle(
                    color: _t0,
                    fontSize: 17,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  String _monthsLabel(int m) {
    if (m == 1) return '1 месяц';
    if (m % 100 != 11 && m % 10 == 1) return '$m месяц';
    if (m % 10 >= 2 && m % 10 <= 4 && (m % 100 < 10 || m % 100 >= 20)) {
      return '$m месяца';
    }
    return '$m месяцев';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _RadioDot
// ─────────────────────────────────────────────────────────────────────────────

class _RadioDot extends StatelessWidget {
  final bool selected;
  const _RadioDot({required this.selected});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? DS.violet : Colors.transparent,
        border: selected
            ? null
            : Border.all(color: _b1, width: 1.5),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, color: Colors.white, size: 13)
          : null,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _DiscountBadge
// ─────────────────────────────────────────────────────────────────────────────

class _DiscountBadge extends StatelessWidget {
  final int percent;
  const _DiscountBadge({required this.percent});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0x2E1DC97A),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text('−$percent%',
          style: const TextStyle(
              color: DS.emerald,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _BalanceToggle
// ─────────────────────────────────────────────────────────────────────────────

class _BalanceToggle extends StatelessWidget {
  final double balanceRub;
  final bool enabled;
  final ValueChanged<bool> onToggle;

  const _BalanceToggle({
    required this.balanceRub,
    required this.enabled,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final balanceStr = balanceRub == balanceRub.roundToDouble()
        ? '${balanceRub.round()} ₽'
        : '${balanceRub.toStringAsFixed(2)} ₽';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _surf,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _b1),
      ),
      child: Row(
        children: [
          const Icon(Icons.account_balance_wallet_outlined,
              color: DS.emerald, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(color: _t0, fontSize: 13),
                children: [
                  const TextSpan(text: 'Списать с баланса '),
                  TextSpan(
                      text: '($balanceStr)',
                      style: const TextStyle(color: _t1)),
                ],
              ),
            ),
          ),
          GestureDetector(
            onTap: () => onToggle(!enabled),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 40,
              height: 24,
              decoration: BoxDecoration(
                color: enabled ? DS.violet : const Color(0xFF2A2A38),
                borderRadius: BorderRadius.circular(999),
              ),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 200),
                alignment:
                    enabled ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.all(2),
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color:
                        enabled ? Colors.white : const Color(0xFF6B6B7D),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _PrimaryButton
// ─────────────────────────────────────────────────────────────────────────────

class _PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  const _PrimaryButton({
    required this.label,
    required this.onPressed,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: loading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: DS.violet,
          disabledBackgroundColor: const Color(0xFF2A2A38),
          foregroundColor: Colors.white,
          disabledForegroundColor: const Color(0xFF6B6B7D),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DS.radius)),
          elevation: 0,
        ),
        child: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 2.5))
            : Text(label,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _SecureCaption
// ─────────────────────────────────────────────────────────────────────────────

class _SecureCaption extends StatelessWidget {
  const _SecureCaption();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.lock_outline_rounded, size: 12, color: _t2),
        SizedBox(width: 4),
        Text('Безопасная оплата · YooKassa',
            style: TextStyle(color: _t2, fontSize: 11)),
      ],
    );
  }
}
