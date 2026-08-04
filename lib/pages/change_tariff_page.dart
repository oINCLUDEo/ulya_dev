import 'dart:async';
import 'dart:math' show max, min;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../main.dart' show DS;
import '../models/me_response.dart';
import '../services/app_logger.dart';
import '../services/me_service.dart';
import '../services/subscription_api_service.dart';
import '../widgets/accent_surface.dart';
import '../widgets/payment_polling_card.dart';
import 'payment_webview_page.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Тарифные иконки — выбираются по ключевым словам в названии тарифа
// ─────────────────────────────────────────────────────────────────────────────

/// Возвращает (иконка Phosphor, акцент-цвет) для тарифа по имени.
/// Синхронизировано с premium_page._TariffRadioCardState._tariffStyle()
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

/// Краткое описание тарифа по его параметрам + ключевым словам.
String _tariffSubtitle(String name, int trafficGb, int deviceLimit) {
  final trafficPart =
      trafficGb == 0 ? 'Безлимитный трафик' : '$trafficGb ГБ трафика';
  final devWord = _pluralDevicesShort(deviceLimit);
  return '$trafficPart · $deviceLimit $devWord';
}

String _pluralDevicesShort(int n) {
  final abs = n.abs() % 100;
  final last = abs % 10;
  if (abs >= 11 && abs <= 19) return 'устр.';
  if (last == 1) return 'устройство';
  if (last >= 2 && last <= 4) return 'устройства';
  return 'устройств';
}

// ═══════════════════════════════════════════════════════════════════════════════
//  ChangeTariffPage — экран «Сменить тариф»
//  Два шага в одном виджете: выбор тарифа → чекаут.
//  Открывается push-навигацией с экрана аккаунта.
// ═══════════════════════════════════════════════════════════════════════════════

class ChangeTariffPage extends StatefulWidget {
  const ChangeTariffPage({super.key});

  @override
  State<ChangeTariffPage> createState() => _ChangeTariffPageState();
}

class _ChangeTariffPageState extends State<ChangeTariffPage>
    with WidgetsBindingObserver {
  // ── Data ────────────────────────────────────────────────────────────────────
  List<TariffInfo> _otherTariffs = [];
  SubscriptionOptions? _options;
  TariffInfo? _currentTariff;
  bool _loading = true;

  // ── Step 1 ───────────────────────────────────────────────────────────────────
  TariffInfo? _selectedTariff;
  int _familyDevices = _kFamilyBaseDevices;

  // ── Step 2 ───────────────────────────────────────────────────────────────────
  bool _checkoutMode = false;
  TariffPeriod? _selectedPeriod;

  // ── Step 2 (existing active/trial plan — real proration preview) ────────────
  TariffSwitchPreview? _switchPreview;
  bool _switchPreviewLoading = false;

  // ── Payment ─────────────────────────────────────────────────────────────────
  bool _purchasing = false;
  bool _pendingPaymentPoll = false;
  Timer? _pollTimer;
  int _pollAttempt = 0;
  bool _pollingForPayment = false;
  // Pre-checkout snapshot so polling distinguishes a real switch from a cancel
  // (the user is always an active subscriber here, so "has active sub" alone
  // can't signal success).
  String?   _payBaselinePlan;
  DateTime? _payBaselineExpiry;

  static const int _maxPollAttempts = 30;
  static const Duration _pollInterval = Duration(seconds: 4);

  // ── Constants ────────────────────────────────────────────────────────────────
  static const int _kFamilyBaseDevices = 5;
  static const int _kFamilyMaxDevices = 8;

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

  // ── Data ─────────────────────────────────────────────────────────────────────

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final results = await Future.wait<dynamic>([
        SubscriptionApiService.getTariffs(),
        SubscriptionApiService.getOptions(),
      ]);
      final rawTariffs = results[0] as List<TariffInfo>?;
      final options = results[1] as SubscriptionOptions?;

      if (!mounted) return;

      final sub = meNotifier.value?.subscription;
      TariffInfo? currentTariff;

      final sorted = rawTariffs != null
          ? ([...rawTariffs]
              ..sort((a, b) {
                final ap = a.cheapestPeriod?.priceKopeks ?? 0;
                final bp = b.cheapestPeriod?.priceKopeks ?? 0;
                return ap.compareTo(bp);
              }))
          : <TariffInfo>[];

      if (sub?.planName != null) {
        final name = sub!.planName!.toLowerCase().trim();
        currentTariff = sorted.cast<TariffInfo?>().firstWhere(
          (t) => t!.name.toLowerCase().trim() == name,
          orElse: () => null,
        );
      }

      final others =
          sorted.where((t) => t.id != currentTariff?.id).toList();

      // Auto-select the first available "other" tariff
      TariffInfo? autoSelected;
      TariffPeriod? autoSelectedPeriod;
      if (others.isNotEmpty) {
        autoSelected = others.first;
        autoSelectedPeriod = _cheapestPeriod(autoSelected);
      }

      setState(() {
        _currentTariff = currentTariff;
        _otherTariffs = others;
        _options = options;
        _selectedTariff ??= autoSelected;
        _selectedPeriod ??= autoSelectedPeriod;
        _loading = false;
      });
    } catch (e) {
      debugPrint('ChangeTariffPage._loadData: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  /// True when the user has an active/trial plan. Only then does the real
  /// backend switch endpoint apply (it keeps the existing end_date and
  /// prorates the difference — there's no period to pick). Expired or
  /// plan-less users go through the regular buy-tariff flow instead.
  bool get _hasExistingPlan {
    final sub = meNotifier.value?.subscription;
    return sub != null &&
        sub.planName != null &&
        sub.planName!.isNotEmpty &&
        (sub.isActive || sub.isTrial);
  }

  TariffPeriod? _cheapestPeriod(TariffInfo t) {
    if (t.periods.isEmpty) return null;
    final sorted = [...t.periods]..sort((a, b) => a.months.compareTo(b.months));
    return sorted.first;
  }

  List<TariffPeriod> _sortedPeriods(TariffInfo t) {
    return [...t.periods]..sort((a, b) => a.months.compareTo(b.months));
  }

  // ── Computed ─────────────────────────────────────────────────────────────────

  double get _balanceRub => _options?.balanceRub ?? 0.0;

  bool _isFamilyTariff(TariffInfo t) {
    final n = t.name.toLowerCase();
    return n.contains('семей') || n.contains('family');
  }

  bool _isPopularTariff(TariffInfo t) {
    final n = t.name.toLowerCase();
    return n.contains('популяр') || n.contains('popular');
  }

  // Base monthly price from the cheapest (1-month) period
  double _basePricePerMonth(TariffInfo t) {
    final c = t.cheapestPeriod;
    if (c == null || c.months == 0) return 0;
    return c.priceKopeks / 100 / c.months;
  }

  // Extra devices surcharge per month — uses real device_price_kopeks from tariff.
  double _extraPerMonth(TariffInfo t) {
    if (!_isFamilyTariff(t)) return 0;
    final extra = _familyDevices - _kFamilyBaseDevices;
    if (extra <= 0) return 0;
    final pricePerDevice = (t.devicePriceKopeks ?? 0) / 100.0;
    return extra * pricePerDevice;
  }

  // Displayed price per month in the tariff card header
  double _displayPricePerMonth(TariffInfo t) =>
      _basePricePerMonth(t) + _extraPerMonth(t);

  // Period discount factor relative to base monthly price
  double _discountFactor(TariffInfo t, TariffPeriod p) {
    final cheapest = t.cheapestPeriod;
    if (cheapest == null || cheapest.months == 0) return 1.0;
    final baseKopeksPerMonth = cheapest.priceKopeks / cheapest.months;
    if (baseKopeksPerMonth == 0) return 1.0;
    return (p.priceKopeks / (baseKopeksPerMonth * p.months)).clamp(0.0, 1.0);
  }

  // Total price for a period, including extra-device surcharge and discount
  double _periodTotal(TariffInfo t, TariffPeriod p) {
    final extra = _extraPerMonth(t);
    if (extra == 0) {
      // No extra devices → use the authoritative API price
      return p.priceKopeks / 100;
    }
    // Extra devices: apply same discount factor as the base price
    final factor = _discountFactor(t, p);
    final totalPerMonth = _basePricePerMonth(t) + extra;
    return totalPerMonth * p.months * factor;
  }


  // ── Payment ──────────────────────────────────────────────────────────────────

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
    appLogger.info('Payment', 'change-tariff poll: cancelled by user at attempt=$_pollAttempt');
    _pollTimer?.cancel();
    _pollTimer = null;
    if (mounted) setState(() => _pollingForPayment = false);
  }

  Future<void> _onPollTick(Timer timer) async {
    _pollAttempt++;
    await MeService.refreshAll();
    if (!mounted) {
      timer.cancel();
      return;
    }
    final sub = meNotifier.value?.subscription;
    final active = sub != null && sub.isActive && !sub.isTrial;
    // A switch is confirmed when the plan name changes or the expiry advances
    // past the pre-checkout snapshot — not merely because a sub is active.
    final confirmed = active &&
        ((sub.planName != null && sub.planName != _payBaselinePlan) ||
            (sub.expireDate != null &&
                _payBaselineExpiry != null &&
                sub.expireDate!.isAfter(_payBaselineExpiry!)));
    if (confirmed || _pollAttempt >= _maxPollAttempts) {
      timer.cancel();
      _pollTimer = null;
      appLogger.info('Payment',
          'change-tariff poll: finished attempt=$_pollAttempt confirmed=$confirmed');
      if (!mounted) return;
      setState(() => _pollingForPayment = false);
      if (confirmed) {
        _snack('Тариф успешно изменён!', ok: true);
        await Future.delayed(const Duration(milliseconds: 900));
        if (mounted) Navigator.of(context).pop();
      } else {
        appLogger.warning('Payment',
            'change-tariff poll: gave up after $_maxPollAttempts attempts without confirmation');
        _snack('Платёж ещё не подтверждён. Проверьте статус позже.',
            ok: true);
      }
    }
  }

  Future<void> _openPaymentUrl(String url) async {
    try {
      if (!mounted) return;
      // Snapshot current plan/expiry so polling can tell a real switch from a
      // cancelled checkout.
      final curSub = meNotifier.value?.subscription;
      _payBaselinePlan = curSub?.planName;
      _payBaselineExpiry = curSub?.expireDate;
      // Embedded in-app payment window (own top bar, no browser UI); poll the
      // backend for the result once it closes.
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PaymentWebViewPage(url: url),
        fullscreenDialog: true,
      ));
      if (mounted) {
        _snack('Проверяем оплату…', color: DS.violet);
        _startPaymentPolling();
      }
    } catch (_) {
      if (mounted) _snack('Ошибка при открытии оплаты');
    }
  }

  // ── Actions ──────────────────────────────────────────────────────────────────

  void _selectTariff(TariffInfo t) {
    HapticFeedback.selectionClick();
    setState(() {
      _selectedTariff = t;
      _familyDevices = _kFamilyBaseDevices;
      _selectedPeriod = _cheapestPeriod(t);
    });
  }

  void _familyDecrement() {
    if (_familyDevices > _kFamilyBaseDevices) {
      HapticFeedback.selectionClick();
      setState(() => _familyDevices--);
      if (_checkoutMode && _hasExistingPlan) _loadSwitchPreview();
    } else {
      HapticFeedback.heavyImpact();
    }
  }

  void _familyIncrement() {
    if (_familyDevices < _kFamilyMaxDevices) {
      HapticFeedback.selectionClick();
      setState(() => _familyDevices++);
      if (_checkoutMode && _hasExistingPlan) _loadSwitchPreview();
    } else {
      HapticFeedback.heavyImpact();
    }
  }

  /// Fetches the real prorated switch cost for the selected tariff (and, for
  /// the Family tariff, the currently chosen device count) via the working
  /// /tariff/switch/preview endpoint. Only meaningful when [_hasExistingPlan].
  Future<void> _loadSwitchPreview() async {
    final t = _selectedTariff;
    if (t == null) return;
    if (!mounted) return;
    setState(() {
      _switchPreviewLoading = true;
      _switchPreview = null;
    });
    final devices = _isFamilyTariff(t) ? _familyDevices : null;
    final r = await SubscriptionApiService.previewTariffSwitch(
      tariffId: t.id,
      devices: devices,
    );
    if (!mounted) return;
    setState(() {
      _switchPreview = r;
      _switchPreviewLoading = false;
    });
  }

  Future<void> _onPayTapped() async {
    final t = _selectedTariff;
    if (t == null) return;

    if (_hasExistingPlan) {
      setState(() => _purchasing = true);
      try {
        final devices = _isFamilyTariff(t) ? _familyDevices : null;
        final r = await SubscriptionApiService.switchTariff(
          tariffId: t.id,
          devices: devices,
        );
        if (!mounted) return;
        if (r == null) {
          _snack('Ошибка соединения с сервером');
        } else if (r.isSuccess) {
          await MeService.refreshAll();
          _snack('Тариф успешно изменён!', ok: true);
          await Future.delayed(const Duration(milliseconds: 900));
          if (mounted) Navigator.of(context).pop();
        } else if (r.requiresPayment && r.paymentUrl != null) {
          await _openPaymentUrl(r.paymentUrl!);
        } else {
          _snack(r.message ?? 'Ошибка при смене тарифа');
        }
      } catch (e) {
        appLogger.error('Payment', 'switch tariff: exception: $e');
        if (mounted) _snack('Ошибка: $e');
      }
      if (mounted) setState(() => _purchasing = false);
      return;
    }

    final p = _selectedPeriod;
    if (p == null) {
      _snack('Выберите период');
      return;
    }

    setState(() => _purchasing = true);
    try {
      final r = await SubscriptionApiService.buyTariff(
        tariffId: t.id,
        periodDays: p.days,
      );

      if (!mounted) return;
      if (r == null) {
        _snack('Ошибка соединения с сервером');
      } else if (r.isSuccess) {
        await MeService.refreshAll();
        _snack('Тариф успешно оформлен!', ok: true);
        await Future.delayed(const Duration(milliseconds: 900));
        if (mounted) Navigator.of(context).pop();
      } else if (r.requiresPayment && r.paymentUrl != null) {
        await _openPaymentUrl(r.paymentUrl!);
      } else {
        _snack(r.message ?? 'Ошибка при оформлении тарифа');
      }
    } catch (e) {
      appLogger.error('Payment', 'change tariff: exception: $e');
      if (mounted) _snack('Ошибка: $e');
    }
    if (mounted) setState(() => _purchasing = false);
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

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_checkoutMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _checkoutMode) {
          setState(() => _checkoutMode = false);
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF07070D),
        body: Stack(
          children: [
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
                  _buildHeader(),
                  Expanded(
                    child: _loading
                        ? const Center(
                            child: CircularProgressIndicator(
                                color: DS.violet, strokeWidth: 2.5))
                        : AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: _checkoutMode
                                ? _buildCheckout()
                                : _buildStep1(),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Header ───────────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 16, 0),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              if (_checkoutMode) {
                setState(() => _checkoutMode = false);
              } else {
                Navigator.of(context).pop();
              }
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: DS.surface1,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: DS.border),
              ),
              child: const Center(
                child: Icon(Icons.arrow_back_ios_new_rounded,
                    color: DS.textSecondary, size: 16),
              ),
            ),
          ),
          const SizedBox(width: 12),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: Text(
              _checkoutMode ? 'Оформление' : 'Сменить тариф',
              key: ValueKey(_checkoutMode),
              style: const TextStyle(
                  color: DS.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  ШАГ 1 — Выбор тарифа
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildStep1() {
    final sub = meNotifier.value?.subscription;

    if (_currentTariff == null && _otherTariffs.isEmpty) {
      return _ErrorRetry(onRetry: _loadData);
    }

    return Column(
      key: const ValueKey('step1'),
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            children: [
              // ── Текущий тариф ──
              if (_currentTariff != null || sub != null) ...[
                const _SectionLabel(text: 'У вас сейчас'),
                const SizedBox(height: 8),
                _CurrentTariffCard(
                  name: _currentTariff?.name ?? sub?.planName ?? 'Текущий тариф',
                  trafficGb:
                      _currentTariff?.trafficLimitGb ?? sub?.trafficLimitGb ?? 0,
                  devices:
                      _currentTariff?.deviceLimit ?? sub?.deviceLimit ?? 1,
                  pricePerMonth: _currentTariff != null
                      ? _basePricePerMonth(_currentTariff!)
                      : null,
                  sub: sub,
                ),
                const SizedBox(height: 20),
              ],

              // ── Другие тарифы ──
              const _SectionLabel(text: 'Другие тарифы'),
              const SizedBox(height: 8),
              ..._otherTariffs.map((t) {
                final isSelected = _selectedTariff?.id == t.id;
                final isFamily = _isFamilyTariff(t);
                final isPopular = _isPopularTariff(t);
                // Stepper shown for Family tariff (both new purchase and switch).
                final showStepper = isFamily;
                return Padding(
                  // Верхний отступ для плашки «Популярный» (badge = 20px, top: -10)
                  padding: EdgeInsets.only(
                      top: isPopular ? 16 : 0, bottom: 10),
                  child: _TariffSelectCard(
                    tariff: t,
                    isSelected: isSelected,
                    isPopular: isPopular,
                    isFamily: showStepper,
                    familyDevices: showStepper ? _familyDevices : null,
                    displayPricePerMonth: _displayPricePerMonth(t),
                    onTap: () => _selectTariff(t),
                    onFamilyDecrement: _familyDecrement,
                    onFamilyIncrement: _familyIncrement,
                  ),
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        ),

        // ── Кнопка перехода ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            children: [
              _CTAButton(
                label: _selectedTariff != null
                    ? 'Перейти на «${_selectedTariff!.name}»'
                    : 'Выберите тариф',
                onPressed: _selectedTariff != null
                    ? () {
                        HapticFeedback.mediumImpact();
                        setState(() => _checkoutMode = true);
                        if (_hasExistingPlan) _loadSwitchPreview();
                      }
                    : null,
                loading: false,
              ),
              const SizedBox(height: 10),
              Text(
                _hasExistingPlan
                    ? 'Стоимость рассчитывается автоматически'
                    : 'Выбор периода — на следующем шаге',
                style: const TextStyle(color: DS.textFaint, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  ШАГ 2 — Чекаут
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildCheckout() {
    final t = _selectedTariff;
    if (t == null) return const SizedBox.shrink();

    if (_pollingForPayment) {
      return Center(
        key: const ValueKey('step2-polling'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: PaymentPollingCard(onCancel: _cancelPaymentPolling),
        ),
      );
    }

    return _hasExistingPlan ? _buildCheckoutSwitch(t) : _buildCheckoutBuy(t);
  }

  /// Checkout for switching an existing active/trial plan: no period picker —
  /// the real /tariff/switch endpoint keeps the current end_date and charges
  /// only the prorated difference for the remaining days.
  Widget _buildCheckoutSwitch(TariffInfo t) {
    final isFamily = _isFamilyTariff(t);
    final preview = _switchPreview;
    final loading = _switchPreviewLoading;

    return ListView(
      key: const ValueKey('step2-switch'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        const _SectionLabel(text: 'Тариф'),
        const SizedBox(height: 8),
        _CheckoutTariffCard(
          tariff: t,
          deviceCount: isFamily ? _familyDevices : t.deviceLimit,
          onEdit: () => setState(() => _checkoutMode = false),
        ),
        const SizedBox(height: 14),

        if (isFamily) ...[
          const _SectionLabel(text: 'Устройства'),
          const SizedBox(height: 8),
          _FamilyStepper(
            count: _familyDevices,
            max: _kFamilyMaxDevices,
            base: _kFamilyBaseDevices,
            onDecrement: _familyDecrement,
            onIncrement: _familyIncrement,
          ),
          const SizedBox(height: 14),
        ],

        const _SectionLabel(text: 'Расчёт'),
        const SizedBox(height: 8),
        if (loading || preview == null)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 24),
            decoration: BoxDecoration(
              color: DS.surface1,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Center(
              child: SizedBox(
                width: 22, height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: DS.violet),
              ),
            ),
          )
        else
          _SwitchBreakdownCard(preview: preview),
        const SizedBox(height: 16),

        _CTAButton(
          label: preview == null
              ? 'Оплатить'
              : preview.isFree
                  ? 'Сменить тариф'
                  : 'Оплатить ${(preview.upgradeCostKopeks / 100).round()} ₽',
          onPressed: (preview != null && !loading && !_pollingForPayment)
              ? _onPayTapped
              : null,
          loading: _purchasing || loading || _pollingForPayment,
        ),
        const SizedBox(height: 10),
        const _SecureCaption(),
      ],
    );
  }

  Widget _buildCheckoutBuy(TariffInfo t) {
    final periods = _sortedPeriods(t);
    final p = _selectedPeriod ?? (periods.isNotEmpty ? periods.first : null);

    final isFamily = _isFamilyTariff(t);
    final baseDevices = isFamily ? _kFamilyBaseDevices : t.deviceLimit;
    final extraDevices =
        isFamily ? (_familyDevices - _kFamilyBaseDevices) : 0;
    final basePerMonth = _basePricePerMonth(t);
    final extraPerMonth = extraDevices * ((t.devicePriceKopeks ?? 0) / 100.0);
    final periodTotal = p != null ? _periodTotal(t, p) : 0.0;
    final balance = _balanceRub;
    final finalPrice =
        balance > 0 ? max(0.0, periodTotal - balance) : periodTotal;

    return ListView(
      key: const ValueKey('step2'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        // ── Тариф ──
        const _SectionLabel(text: 'Тариф'),
        const SizedBox(height: 8),
        _CheckoutTariffCard(
          tariff: t,
          deviceCount: isFamily ? _familyDevices : t.deviceLimit,
          onEdit: () => setState(() => _checkoutMode = false),
        ),
        const SizedBox(height: 14),

        // ── Степпер устройств (только для семейного тарифа) ──
        if (isFamily) ...[
          const _SectionLabel(text: 'Устройства'),
          const SizedBox(height: 8),
          _FamilyStepper(
            count: _familyDevices,
            max: _kFamilyMaxDevices,
            base: _kFamilyBaseDevices,
            onDecrement: _familyDecrement,
            onIncrement: _familyIncrement,
          ),
          const SizedBox(height: 14),
        ],

        // ── Период ──
        const _SectionLabel(text: 'Период'),
        const SizedBox(height: 8),
        _PeriodPills(
          periods: periods,
          selectedId: p?.id,
          onSelect: (period) {
            HapticFeedback.selectionClick();
            setState(() => _selectedPeriod = period);
          },
        ),
        const SizedBox(height: 14),

        // ── Расчёт ──
        const _SectionLabel(text: 'Расчёт'),
        const SizedBox(height: 8),
        _BreakdownCard(
          baseDevices: baseDevices,
          basePerMonth: basePerMonth,
          extraDevices: extraDevices,
          extraPerMonth: extraPerMonth,
          selectedPeriod: p,
          periodTotal: periodTotal,
          balanceRub: balance,
          finalPrice: finalPrice,
        ),
        const SizedBox(height: 16),

        _CTAButton(
          label: 'Оплатить ${finalPrice.round()} ₽',
          onPressed:
              (p != null && !_pollingForPayment) ? _onPayTapped : null,
          loading: _purchasing || _pollingForPayment,
        ),
        const SizedBox(height: 10),
        const _SecureCaption(),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _SectionLabel
// ─────────────────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: DS.textFaint,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _CurrentTariffCard — «У вас сейчас»
// ─────────────────────────────────────────────────────────────────────────────

class _CurrentTariffCard extends StatelessWidget {
  final String name;
  final int trafficGb;
  final int devices;
  final double? pricePerMonth;
  final MeSubscription? sub;

  const _CurrentTariffCard({
    required this.name,
    required this.trafficGb,
    required this.devices,
    this.pricePerMonth,
    this.sub,
  });

  @override
  Widget build(BuildContext context) {
    final trafficLabel = trafficGb == 0 ? 'Без лимита' : '$trafficGb ГБ';
    final trafficIcon = trafficGb == 0
        ? Icons.all_inclusive_rounded
        : Icons.signal_cellular_alt_rounded;

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

    // Tier 1 — this is the reference point the whole screen's decision hangs
    // off ("what am I on now?"), keyed to the plan's own health colour.
    return AccentCard(
      accent: expiryColor,
      muted: sub?.expireDate == null,
      radius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(
        children: [
          _TariffIcon(name: name, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: DS.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _InfoChip(icon: trafficIcon, label: trafficLabel),
                    _InfoChip(
                        icon: Icons.devices_rounded,
                        label: '$devices устр.'),
                    if (pricePerMonth != null)
                      _InfoChip(
                          icon: Icons.payments_outlined,
                          label: '${pricePerMonth!.round()} ₽/мес'),
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
//  _TariffSelectCard — карточка тарифа в списке (Шаг 1)
// ─────────────────────────────────────────────────────────────────────────────

class _TariffSelectCard extends StatelessWidget {
  final TariffInfo tariff;
  final bool isSelected;
  final bool isPopular;
  final bool isFamily;
  final int? familyDevices;
  final double displayPricePerMonth;
  final VoidCallback onTap;
  final VoidCallback onFamilyDecrement;
  final VoidCallback onFamilyIncrement;

  static const int _kFamilyBase = 5;
  static const int _kFamilyMax = 8;

  const _TariffSelectCard({
    required this.tariff,
    required this.isSelected,
    required this.isPopular,
    required this.isFamily,
    this.familyDevices,
    required this.displayPricePerMonth,
    required this.onTap,
    required this.onFamilyDecrement,
    required this.onFamilyIncrement,
  });

  @override
  Widget build(BuildContext context) {
    final devCount =
        isFamily ? (familyDevices ?? _kFamilyBase) : tariff.deviceLimit;
    final trafficLabel =
        tariff.trafficLimitGb == 0 ? 'Без лимита' : '${tariff.trafficLimitGb} ГБ';
    final devLabel = '$devCount ${_shortPlural(devCount)}';

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // ── Card (рендерится первым — под плашкой) ──
        GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Builder(builder: (context) {
            final (_, accent) = _resolveTariffStyle(tariff.name);
            return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            // Фиксированный padding обеспечивает одинаковую высоту всех карточек
            padding: EdgeInsets.all(isSelected ? 13.5 : 14),
            decoration: BoxDecoration(
              color: isSelected ? accent.withValues(alpha: 0.10) : DS.surface1,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isSelected ? accent : DS.border,
                width: isSelected ? 1.5 : 1.0,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Основная строка: иконка | название+чипы | цена ──
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _TariffIcon(name: tariff.name, selected: isSelected),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tariff.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: DS.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 6),
                          // ── Визуальные чипы ──
                          Row(
                            children: [
                              _InfoChip(
                                icon: tariff.trafficLimitGb == 0
                                    ? Icons.all_inclusive_rounded
                                    : Icons.signal_cellular_alt_rounded,
                                label: trafficLabel,
                              ),
                              const SizedBox(width: 6),
                              _InfoChip(
                                icon: Icons.devices_rounded,
                                label: devLabel,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    // ── Цена ──
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${displayPricePerMonth.round()} ₽',
                          style: const TextStyle(
                              color: DS.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w600),
                        ),
                        const Text(
                          '/мес',
                          style: TextStyle(
                              color: DS.textSecondary,
                              fontSize: 11),
                        ),
                      ],
                    ),
                  ],
                ),

                // ── Family stepper (только когда выбран) ──
                if (isFamily && isSelected && familyDevices != null) ...[
                  const SizedBox(height: 12),
                  _FamilyStepper(
                    count: familyDevices!,
                    max: _kFamilyMax,
                    base: _kFamilyBase,
                    onDecrement: onFamilyDecrement,
                    onIncrement: onFamilyIncrement,
                  ),
                ],
              ],
            ),
          );
          }),
        ),

        // ── Плашка «Популярный» (рендерится последней — поверх карточки) ──
        if (isPopular)
          Positioned(
            top: -10,
            left: 12,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: DS.amber,
                borderRadius: BorderRadius.circular(5),
              ),
              child: const Text(
                'ПОПУЛЯРНЫЙ',
                style: TextStyle(
                    color: Colors.black,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5),
              ),
            ),
          ),
      ],
    );
  }

  static String _shortPlural(int n) {
    final abs = n.abs() % 100;
    final last = abs % 10;
    if (abs >= 11 && abs <= 19) return 'устр.';
    if (last == 1) return 'устр.';
    if (last >= 2 && last <= 4) return 'устр.';
    return 'устр.';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _TariffIcon — контейнер иконки тарифа (40×40, скруглённый)
// ─────────────────────────────────────────────────────────────────────────────

class _TariffIcon extends StatelessWidget {
  final String name;
  final double size;
  final bool selected;
  const _TariffIcon({required this.name, this.size = 40, this.selected = false});

  @override
  Widget build(BuildContext context) {
    final (iconData, accent) = _resolveTariffStyle(name);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: selected ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(size * 0.275),
      ),
      child: Center(
        child: PhosphorIcon(
          iconData,
          color: selected ? accent : accent.withValues(alpha: 0.75),
          size: size * 0.50,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _InfoChip — миниатюрный чип с иконкой и лейблом (трафик, устройства)
// ─────────────────────────────────────────────────────────────────────────────

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 13, color: DS.textSecondary),
      const SizedBox(width: 4),
      Text(
        label,
        style: const TextStyle(
            color: DS.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w500),
      ),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
//  _FamilyStepper — степпер устройств для тарифа «Семейный»
// ─────────────────────────────────────────────────────────────────────────────

class _FamilyStepper extends StatelessWidget {
  final int count;
  final int max;
  final int base;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;

  const _FamilyStepper({
    required this.count,
    required this.max,
    required this.base,
    required this.onDecrement,
    required this.onIncrement,
  });

  @override
  Widget build(BuildContext context) {
    final atMin = count <= base;
    final atMax = count >= max;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0C0B1E),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Устройства',
                    style: TextStyle(color: DS.textSecondary, fontSize: 11)),
                const SizedBox(height: 2),
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: '$count ',
                        style: const TextStyle(
                            color: DS.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500),
                      ),
                      TextSpan(
                        text: 'из $max',
                        style: const TextStyle(
                            color: DS.textFaint,
                            fontSize: 11,
                            fontWeight: FontWeight.w400),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Row(
            children: [
              _StepperBtn(
                icon: Icons.remove_rounded,
                onTap: onDecrement,
                disabled: atMin,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  '$count',
                  style: const TextStyle(
                      color: DS.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600),
                ),
              ),
              _StepperBtn(
                icon: Icons.add_rounded,
                onTap: onIncrement,
                disabled: atMax,
                filled: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _StepperBtn — кнопка степпера (30×30, rounded 8)
// ─────────────────────────────────────────────────────────────────────────────

class _StepperBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool disabled;
  final bool filled;

  const _StepperBtn({
    required this.icon,
    required this.onTap,
    this.disabled = false,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: disabled ? 0.4 : 1.0,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: filled ? DS.violet : DS.surface1,
            border: filled
                ? null
                : Border.all(color: DS.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 16,
            color: filled ? Colors.white : DS.textSecondary,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _CheckoutTariffCard — карточка тарифа на экране чекаута (с карандашом)
// ─────────────────────────────────────────────────────────────────────────────

class _CheckoutTariffCard extends StatelessWidget {
  final TariffInfo tariff;
  final int deviceCount;
  final VoidCallback onEdit;

  const _CheckoutTariffCard({
    required this.tariff,
    required this.deviceCount,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = _tariffSubtitle(
        tariff.name, tariff.trafficLimitGb, deviceCount);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _TariffIcon(name: tariff.name, size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tariff.name,
                    style: const TextStyle(
                        color: DS.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
                Text(
                  subtitle,
                  style: const TextStyle(
                      color: DS.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: onEdit,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.edit_outlined,
                  size: 16, color: DS.violet),
            ),
          ),
        ],
      ),
    );
  }

}

// ─────────────────────────────────────────────────────────────────────────────
//  _PeriodPills — горизонтальные таблетки выбора периода
// ─────────────────────────────────────────────────────────────────────────────

class _PeriodPills extends StatelessWidget {
  final List<TariffPeriod> periods;
  final String? selectedId;
  final ValueChanged<TariffPeriod> onSelect;

  const _PeriodPills({
    required this.periods,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: periods.map((p) {
          final isActive = p.id == selectedId;
          final hasDiscount = p.discountPercent > 0;

          return Expanded(
            child: GestureDetector(
              onTap: () => onSelect(p),
              behavior: HitTestBehavior.opaque,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: isActive ? DS.violet : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Center(
                      child: Text(
                        '${p.months} мес',
                        style: TextStyle(
                          color: isActive
                              ? Colors.white
                              : DS.textSecondary,
                          fontSize: 11,
                          fontWeight: isActive
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                  if (hasDiscount)
                    Positioned(
                      top: -4,
                      right: 2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(0x2E1DC97A),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          '−${p.discountPercent}%',
                          style: const TextStyle(
                              color: DS.emerald,
                              fontSize: 9,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _BreakdownCard — блок «Расчёт» на экране чекаута
// ─────────────────────────────────────────────────────────────────────────────

class _BreakdownCard extends StatelessWidget {
  final int baseDevices;
  final double basePerMonth;
  final int extraDevices;
  final double extraPerMonth;
  final TariffPeriod? selectedPeriod;
  final double periodTotal;
  final double balanceRub;
  final double finalPrice;

  const _BreakdownCard({
    required this.baseDevices,
    required this.basePerMonth,
    required this.extraDevices,
    required this.extraPerMonth,
    required this.selectedPeriod,
    required this.periodTotal,
    required this.balanceRub,
    required this.finalPrice,
  });

  @override
  Widget build(BuildContext context) {
    final months = selectedPeriod?.months ?? 1;
    final periodLabel = _monthsLabel(months);
    final balanceDeducted =
        balanceRub > 0 ? balanceRub.clamp(0, periodTotal) : 0.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          // Базовая цена · N устр.
          _Row(
            label: 'Базовая цена · $baseDevices устр.',
            value: '${basePerMonth.round()} ₽/мес',
          ),

          // Доп. устройства — только если > 0
          if (extraDevices > 0)
            _Row(
              label: '$extraDevices доп. устр.',
              value: '+${extraPerMonth.round()} ₽/мес',
            ),

          // × N месяцев
          _Row(
            label: '× $periodLabel',
            value: '${periodTotal.round()} ₽',
          ),

          // Списано с баланса — только если баланс > 0
          if (balanceRub > 0)
            _Row(
              label: 'Списано с баланса',
              value: '−${balanceDeducted.round()} ₽',
              labelColor: DS.emerald,
              valueColor: DS.emerald,
            ),

          // Divider
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(
                height: 1,
                thickness: 0.5,
                color: Color(0xFF2A2A38)),
          ),

          // К оплате
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              const Text('К оплате',
                  style: TextStyle(
                      color: DS.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w500)),
              Text(
                '${finalPrice.round()} ₽',
                style: const TextStyle(
                    color: DS.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ],
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
//  _SwitchBreakdownCard — блок «Расчёт» для смены тарифа активной подписки
//  (реальная доплата за оставшиеся дни, без выбора периода).
// ─────────────────────────────────────────────────────────────────────────────

class _SwitchBreakdownCard extends StatelessWidget {
  final TariffSwitchPreview preview;

  const _SwitchBreakdownCard({required this.preview});

  @override
  Widget build(BuildContext context) {
    final p = preview;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          _Row(
            label: 'Доплата за ${p.remainingDays} дн.',
            value: p.upgradeCostLabel,
          ),
          if (p.hasDeviceBreakdown)
            _Row(
              label: '${p.devicesRequested} устр. (доп.)',
              value:
                  '+${((p.extraDeviceCostKopeks ?? 0) / 100).round()} ₽',
            ),
          if (p.upgradeCostKopeks > 0)
            _Row(
              label: 'Списано с баланса',
              value:
                  '−${(min(p.upgradeCostKopeks, p.balanceKopeks) / 100).round()} ₽',
              labelColor: DS.emerald,
              valueColor: DS.emerald,
            ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(
                height: 1, thickness: 0.5, color: Color(0xFF2A2A38)),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              const Text('К оплате',
                  style: TextStyle(
                      color: DS.textPrimary, fontSize: 14, fontWeight: FontWeight.w500)),
              Text(
                '${(p.upgradeCostKopeks / 100).round()} ₽',
                style: const TextStyle(
                    color: DS.textPrimary, fontSize: 22, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final Color labelColor;
  final Color valueColor;

  const _Row({
    required this.label,
    required this.value,
    this.labelColor = DS.textSecondary,
    this.valueColor = DS.textPrimary,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(color: labelColor, fontSize: 13)),
          Text(value,
              style: TextStyle(
                  color: valueColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _CTAButton — главная кнопка действия
// ─────────────────────────────────────────────────────────────────────────────

class _CTAButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  const _CTAButton({
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
          disabledBackgroundColor: DS.borderDim,
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
                    color: Colors.white, strokeWidth: 2.5),
              )
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
        Icon(Icons.lock_outline_rounded, size: 12, color: DS.textFaint),
        SizedBox(width: 4),
        Text('Безопасная оплата · YooKassa',
            style: TextStyle(color: DS.textFaint, fontSize: 11)),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _ErrorRetry
// ─────────────────────────────────────────────────────────────────────────────

class _ErrorRetry extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorRetry({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded,
                color: DS.textFaint, size: 48),
            const SizedBox(height: 16),
            const Text(
              'Не удалось загрузить тарифы.\nПопробуйте ещё раз.',
              textAlign: TextAlign.center,
              style: TextStyle(color: DS.textSecondary, fontSize: 15),
            ),
            const SizedBox(height: 20),
            _CTAButton(label: 'Повторить', onPressed: onRetry, loading: false),
          ],
        ),
      ),
    );
  }
}
