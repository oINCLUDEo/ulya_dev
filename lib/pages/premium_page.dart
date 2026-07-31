import 'dart:async';
import 'dart:math' show Random, cos, sin, pi;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../main.dart' show DS;
import '../models/me_response.dart';
import '../services/app_logger.dart';
import '../services/auth_state.dart';
import '../services/me_service.dart';
import '../services/referral_service.dart';
import '../services/subscription_api_service.dart';
import '../utils/referral_card.dart';
import '../utils/tariff_pricing.dart' as pricing;
import '../widgets/skeleton.dart';
import '../widgets/telegram_login_button.dart';
import 'auth_bottom_sheet.dart';
import 'payment_webview_page.dart';

part 'premium_page_cards.dart';
part 'premium_page_status.dart';
part 'premium_page_overlays.dart';

// ── Shared helpers ───────────────────────────────────────────────────────────
// Thin wrappers around lib/utils/tariff_pricing.dart — kept so none of the
// call sites below (or in the part files) had to change. The real,
// unit-tested logic lives in that module.

/// Parses a period label into a month count.
/// Examples: "3 месяца" → 3, "1 год" → 12, "6 мес" → 6
int? _parseMonths(String label) => pricing.parsePeriodMonths(label);

/// Pluralises "день / дня / дней".
String _pluralDays(int n) => pricing.pluralDays(n);

// ── Premium-page-specific constants (colours with no DS equivalent) ──────────
// DS tokens used where possible; these are kept because they define the
// distinct "Signal Dark" premium aesthetic (bluer/darker than the main palette).

const _premSurface = Color(0xFF111124);  // blue-tinted card surface
const _cg1         = Color(0xFF0D0B26);  // hero card gradient – dark indigo
const _cg2         = Color(0xFF0A0820);  // hero card gradient – near-black indigo
const _indigoB     = Color(0xFF9D8FFF);  // lighter violet for highlights
const _indigoD     = Color(0xFF4338CA);  // darker violet for gradients/shadows
const _teal        = Color(0xFF2DD4BF);  // teal – active/success badge accent
const _sky         = Color(0xFF60A5FA);  // sky-blue – traffic feature chip
const _silver      = Color(0xFF8B96AA);  // cool silver – basic tier icon
const _t0          = Color(0xFFF0F0FF);  // warm white headings
const _t1          = Color(0xFF8892AA);  // secondary text (blueish tint)
const _t2          = Color(0xFF454565);  // muted text (darker than DS.textMuted)
const _b0          = Color(0xFF16162E);  // deep divider border
const _b1          = Color(0xFF1E1E38);  // card border
const _r16         = 16.0;              // medium card radius
const _r22         = 22.0;              // large card / modal radius

// ═══════════════════════════════════════════════════════════════════════════
//  PremiumPage
// ═══════════════════════════════════════════════════════════════════════════

class PremiumPage extends StatefulWidget {
  const PremiumPage({super.key});

  @override
  State<PremiumPage> createState() => _PremiumPageState();
}

class _PremiumPageState extends State<PremiumPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {

  // ── Options ────────────────────────────────────────────────────────────────
  SubscriptionOptions? _options;
  bool _loadingOptions  = false;
  bool _pendingOptions  = false;   // set when a reload is requested during an active load
  bool _purchasing      = false;

  // ── Trial (free pilot period) ──────────────────────────────────────────────
  // Loaded from /mobile/v1/subscription/trial; the CTA is hidden if the user
  // has already redeemed their trial or the programme is disabled server-side.
  bool _trialAvailable = false;
  int  _trialDays      = 7;
  bool _activatingTrial = false;

  // ── Payment polling ────────────────────────────────────────────────────────
  Timer? _pollTimer;
  int    _pollAttempt        = 0;
  bool   _pollingForPayment  = false;
  bool   _pendingPaymentPoll = false;
  bool   _showSuccessOverlay = false;
  /// Subscription expiry captured right before opening checkout. Payment is
  /// only "confirmed" if the expiry advances past this (so cancelling with an
  /// already-active sub no longer reports a false success).
  DateTime? _payBaselineExpiry;
  bool      _payHadSubBefore = false;
  static const int      _maxPollAttempts = 30;
  static const Duration _pollInterval    = Duration(seconds: 4);

  // ── Tariff catalog ─────────────────────────────────────────────────────────
  List<TariffInfo>? _tariffs;
  // Entrance: single controller drives all tariff cards via Interval stagger
  late final AnimationController _entranceCtrl;
  int?              _selectedTariffId;
  String?           _selectedTariffPeriodId;
  // For active-user "change tariff" flow:
  int?              _changeTariffId;
  String?           _changeTariffPeriodId;
  // For active-user "renew current tariff" flow (tariff mode):
  String?           _renewTariffPeriodId;
  // Active-user action tab: false=renew, true=change tariff
  bool              _showChangeTariff = false;
  // Global period selector (days): shared by new-user + change-tariff radio card list
  int?              _selectedPeriodDays;
  // Prorated price preview for change-tariff flow (null = not yet loaded)
  UpgradeCalcResult? _changeTariffCalcResult;
  bool               _changeTariffCalcLoading = false;

  // ── New-user legacy buy flow ───────────────────────────────────────────────
  String? _selectedPeriodId;

  // ── Active-user manage flow ────────────────────────────────────────────────
  String?           _renewPeriodId;
  int?              _selectedTrafficGb;
  int?              _selectedDevicesAdd;
  Map<String, int?> _renewPrices   = {};
  Map<int, int?>    _trafficPrices = {};
  Map<int, int?>    _devicesPrices = {};

  // ── Change-tariff 2-step checkout ─────────────────────────────────────────
  bool _checkoutMode     = false;   // false=step1 (tariff list), true=step2 (checkout)
  bool _useBalance       = false;   // balance toggle on renew + checkout screens
  int  _familyDeviceCount = 5;      // device count in family stepper

  // ── Computed ───────────────────────────────────────────────────────────────

  bool get _trafficTabAvailable =>
      (_options?.trafficTopupEnabled ?? false) &&
      (_options?.trafficTopupPackages.isNotEmpty ?? false);

  bool get _devicesTabAvailable => _devicesOpts.isNotEmpty;

  List<int> get _devicesOpts {
    final opts = _options;
    if (opts == null) return const [];
    final currentPeriodId = opts.currentSubscription?['period_id'] as String?;
    DevicesConfig? cfg;
    if (currentPeriodId != null) {
      cfg = opts.periods
          .cast<PeriodOption?>()
          .firstWhere((p) => p?.id == currentPeriodId, orElse: () => null)
          ?.devices;
    }
    cfg ??= opts.periods
        .cast<PeriodOption?>()
        .firstWhere((p) => p?.devices != null, orElse: () => null)
        ?.devices;
    if (cfg == null) return const [];

    final current = meNotifier.value?.subscription?.deviceLimit ?? 1;
    final maxCfg  = cfg.maximum ??
        (cfg.options.isNotEmpty
            ? cfg.options.reduce((a, b) => a > b ? a : b)
            : null);
    if (maxCfg != null && current >= maxCfg) return const [];
    final adds = cfg.options
        .where((v) => v > current && (maxCfg == null || v <= maxCfg))
        .map((v) => v - current)
        .where((v) => v > 0)
        .toSet()
        .toList()
      ..sort();
    if (adds.isNotEmpty) return adds;
    if (maxCfg == null || current < maxCfg) return [1];
    return const [];
  }

  List<TrafficTopupPackage> get _topupPackages =>
      _options?.trafficTopupPackages ?? [];

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _entranceCtrl = AnimationController(vsync: this);
    WidgetsBinding.instance.addObserver(this);
    authStateNotifier.addListener(_onAuthChanged);
    meNotifier.addListener(_onMeChanged);
    globalRefreshNotifier.addListener(_onGlobalRefresh);
    // Pre-populate from global in-memory cache so the page never flashes
    // an empty state — a background network refresh follows right after.
    final cachedTariffs = tarifsNotifier.value;
    final cachedOptions = optionsNotifier.value;
    if (cachedTariffs != null || cachedOptions != null) {
      _applyOptionsData(cachedOptions, cachedTariffs);
    }
    _loadOptions();
  }

  @override
  void dispose() {
    _entranceCtrl.dispose();
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    authStateNotifier.removeListener(_onAuthChanged);
    meNotifier.removeListener(_onMeChanged);
    globalRefreshNotifier.removeListener(_onGlobalRefresh);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _pendingPaymentPoll) {
      _pendingPaymentPoll = false;
      _startPaymentPolling();
    }
  }

  void _onAuthChanged() { if (mounted) { _loadOptions(); setState(() {}); } }
  void _onMeChanged()     { if (mounted) setState(() {}); }
  void _onGlobalRefresh() { if (mounted) _loadOptions(); }

  // ── Data ───────────────────────────────────────────────────────────────────

  /// Applies fetched/cached opts+tariffs into state.  Call from [_loadOptions]
  /// and from [initState] when the global cache is already populated.
  void _applyOptionsData(SubscriptionOptions? opts, List<TariffInfo>? tariffs) {
    if (!mounted) return;
    setState(() {
      if (opts != null) _options = opts;

      // ── Tariff catalog ────────────────────────────────────────────────
      if (tariffs != null && tariffs.isNotEmpty) {
        final sorted = [...tariffs]..sort((a, b) {
          final ap = a.cheapestPeriod?.priceKopeks ?? 0;
          final bp = b.cheapestPeriod?.priceKopeks ?? 0;
          return ap.compareTo(bp);
        });
        _tariffs = sorted;

        if (_selectedTariffId == null ||
            !sorted.any((t) => t.id == _selectedTariffId)) {
          _selectedTariffId = sorted.first.id;
        }
        final selTariff = sorted.firstWhere(
            (t) => t.id == _selectedTariffId,
            orElse: () => sorted.first);
        if ((_selectedTariffPeriodId == null ||
                !selTariff.periods.any((p) => p.id == _selectedTariffPeriodId)) &&
            selTariff.periods.isNotEmpty) {
          _selectedTariffPeriodId =
              selTariff.cheapestPeriod?.id ?? selTariff.periods.first.id;
        }

        final allUniqueDays = sorted
            .expand((t) => t.periods.map((p) => p.days))
            .toSet();
        final preferredDays =
            selTariff.cheapestPeriod?.days ??
            (selTariff.periods.isNotEmpty ? selTariff.periods.first.days : null);
        if (_selectedPeriodDays == null ||
            !allUniqueDays.contains(_selectedPeriodDays)) {
          _selectedPeriodDays = preferredDays;
        }

        if (_changeTariffId == null ||
            !sorted.any((t) => t.id == _changeTariffId)) {
          _changeTariffId = sorted.first.id;
        }
        final chTariff = sorted.firstWhere(
            (t) => t.id == _changeTariffId,
            orElse: () => sorted.first);
        if ((_changeTariffPeriodId == null ||
                !chTariff.periods.any((p) => p.id == _changeTariffPeriodId)) &&
            chTariff.periods.isNotEmpty) {
          _changeTariffPeriodId =
              chTariff.cheapestPeriod?.id ?? chTariff.periods.first.id;
        }

        final subName =
            (meNotifier.value?.subscription?.planName ?? '').toLowerCase().trim();
        if (subName.isNotEmpty) {
          final curTariff = tariffs.cast<TariffInfo?>().firstWhere(
              (t) => t!.name.toLowerCase().trim() == subName,
              orElse: () => null);
          if (curTariff != null && curTariff.periods.isNotEmpty &&
              (_renewTariffPeriodId == null ||
                  !curTariff.periods.any((p) => p.id == _renewTariffPeriodId))) {
            _renewTariffPeriodId =
                curTariff.cheapestPeriod?.id ?? curTariff.periods.first.id;
          }
        }
      }

      // ── Legacy flow ──────────────────────────────────────────────────
      final o = opts ?? _options;
      if (o != null && o.periods.isNotEmpty) {
        _selectedPeriodId ??= _bestPeriodId(o) ?? o.periods.first.id;
        _renewPeriodId ??= o.periods.first.id;
      }
    });
    final o = opts ?? _options;
    if (o != null) _initManagePrices(o);
  }

  Future<void> _loadOptions() async {
    if (!mounted) return;
    if (_loadingOptions) { _pendingOptions = true; return; }
    _pendingOptions = false;
    setState(() => _loadingOptions = true);
    try {
      final futures = await Future.wait<dynamic>([
        SubscriptionApiService.getOptions(),
        SubscriptionApiService.getTariffs(),
        SubscriptionApiService.getTrialInfo(),
      ]);
      final opts    = futures[0] as SubscriptionOptions?;
      final tariffs = futures[1] as List<TariffInfo>?;
      final trial   = futures[2] as Map<String, dynamic>?;
      if (mounted) _applyOptionsData(opts, tariffs);
      if (mounted) _applyTrialInfo(trial);
    } catch (e) { debugPrint('PremiumPage._loadOptions: $e'); }
    if (mounted) setState(() => _loadingOptions = false);
    if (_pendingOptions && mounted) {
      _pendingOptions = false;
      _loadOptions();
    }
    _triggerStaggeredEntrance();
  }

  /// Reads trial availability from the API. The endpoint may return any of:
  ///   * {available: true,  days: 7}            — eligible, show CTA
  ///   * {available: false, ...}                — already used / disabled
  ///   * {is_available: true, trial_days: 7}    — alternate key naming
  void _applyTrialInfo(Map<String, dynamic>? trial) {
    if (trial == null) {
      setState(() => _trialAvailable = false);
      return;
    }
    final available = (trial['available'] as bool?) ??
        (trial['is_available'] as bool?) ??
        (trial['can_activate'] as bool?) ??
        false;
    final days = (trial['days'] as num?)?.toInt() ??
        (trial['trial_days'] as num?)?.toInt() ??
        (trial['duration_days'] as num?)?.toInt() ??
        7;
    setState(() {
      _trialAvailable = available;
      _trialDays      = days <= 0 ? 7 : days;
    });
  }

  Future<void> _onActivateTrial() async {
    if (_activatingTrial) return;
    final token = authStateNotifier.value.cabinetAccessToken;
    setState(() => _activatingTrial = true);
    try {
      final result = token != null && token.isNotEmpty
          ? await SubscriptionApiService.activateCabinetTrial()
          : await SubscriptionApiService.activateTrial();
      if (!mounted) return;
      if (result?.status == 'success') {
        // Pull /me + options so the screen reflects the new trial sub.
        await MeService.refresh();
        await _loadOptions();
        if (mounted) setState(() => _showSuccessOverlay = true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result?.message ?? 'Не удалось активировать пробный период'),
          backgroundColor: DS.surface2,
        ));
      }
    } finally {
      if (mounted) setState(() => _activatingTrial = false);
    }
  }

  void _triggerStaggeredEntrance() {
    final count = _tariffs?.length ?? 0;
    if (count == 0 || !mounted) return;
    // Each card has 55 ms stagger; reveal lasts 320 ms.
    // Total = (n−1)×55 + 320 ms.  Max 5 cards → 540 ms — well within limit.
    _entranceCtrl
      ..duration = Duration(milliseconds: (count - 1) * 55 + 320)
      ..forward(from: 0);
  }

  /// Returns the eased [0..1] progress for card at [index] out of [total],
  /// given the current controller value [t].  Thread-safe, allocation-free.
  static double _cardReveal(int index, int total, double t) {
    const staggerMs = 55.0;
    const revealMs  = 320.0;
    final totalMs = (total - 1) * staggerMs + revealMs;
    final start   = (index * staggerMs) / totalMs;
    final end     = (index * staggerMs + revealMs) / totalMs;
    final local   = ((t - start) / (end - start)).clamp(0.0, 1.0);
    return Curves.easeOutCubic.transform(local);
  }

  void _initManagePrices(SubscriptionOptions opts) {
    _renewPrices   = { for (final p in opts.periods) p.id: null };
    _trafficPrices = { for (final p in _topupPackages) p.gb: null };
    _devicesPrices = { for (final d in _devicesOpts) d: null };
    for (final p in opts.periods)    { _calcRenewPrice(p.id); }
    for (final p in _topupPackages)  { _calcTrafficPrice(p.gb); }
    for (final d in _devicesOpts)    { _calcDevicesPrice(d); }

    if (_selectedTrafficGb == null && _topupPackages.isNotEmpty) {
      _selectedTrafficGb = _topupPackages.first.gb;
    }
    if (_selectedDevicesAdd == null && _devicesOpts.isNotEmpty) {
      _selectedDevicesAdd = _devicesOpts.first;
    }
  }

  String? _bestPeriodId(SubscriptionOptions opts) =>
      pricing.bestDiscountPeriodId(opts);

  // ── Manage price calculations ───────────────────────────────────────────────

  ({int? traffic, int? devices}) _resolveParams(String periodId) {
    final opts = _options;
    if (opts == null) return (traffic: null, devices: null);
    final period = opts.periods.firstWhere(
        (p) => p.id == periodId, orElse: () => opts.periods.first);
    int? traffic;
    final tCfg = period.traffic;
    if (tCfg != null && tCfg.options.isNotEmpty) {
      final cur = meNotifier.value?.subscription?.trafficLimitGb;
      final ok  = tCfg.options.any((o) => o.value == cur);
      traffic   = (cur != null && ok)
          ? cur
          : tCfg.options.firstWhere((o) => o.isDefault, orElse: () => tCfg.options.first).value;
    }
    int? devices;
    final dCfg = period.devices;
    if (dCfg != null) {
      final cur = meNotifier.value?.subscription?.deviceLimit ?? 1;
      devices = dCfg.options.contains(cur) ? cur : (dCfg.defaultValue ?? dCfg.minimum);
    }
    return (traffic: traffic, devices: devices);
  }

  Future<void> _calcRenewPrice(String periodId) async {
    if (!mounted) return;
    setState(() { _renewPrices = Map.from(_renewPrices)..[periodId] = null; });
    final p = _resolveParams(periodId);
    final r = await SubscriptionApiService.calcPrice(
        periodId: periodId, trafficValue: p.traffic, devices: p.devices);
    if (!mounted) return;
    setState(() { _renewPrices = Map.from(_renewPrices)..[periodId] = r?.totalKopeks ?? 0; });
  }

  Future<void> _calcTrafficPrice(int gb) async {
    if (!mounted) return;
    setState(() { _trafficPrices = Map.from(_trafficPrices)..[gb] = null; });
    final r = await SubscriptionApiService.calcUpgradePrice(trafficAdd: gb);
    if (!mounted) return;
    setState(() { _trafficPrices = Map.from(_trafficPrices)..[gb] = r?.amountKopeks ?? 0; });
  }

  Future<void> _calcDevicesPrice(int d) async {
    if (!mounted) return;
    setState(() { _devicesPrices = Map.from(_devicesPrices)..[d] = null; });
    final r = await SubscriptionApiService.calcUpgradePrice(devicesAdd: d);
    if (!mounted) return;
    setState(() { _devicesPrices = Map.from(_devicesPrices)..[d] = r?.amountKopeks ?? 0; });
  }

  // ── Payment polling ────────────────────────────────────────────────────────

  void _startPaymentPolling() {
    if (!mounted) return;
    appLogger.info('Payment', 'poll: started (max $_maxPollAttempts attempts)');
    _pollTimer?.cancel();
    setState(() { _pollingForPayment = true; _pollAttempt = 0; });
    _pollTimer = Timer.periodic(_pollInterval, _onPollTick);
  }

  Future<void> _onPollTick(Timer timer) async {
    _pollAttempt++;
    await MeService.refresh();
    if (!mounted) { timer.cancel(); return; }
    final sub    = meNotifier.value?.subscription;
    final active = sub != null && sub.isActive && !sub.isTrial;
    // Confirmed only when a NEW paid period landed: either the user had no paid
    // sub before, or the expiry moved forward past the pre-checkout baseline.
    final exp = sub?.expireDate;
    final confirmed = active &&
        (!_payHadSubBefore ||
            _payBaselineExpiry == null ||
            exp == null ||
            exp.isAfter(_payBaselineExpiry!));
    if (confirmed || _pollAttempt >= _maxPollAttempts) {
      timer.cancel(); _pollTimer = null;
      appLogger.info('Payment',
          'poll: finished attempt=$_pollAttempt confirmed=$confirmed '
          'expiry=${exp?.toIso8601String()}');
      if (!mounted) return;
      setState(() => _pollingForPayment = false);
      if (confirmed) {
        await _loadOptions();
        if (mounted) _snack('Подписка активирована!', ok: true);
      } else {
        appLogger.warning('Payment',
            'poll: gave up after $_maxPollAttempts attempts without confirmation');
        if (mounted) _snack('Платёж ещё не подтверждён. Проверьте статус позже.', ok: true);
      }
    }
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _onBuyTapped() async {
    if (!authStateNotifier.value.isLoggedIn) {
      await showAuthBottomSheet(context);
      return;
    }

    // ── Tariff mode ───────────────────────────────────────────────────────────
    final tariffs = _tariffs;
    if (tariffs != null && tariffs.isNotEmpty) {
      final tariff = tariffs.firstWhere(
          (t) => t.id == (_selectedTariffId ?? tariffs.first.id),
          orElse: () => tariffs.first);
      if (tariff.periods.isEmpty) return;
      // Prefer period by days (radio-card flow), fall back to stored id
      final period = (_selectedPeriodDays != null
              ? _periodForDays(tariff, _selectedPeriodDays!)
              : null) ??
          (_selectedTariffPeriodId != null
              ? tariff.periods.firstWhere(
                  (p) => p.id == _selectedTariffPeriodId,
                  orElse: () => tariff.periods.first)
              : tariff.periods.first);

      setState(() => _purchasing = true);
      try {
        final r = await SubscriptionApiService.buyTariff(
            tariffId: tariff.id, periodDays: period.days);
        if (!mounted) return;
        if (r == null) {
          _snack('Ошибка соединения с сервером');
        } else if (r.isSuccess) {
          setState(() => _showSuccessOverlay = true);
          await MeService.refresh();
          await _loadOptions();
          await Future.delayed(const Duration(milliseconds: 1800));
          if (mounted) setState(() => _showSuccessOverlay = false);
        } else if (r.requiresPayment && r.paymentUrl != null) {
          await _openPaymentUrl(r.paymentUrl!);
        } else {
          _snack(r.message ?? 'Ошибка при покупке');
        }
      } catch (e) {
      appLogger.error('Payment', 'purchase action failed: $e');
      if (mounted) _snack('Ошибка: $e');
    }
      if (mounted) setState(() => _purchasing = false);
      return;
    }

    // ── Legacy mode ───────────────────────────────────────────────────────────
    final periodId = _selectedPeriodId;
    if (periodId == null) return;
    final opts = _options;
    if (opts == null) return;
    final period = opts.periods.firstWhere((p) => p.id == periodId, orElse: () => opts.periods.first);
    int? traffic;
    final tCfg = period.traffic;
    if (tCfg != null && tCfg.options.isNotEmpty) {
      traffic = tCfg.defaultValue ??
          tCfg.options.firstWhere((o) => o.isDefault, orElse: () => tCfg.options.first).value;
    }
    int? devices;
    final dCfg = period.devices;
    if (dCfg != null) devices = dCfg.defaultValue ?? dCfg.minimum;

    setState(() => _purchasing = true);
    try {
      final r = await SubscriptionApiService.buySubscription(
          periodId: periodId, trafficValue: traffic, devices: devices);
      if (!mounted) return;
      if (r == null)                         { _snack('Ошибка соединения с сервером'); }
      else if (r.isSuccess) {
        setState(() => _showSuccessOverlay = true);
        await MeService.refresh();
        await _loadOptions();
        await Future.delayed(const Duration(milliseconds: 1800));
        if (mounted) setState(() => _showSuccessOverlay = false);
      } else if (r.requiresPayment && r.paymentUrl != null) {
        await _openPaymentUrl(r.paymentUrl!);
      } else { _snack(r.message ?? 'Ошибка при покупке'); }
    } catch (e) {
      appLogger.error('Payment', 'purchase action failed: $e');
      if (mounted) _snack('Ошибка: $e');
    }
    if (mounted) setState(() => _purchasing = false);
  }

  Future<void> _onRenewTapped() async {
    final periodId = _renewPeriodId;
    if (periodId == null) return;
    setState(() => _purchasing = true);
    try {
      final p = _resolveParams(periodId);
      final r = await SubscriptionApiService.buySubscription(
          periodId: periodId, trafficValue: p.traffic, devices: p.devices);
      if (!mounted) return;
      if (r == null)                         { _snack('Ошибка соединения с сервером'); }
      else if (r.isSuccess) {
        setState(() => _showSuccessOverlay = true);
        await MeService.refresh();
        globalRefreshNotifier.value++;
        await _loadOptions();
        await Future.delayed(const Duration(milliseconds: 1800));
        if (mounted) setState(() => _showSuccessOverlay = false);
      } else if (r.requiresPayment && r.paymentUrl != null) {
        await _openPaymentUrl(r.paymentUrl!);
      } else { _snack(r.message ?? 'Ошибка при продлении'); }
    } catch (e) {
      appLogger.error('Payment', 'purchase action failed: $e');
      if (mounted) _snack('Ошибка: $e');
    }
    if (mounted) setState(() => _purchasing = false);
  }

  Future<void> _onUpgradeTapped({int? trafficAdd, int? devicesAdd}) async {
    setState(() => _purchasing = true);
    try {
      final r = await SubscriptionApiService.upgradeSubscription(
          periodId: null, trafficAdd: trafficAdd, devicesAdd: devicesAdd);
      if (!mounted) return;
      if (r == null)                         { _snack('Ошибка соединения с сервером'); }
      else if (r.isSuccess) {
        setState(() => _showSuccessOverlay = true);
        await MeService.refresh();
        globalRefreshNotifier.value++;
        await _loadOptions();
        await Future.delayed(const Duration(milliseconds: 1800));
        if (mounted) setState(() => _showSuccessOverlay = false);
      } else if (r.requiresPayment && r.paymentUrl != null) {
        await _openPaymentUrl(r.paymentUrl!);
      } else { _snack(r.message ?? 'Ошибка при улучшении'); }
    } catch (e) {
      appLogger.error('Payment', 'purchase action failed: $e');
      if (mounted) _snack('Ошибка: $e');
    }
    if (mounted) setState(() => _purchasing = false);
  }

  Future<void> _onChangeTariffTapped() async {
    final tariffs = _tariffs;
    if (tariffs == null || tariffs.isEmpty) return;
    final tariff = tariffs.firstWhere(
        (t) => t.id == (_changeTariffId ?? tariffs.first.id),
        orElse: () => tariffs.first);
    if (tariff.periods.isEmpty) return;
    // Prefer period by days (radio-card flow), fall back to stored id
    final period = (_selectedPeriodDays != null
            ? _periodForDays(tariff, _selectedPeriodDays!)
            : null) ??
        (_changeTariffPeriodId != null
            ? tariff.periods.firstWhere(
                (p) => p.id == _changeTariffPeriodId,
                orElse: () => tariff.periods.first)
            : tariff.periods.first);

    setState(() => _purchasing = true);
    try {
      final r = await SubscriptionApiService.changeTariff(
          tariffId: tariff.id, periodDays: period.days);
      if (!mounted) return;
      if (r == null) {
        _snack('Ошибка соединения с сервером');
      } else if (r.isSuccess) {
        setState(() => _showSuccessOverlay = true);
        await MeService.refresh();
        globalRefreshNotifier.value++;
        await _loadOptions();
        await Future.delayed(const Duration(milliseconds: 1800));
        if (mounted) setState(() => _showSuccessOverlay = false);
      } else if (r.requiresPayment && r.paymentUrl != null) {
        await _openPaymentUrl(r.paymentUrl!);
      } else {
        _snack(r.message ?? 'Ошибка при смене тарифа');
      }
    } catch (e) {
      appLogger.error('Payment', 'purchase action failed: $e');
      if (mounted) _snack('Ошибка: $e');
    }
    if (mounted) setState(() => _purchasing = false);
  }

  /// Fetches the prorated price for switching to the currently selected tariff.
  /// Sets _changeTariffCalcResult to 0 immediately for downgrades (no network call).
  Future<void> _loadChangeTariffCalc() async {
    final tariffs = _tariffs;
    if (tariffs == null || tariffs.isEmpty) return;

    final tariff = tariffs.firstWhere(
      (t) => t.id == (_changeTariffId ?? tariffs.first.id),
      orElse: () => tariffs.first,
    );
    if (tariff.periods.isEmpty) return;

    final period = (_selectedPeriodDays != null
            ? _periodForDays(tariff, _selectedPeriodDays!)
            : null) ??
        tariff.cheapestPeriod ??
        tariff.periods.first;

    // Determine if this is a downgrade by comparing tier levels.
    final subName =
        (meNotifier.value?.subscription?.planName ?? '').toLowerCase().trim();
    TariffInfo? curTariff;
    if (subName.isNotEmpty) {
      try {
        curTariff =
            tariffs.firstWhere((t) => t.name.toLowerCase().trim() == subName);
      } catch (_) {}
    }

    // Downgrade is always free — skip the network round-trip.
    if (curTariff != null && tariff.tierLevel <= curTariff.tierLevel) {
      if (mounted) {
        setState(() => _changeTariffCalcResult =
            const UpgradeCalcResult(amountKopeks: 0, amountRub: 0.0));
      }
      return;
    }

    if (!mounted) return;
    setState(() {
      _changeTariffCalcLoading = true;
      _changeTariffCalcResult  = null;
    });
    try {
      final r = await SubscriptionApiService.calcChangeTariffPrice(
        tariffId:  tariff.id,
        periodDays: period.days,
      );
      if (mounted) {
        setState(() {
          _changeTariffCalcResult  = r;
          _changeTariffCalcLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _changeTariffCalcLoading = false);
    }
  }

  /// Renewal of the current active tariff via tariff API (tariff mode).
  /// Falls back to legacy [_onRenewTapped] if the current tariff cannot be found.
  Future<void> _onRenewCurrentTariffTapped() async {
    final tariffs = _tariffs;
    final sub     = meNotifier.value?.subscription;
    if (tariffs == null || sub == null) { await _onRenewTapped(); return; }

    final subName = (sub.planName ?? '').toLowerCase().trim();
    TariffInfo? curTariff;
    if (subName.isNotEmpty) {
      try {
        curTariff = tariffs.firstWhere(
            (t) => t.name.toLowerCase().trim() == subName);
      } catch (_) {}
    }

    if (curTariff == null || curTariff.periods.isEmpty) {
      await _onRenewTapped(); return;
    }

    final period = _renewTariffPeriodId != null
        ? curTariff.periods.firstWhere(
            (p) => p.id == _renewTariffPeriodId,
            orElse: () => curTariff!.periods.first)
        : curTariff.periods.first;

    setState(() => _purchasing = true);
    try {
      final r = await SubscriptionApiService.buyTariff(
          tariffId: curTariff.id, periodDays: period.days);
      if (!mounted) return;
      if (r == null) {
        _snack('Ошибка соединения с сервером');
      } else if (r.isSuccess) {
        setState(() => _showSuccessOverlay = true);
        await MeService.refresh();
        globalRefreshNotifier.value++;
        await _loadOptions();
        await Future.delayed(const Duration(milliseconds: 1800));
        if (mounted) setState(() => _showSuccessOverlay = false);
      } else if (r.requiresPayment && r.paymentUrl != null) {
        await _openPaymentUrl(r.paymentUrl!);
      } else {
        _snack(r.message ?? 'Ошибка при продлении');
      }
    } catch (e) {
      appLogger.error('Payment', 'purchase action failed: $e');
      if (mounted) _snack('Ошибка: $e');
    }
    if (mounted) setState(() => _purchasing = false);
  }

  Future<void> _openPaymentUrl(String url) async {
    if (!mounted) return;
    // Snapshot the current expiry so polling can tell a real payment from a
    // cancelled one (see _onPollTick).
    final curSub = meNotifier.value?.subscription;
    _payHadSubBefore = curSub != null && curSub.isActive && !curSub.isTrial;
    _payBaselineExpiry = curSub?.expireDate;

    // Open checkout in an embedded in-app window (our own top bar, no browser
    // UI). When it closes we poll the backend for the payment result.
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PaymentWebViewPage(url: url),
      fullscreenDialog: true,
    ));
    if (!mounted) return;
    _snack('Проверяем оплату…', ok: true);
    _startPaymentPolling();
  }

  void _snack(String msg, {bool ok = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
      backgroundColor: ok ? _teal : DS.rose,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusSm)),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ));
  }

  // ── Build helpers ─────────────────────────────────────────────────────────

  String? _tariffBadge(TariffInfo t) {
    final n = _TariffRadioCard._cleanTariffName(t.name).toLowerCase();
    if (n.contains('безлимит') || n.contains('unlimit')) return 'РЕКОМЕНДУЕМ';
    return null;
  }

  static bool _isFamilyTariff(TariffInfo t) {
    final n = t.name.toLowerCase();
    return n.contains('семей') || n.contains('family');
  }

  /// Human-readable label for a period length in days.
  static String _daysLabel(int days) => pricing.periodDaysLabel(days);

  /// Find the period in [tariff] whose days match [days].
  /// Returns cheapest period as fallback.
  static TariffPeriod? _periodForDays(TariffInfo tariff, int days) =>
      pricing.periodForDays(tariff, days);

  /// All unique period-day values across a list of tariffs, sorted ascending.
  static List<int> _uniqueDays(List<TariffInfo> tariffs) =>
      pricing.uniqueDays(tariffs);

  /// Build the new-user radio-card + period-strip tariff section.
  Widget _buildNewUserTariffSection(
      List<TariffInfo> tariffs, bool isLoggedIn) {
    final days        = _uniqueDays(tariffs);
    final selDays     = _selectedPeriodDays ?? (days.isNotEmpty ? days.first : 30);
    final selTariffId = _selectedTariffId ?? tariffs.first.id;

    // Resolve buy-period for selected tariff + days
    final selTariff = tariffs.firstWhere(
        (t) => t.id == selTariffId, orElse: () => tariffs.first);
    final selPeriod = _periodForDays(selTariff, selDays);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Features banner
        const _FeaturesBanner(),
        const SizedBox(height: 18),

        // Period strip
        if (days.length > 1) ...[
          _PeriodStrip(
            days: days,
            selected: selDays,
            tariffs: tariffs,
            onChanged: (d) {
              final tariff = tariffs.firstWhere(
                  (t) => t.id == (_selectedTariffId ?? tariffs.first.id),
                  orElse: () => tariffs.first);
              final p = _periodForDays(tariff, d);
              setState(() {
                _selectedPeriodDays     = d;
                _selectedTariffPeriodId = p?.id;
              });
            },
          ),
          const SizedBox(height: 14),
        ],

        // Tariff radio cards
        for (int i = 0; i < tariffs.length; i++) ...[
          if (i > 0) const SizedBox(height: 24),
          AnimatedBuilder(
            animation: _entranceCtrl,
            builder: (_, child) {
              final v = _cardReveal(i, tariffs.length, _entranceCtrl.value);
              return Opacity(
                opacity: v,
                child: Transform.scale(
                  scale: 0.96 + 0.04 * v,
                  alignment: Alignment.topCenter,
                  child: child,
                ),
              );
            },
            child: _TariffRadioCard(
              tariff:      tariffs[i],
              selected:    tariffs[i].id == selTariffId,
              period:      _periodForDays(tariffs[i], selDays),
              badgeLabel:  _tariffBadge(tariffs[i]),
              onTap: () {
                final t = tariffs[i];
                final p = _periodForDays(t, selDays);
                setState(() {
                  _selectedTariffId       = t.id;
                  _selectedTariffPeriodId = p?.id;
                });
              },
            ),
          ),
        ],

        const SizedBox(height: 16),

        // Continue button
        _ActionBtn(
          loading: _purchasing,
          disabled: selPeriod == null,
          color: DS.violet,
          label: selPeriod != null
              ? 'Продолжить · ${selPeriod.priceRub.toStringAsFixed(0)} ₽'
              : isLoggedIn ? 'Продолжить' : 'Войти и продолжить',
          onTap: _onBuyTapped,
        ),

        const SizedBox(height: 8),
        const _Disclaimer(),
      ],
    );
  }

  /// Top-level wrapper for the 2-step change-tariff flow.
  Widget _buildChangeTariffSection(List<TariffInfo> tariffs, bool isLoggedIn) {
    return _checkoutMode
        ? _buildChangeTariffCheckout(tariffs)
        : _buildChangeTariffStep1(tariffs, isLoggedIn);
  }

  /// Step 1 — tariff selection (current tariff highlighted, others listed).
  Widget _buildChangeTariffStep1(List<TariffInfo> tariffs, bool isLoggedIn) {
    final sub     = meNotifier.value?.subscription;
    final subName = (sub?.planName ?? '').toLowerCase().trim();
    final available = subName.isNotEmpty
        ? tariffs.where((t) => t.name.toLowerCase().trim() != subName).toList()
        : tariffs;

    if (available.isEmpty) {
      return Padding(
        key: const ValueKey('change-step1'),
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Text('Другие тарифы не доступны',
              style: const TextStyle(color: _t2, fontSize: 14)),
        ),
      );
    }

    final selId = _changeTariffId ?? available.first.id;
    final selTariff = available.firstWhere(
        (t) => t.id == selId, orElse: () => available.first);
    final selPeriod = selTariff.cheapestPeriod;

    final isFamilySel = _isFamilyTariff(selTariff);
    final familyMin = selTariff.deviceLimit;
    final familyMax = familyMin + 3;
    if (_familyDeviceCount < familyMin) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => setState(() => _familyDeviceCount = familyMin));
    }
    final clampedDevices = _familyDeviceCount.clamp(familyMin, familyMax);
    final extraDevices   = isFamilySel ? (clampedDevices - familyMin) : 0;

    // Use tariff's own device_price_kopeks (per device / per month).
    // This is correct for both new-buy and change-tariff flows — unlike
    // _devicesPrices which contains a prorated upgrade price for the
    // *current* subscription and is meaningless here.
    final devPriceKop    = isFamilySel ? (selTariff.devicePriceKopeks ?? 0) : 0;
    final months1        = selPeriod?.months ?? 1;
    final extraPeriodRub = (extraDevices * devPriceKop / 100.0) * months1;
    final totalPeriodRub = selPeriod != null
        ? selPeriod.priceRub + extraPeriodRub
        : null;
    final totalPerMonthRub = (totalPeriodRub != null && months1 > 0)
        ? totalPeriodRub / months1
        : null;

    String buttonLabel;
    if (selPeriod == null) {
      buttonLabel = 'Перейти на «${_TariffRadioCard._cleanTariffName(selTariff.name)}»';
    } else {
      final price = totalPerMonthRub != null
          ? '${totalPerMonthRub.toStringAsFixed(0)} ₽/мес'
          : '';
      buttonLabel = 'Перейти на «${_TariffRadioCard._cleanTariffName(selTariff.name)}» · $price';
    }

    return Column(
      key: const ValueKey('change-step1'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'ДРУГИЕ ТАРИФЫ',
          style: TextStyle(
            color: _t2, fontSize: 10,
            fontWeight: FontWeight.w700, letterSpacing: 2.2,
          ),
        ),
        const SizedBox(height: 10),

        // Tariff cards
        for (int i = 0; i < available.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          AnimatedBuilder(
            animation: _entranceCtrl,
            builder: (_, child) {
              final v = _cardReveal(i, available.length, _entranceCtrl.value);
              return Opacity(
                opacity: v,
                child: Transform.scale(
                  scale: 0.96 + 0.04 * v,
                  alignment: Alignment.topCenter,
                  child: child,
                ),
              );
            },
            child: _TariffSelectCard(
              tariff:     available[i],
              selected:   available[i].id == selId,
              badgeLabel: _tariffBadge(available[i]),
              showStepper: available[i].id == selId && isFamilySel,
              deviceCount: clampedDevices,
              deviceMin:   familyMin,
              deviceMax:   familyMax,
              onTap: () {
                final t = available[i];
                setState(() {
                  _changeTariffId         = t.id;
                  _changeTariffPeriodId   = t.cheapestPeriod?.id;
                  _changeTariffCalcResult = null;
                  if (_isFamilyTariff(t)) {
                    _familyDeviceCount = t.deviceLimit;
                  }
                });
              },
              onDeviceDecrement: () {
                if (_familyDeviceCount > familyMin) {
                  HapticFeedback.selectionClick();
                  setState(() => _familyDeviceCount--);
                  if (_familyDeviceCount - familyMin > 0) {
                    _calcDevicesPrice(_familyDeviceCount - familyMin);
                  }
                }
              },
              onDeviceIncrement: () {
                if (_familyDeviceCount < familyMax) {
                  HapticFeedback.selectionClick();
                  setState(() => _familyDeviceCount++);
                  _calcDevicesPrice(_familyDeviceCount - familyMin);
                }
              },
            ),
          ),
        ],

        const SizedBox(height: 18),

        _ActionBtn(
          loading: false,
          disabled: selPeriod == null,
          color: DS.violet,
          label: buttonLabel,
          onTap: () {
            setState(() {
              _checkoutMode           = true;
              _changeTariffCalcResult = null;
              final p = selTariff.cheapestPeriod;
              if (p != null) {
                _changeTariffPeriodId  = p.id;
                _selectedPeriodDays    = p.days;
              }
            });
            _loadChangeTariffCalc();
          },
        ),

        const SizedBox(height: 6),
        Center(
          child: Text(
            'Выбор периода — на следующем шаге',
            style: const TextStyle(color: _t2, fontSize: 11),
          ),
        ),
        const SizedBox(height: 4),
        const _Disclaimer(),
      ],
    );
  }

  /// Step 2 — checkout: period selector + cost breakdown + pay button.
  Widget _buildChangeTariffCheckout(List<TariffInfo> tariffs) {
    final sub     = meNotifier.value?.subscription;
    final subName = (sub?.planName ?? '').toLowerCase().trim();
    final available = subName.isNotEmpty
        ? tariffs.where((t) => t.name.toLowerCase().trim() != subName).toList()
        : tariffs;

    final selId   = _changeTariffId ?? (available.isNotEmpty ? available.first.id : null);
    final selTariff = selId != null
        ? available.firstWhere((t) => t.id == selId,
            orElse: () => available.isNotEmpty ? available.first : tariffs.first)
        : (available.isNotEmpty ? available.first : tariffs.first);

    final periods  = selTariff.periods;
    final selPerId = _changeTariffPeriodId ?? (periods.isNotEmpty ? periods.first.id : null);
    final selPer   = selPerId != null
        ? periods.firstWhere((p) => p.id == selPerId,
            orElse: () => periods.isNotEmpty ? periods.first : throw StateError('no periods'))
        : (periods.isNotEmpty ? periods.first : null);

    final isFam          = _isFamilyTariff(selTariff);
    final familyMin      = selTariff.deviceLimit;
    final extraDevices   = isFam ? (_familyDeviceCount - familyMin).clamp(0, 99) : 0;

    // Correct device price: use tariff's own devicePriceKopeks (per device / per month),
    // NOT _devicesPrices which is a prorated upgrade price for the current subscription.
    final devPriceKop    = isFam ? (selTariff.devicePriceKopeks ?? 0) : 0;

    // Cost breakdown — periodBaseRub is the total price for the whole period
    final months         = selPer?.months ?? 1;
    final periodBaseRub  = selPer?.priceRub ?? 0.0;
    final extraMonthRub  = extraDevices * devPriceKop / 100.0;   // extra per month for all added devices
    final periodTotalRub = periodBaseRub + extraMonthRub * months;

    final balanceRub     = _options?.balanceRub ?? 0.0;
    final toPayRub       = _useBalance
        ? (periodTotalRub - balanceRub).clamp(0.0, double.infinity)
        : periodTotalRub;

    final calcResult  = _changeTariffCalcResult;

    return Column(
      key: const ValueKey('change-step2'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Tariff summary (with pencil to go back) ────────────────────────
        const Text(
          'ТАРИФ',
          style: TextStyle(
            color: _t2, fontSize: 10,
            fontWeight: FontWeight.w700, letterSpacing: 2.2,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: _premSurface,
            borderRadius: BorderRadius.circular(DS.radiusSm),
            border: Border.all(color: _b1),
          ),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Row(children: [
            Builder(builder: (context) {
              final (iconData, accent) = _TariffRadioCardState._tariffStyle(selTariff);
              return Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: PhosphorIcon(iconData, color: accent, size: 20),
                ),
              );
            }),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  _TariffRadioCard._cleanTariffName(selTariff.name),
                  style: const TextStyle(
                    color: _t0, fontSize: 15, fontWeight: FontWeight.w700),
                ),
                Text(
                  isFam
                      ? '${selTariff.trafficLimitGb == 0 ? 'Без лимита' : '${selTariff.trafficLimitGb} ГБ'} · $_familyDeviceCount устр.'
                      : '${selTariff.trafficLimitGb == 0 ? 'Без лимита' : '${selTariff.trafficLimitGb} ГБ'} · ${selTariff.deviceLimit} устр.',
                  style: const TextStyle(color: _t1, fontSize: 12),
                ),
              ]),
            ),
            GestureDetector(
              onTap: () => setState(() {
                _checkoutMode           = false;
                _changeTariffCalcResult = null;
              }),
              child: const Icon(Icons.edit_rounded, color: DS.violet, size: 18),
            ),
          ]),
        ),

        const SizedBox(height: 16),

        // ── Period selector ─────────────────────────────────────────────────
        if (periods.length > 1) ...[
          const Text(
            'ПЕРИОД',
            style: TextStyle(
              color: _t2, fontSize: 10,
              fontWeight: FontWeight.w700, letterSpacing: 2.2,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: _premSurface,
              borderRadius: BorderRadius.circular(DS.radiusSm),
              border: Border.all(color: _b1),
            ),
            padding: const EdgeInsets.all(4),
            child: Row(children: [
              for (int i = 0; i < periods.length; i++) ...[
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _changeTariffPeriodId   = periods[i].id;
                        _selectedPeriodDays     = periods[i].days;
                        _changeTariffCalcResult = null;
                      });
                      _loadChangeTariffCalc();
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: periods[i].id == selPerId
                            ? DS.violet
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Center(
                            child: Text(
                              _daysLabel(periods[i].days),
                              style: TextStyle(
                                color: periods[i].id == selPerId
                                    ? Colors.white
                                    : _t1,
                                fontSize: 11,
                                fontWeight: periods[i].id == selPerId
                                    ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                          ),
                          if (periods[i].discountPercent > 0)
                            Positioned(
                              top: -8, right: 2,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                  color: DS.emerald.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Text(
                                  '−${periods[i].discountPercent}%',
                                  style: const TextStyle(
                                    color: DS.emerald,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ]),
          ),
          const SizedBox(height: 16),
        ],

        // ── Cost breakdown ──────────────────────────────────────────────────
        const Text(
          'РАСЧЁТ',
          style: TextStyle(
            color: _t2, fontSize: 10,
            fontWeight: FontWeight.w700, letterSpacing: 2.2,
          ),
        ),
        const SizedBox(height: 8),
        Builder(builder: (context) {
          final discount     = selPer?.discountPercent ?? 0;
          final perMonthRub  = selPer?.pricePerMonthRub;     // null when months == 1
          final origTotalRub = selPer?.originalPriceRub ?? periodBaseRub;
          final discountAmt  = origTotalRub - periodBaseRub; // 0 if no discount

          return Container(
            decoration: BoxDecoration(
              color: _premSurface,
              borderRadius: BorderRadius.circular(DS.radiusSm),
              border: Border.all(color: _b1),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Column(children: [
              // ── Tariff base price rows ────────────────────────────────
              if (months > 1 && discount > 0 && perMonthRub != null) ...[
                // Зачёркнутая полная цена без скидки
                _BreakdownRow(
                  label: '${origTotalRub ~/ months} ₽/мес × $months мес',
                  value: '${origTotalRub.toStringAsFixed(0)} ₽',
                  strikethrough: true,
                ),
                const SizedBox(height: 4),
                // Скидка зелёным
                _BreakdownRow(
                  label: 'Скидка −$discount%',
                  value: '−${discountAmt.toStringAsFixed(0)} ₽',
                  accent: DS.emerald,
                ),
                const SizedBox(height: 4),
                // Тариф итого
                _BreakdownRow(
                  label: '${selTariff.deviceLimit} устр.',
                  value: '${periodBaseRub.toStringAsFixed(0)} ₽',
                ),
              ] else if (months > 1 && perMonthRub != null) ...[
                // Без скидки, но несколько месяцев
                _BreakdownRow(
                  label: '${perMonthRub.toStringAsFixed(0)} ₽/мес × $months мес',
                  value: '${periodBaseRub.toStringAsFixed(0)} ₽',
                ),
              ] else ...[
                // 1 месяц
                _BreakdownRow(
                  label: '1 месяц · ${selTariff.deviceLimit} устр.',
                  value: '${periodBaseRub.toStringAsFixed(0)} ₽',
                ),
              ],

              // ── Extra devices (family plan) ───────────────────────────
              if (extraDevices > 0 && devPriceKop > 0) ...[
                const SizedBox(height: 4),
                _BreakdownRow(
                  label: months > 1
                      ? '+$extraDevices устр. × ${devPriceKop ~/ 100} ₽ × $months мес'
                      : '+$extraDevices устр. · ${devPriceKop ~/ 100} ₽/мес',
                  value: '+${(extraMonthRub * months).toStringAsFixed(0)} ₽',
                ),
              ],

              // ── Balance deduction ─────────────────────────────────────
              if (_useBalance && balanceRub > 0) ...[
                const SizedBox(height: 4),
                _BreakdownRow(
                  label: 'Списано с баланса',
                  value: '−${balanceRub.toStringAsFixed(0)} ₽',
                  accent: DS.emerald,
                ),
              ],

              const SizedBox(height: 10),
              const Divider(height: 1, color: _b0),
              const SizedBox(height: 12),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  const Text('К оплате',
                      style: TextStyle(
                          color: _t0, fontSize: 14, fontWeight: FontWeight.w500)),
                  _changeTariffCalcLoading
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: DS.violet))
                      : Text(
                          '${(calcResult?.amountRub ?? toPayRub).toStringAsFixed(0)} ₽',
                          style: const TextStyle(
                            color: _t0, fontSize: 22, fontWeight: FontWeight.w700),
                        ),
                ],
              ),
            ]),
          );
        }),

        if (balanceRub > 0) ...[
          const SizedBox(height: 12),
          // Balance toggle
          _BalanceUsageToggle(
            balanceRub: balanceRub,
            enabled: _useBalance,
            onToggle: (v) => setState(() => _useBalance = v),
          ),
        ],

        const SizedBox(height: 16),

        _ActionBtn(
          loading: _purchasing || _changeTariffCalcLoading,
          disabled: selPer == null,
          color: DS.violet,
          label: 'Оплатить ${(calcResult?.amountRub ?? toPayRub).toStringAsFixed(0)} ₽',
          onTap: _onChangeTariffTapped,
        ),

        const SizedBox(height: 10),
        const _Disclaimer(),
      ],
    );
  }



  /// Renew section for active user. Uses tariff periods when available,
  /// falls back to legacy async calc otherwise.
  Widget _buildRenewContent(MeSubscription sub, List<TariffInfo> tariffs) {
    final subName  = (sub.planName ?? '').toLowerCase().trim();
    TariffInfo? cur;
    if (subName.isNotEmpty) {
      try { cur = tariffs.firstWhere((t) => t.name.toLowerCase().trim() == subName); }
      catch (_) {}
    }

    final balanceRub = _options?.balanceRub ?? 0.0;

    if (cur != null && cur.periods.isNotEmpty) {
      final selId = _renewTariffPeriodId ?? cur.periods.first.id;
      final sel   = cur.periods.firstWhere(
          (p) => p.id == selId, orElse: () => cur!.periods.first);

      final toPayRub = _useBalance
          ? (sel.priceRub - balanceRub).clamp(0.0, double.infinity)
          : sel.priceRub;

      return Column(
        key: const ValueKey('renew-tariff'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Карточка «У вас сейчас» — только для активных (expired уже видит _ExpiredCard)
          if (!sub.isExpired) ...[
            _CurrentTariffMini(sub: sub, tariffs: tariffs),
            const SizedBox(height: 18),
          ],

          for (int i = 0; i < cur.periods.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _TariffPeriodTile(
              period: cur.periods[i],
              selected: cur.periods[i].id == selId,
              onTap: () => setState(() => _renewTariffPeriodId = cur!.periods[i].id),
            ),
          ],

          if (balanceRub > 0) ...[
            const SizedBox(height: 14),
            _BalanceUsageToggle(
              balanceRub: balanceRub,
              enabled: _useBalance,
              onToggle: (v) => setState(() => _useBalance = v),
            ),
          ],
          const SizedBox(height: 14),
          _ActionBtn(
            loading: _purchasing,
            disabled: false,
            color: DS.violet,
            label: 'Оплатить ${toPayRub.toStringAsFixed(0)} ₽',
            onTap: _onRenewCurrentTariffTapped,
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.lock_rounded, size: 12, color: _t2),
              SizedBox(width: 4),
              Text('Безопасная оплата · YooKassa',
                  style: TextStyle(color: _t2, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 4),
          const _Disclaimer(),
        ],
      );
    }

    // Legacy fallback
    final opts = _options;
    if (opts == null) return const SizedBox.shrink();
    final selRenewKopeks = _renewPeriodId != null ? _renewPrices[_renewPeriodId] : null;
    final legacyPriceRub = selRenewKopeks != null ? selRenewKopeks / 100.0 : null;
    final legacyPayRub   = (_useBalance && legacyPriceRub != null)
        ? (legacyPriceRub - balanceRub).clamp(0.0, double.infinity)
        : legacyPriceRub;

    return Column(
      key: const ValueKey('renew-legacy'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!sub.isExpired) ...[
          _CurrentTariffMini(sub: sub, tariffs: tariffs),
          const SizedBox(height: 18),
        ],

        for (int i = 0; i < opts.periods.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _PeriodTile(
            period: opts.periods[i],
            selected: opts.periods[i].id == _renewPeriodId,
            priceKopeks: _renewPrices[opts.periods[i].id],
            months: _parseMonths(opts.periods[i].label),
            onTap: () => setState(() => _renewPeriodId = opts.periods[i].id),
          ),
        ],

        if (balanceRub > 0) ...[
          const SizedBox(height: 14),
          _BalanceUsageToggle(
            balanceRub: balanceRub,
            enabled: _useBalance,
            onToggle: (v) => setState(() => _useBalance = v),
          ),
        ],
        const SizedBox(height: 14),
        _ActionBtn(
          loading: _purchasing,
          disabled: _renewPeriodId == null || selRenewKopeks == null,
          color: DS.violet,
          label: legacyPayRub != null
              ? 'Оплатить ${legacyPayRub.toStringAsFixed(0)} ₽'
              : 'Продлить подписку',
          onTap: _onRenewTapped,
        ),
        const SizedBox(height: 10),
        const _Disclaimer(),
      ],
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final auth    = authStateNotifier.value;
    final sub     = meNotifier.value?.subscription;
    final expDate        = sub?.expireDate;
    final isDateExpired  = expDate != null && expDate.isBefore(DateTime.now());
    final isReserveGrace = sub?.isReserveGrace ?? false;
    final hasActivePaidSub =
        sub != null && sub.isActive && !sub.isTrial && !isDateExpired;

    // Expired: has a subscription (non-trial) that is no longer active.
    // Reserve-squad grace is its own state (handled separately below) even
    // though sub.isActive/isExpired already fold it in — we want the warm,
    // specific "temporary access" card here, not the generic expired one.
    final hasExpiredSub = sub != null && !sub.isTrial && !hasActivePaidSub && !isReserveGrace;

    // ── Tariff helpers ─────────────────────────────────────────────────────
    final tariffs      = _tariffs;
    final hasTariffs   = tariffs != null && tariffs.isNotEmpty;

    // (tariff selection is fully managed inside _TariffAccordionItem)

    return Scaffold(
      backgroundColor: DS.surface0,
      body: Stack(children: [

        // Ambient aurora background blobs
        const _Aurora(),

        RefreshIndicator(
          color: DS.violet,
          backgroundColor: _premSurface,
          onRefresh: _loadOptions,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // Header
              SliverToBoxAdapter(
                child: _Header(
                  isManage: hasActivePaidSub || hasExpiredSub,
                  isExpired: hasExpiredSub,
                  balanceRub: (auth.isLoggedIn && _options != null)
                      ? _options!.balanceRub : null,
                  currency: _options?.currency ?? 'RUB',
                ),
              ),

              SliverPadding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 120),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([

                    // ── Payment polling ─────────────────────────────────────
                    if (_pollingForPayment) ...[
                      const SizedBox(height: 20),
                      const _PollingCard(),

                    // ── Active subscriber ──────────────────────────────────
                    ] else if (hasActivePaidSub) ...[
                      _ActiveCard(sub: sub),
                      const SizedBox(height: 16),

                      if (hasTariffs) ...[
                        // ── Toggle: Продлить / Сменить тариф ────────────────
                        _ActionToggle(
                          selected: _showChangeTariff ? 1 : 0,
                          labels: const ['Продлить', 'Сменить тариф'],
                          onChanged: (i) {
                            setState(() {
                              _showChangeTariff       = i == 1;
                              _changeTariffCalcResult = null;
                              _checkoutMode           = false;
                            });
                          },
                        ),
                        const SizedBox(height: 16),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 320),
                          curve: Curves.easeInOutCubic,
                          alignment: Alignment.topCenter,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 240),
                            switchInCurve: Curves.easeOut,
                            switchOutCurve: Curves.easeIn,
                            layoutBuilder: (cur, prev) => Stack(
                              alignment: Alignment.topCenter,
                              children: [...prev, ?cur],
                            ),
                            transitionBuilder: (child, anim) =>
                                FadeTransition(opacity: anim, child: child),
                            child: _showChangeTariff
                                ? _buildChangeTariffSection(tariffs, auth.isLoggedIn)
                                : _buildRenewContent(sub, tariffs),
                          ),
                        ),

                      ] else ...[
                        // Legacy manage section (no tariffs configured)
                        _ManageSection(
                          sub: sub,
                          options: _options,
                          loading: _purchasing,
                          renewPeriodId: _renewPeriodId,
                          renewPrices:   _renewPrices,
                          bestRenewId: _bestPeriodId(_options ?? SubscriptionOptions(
                              hasSubscription: true, periods: [], balanceKopeks: 0,
                              balanceRub: 0, currency: 'RUB')),
                          onRenewPeriodChanged: (id) => setState(() => _renewPeriodId = id),
                          onRenewTap: _onRenewTapped,
                          trafficAvailable: _trafficTabAvailable,
                          topupPackages:    _topupPackages,
                          selectedTrafficGb: _selectedTrafficGb,
                          trafficPrices:    _trafficPrices,
                          onTrafficChanged: (gb) => setState(() => _selectedTrafficGb = gb),
                          onTrafficTap: () => _onUpgradeTapped(trafficAdd: _selectedTrafficGb),
                          devicesAvailable: _devicesTabAvailable,
                          devicesOpts:     _devicesOpts,
                          selectedDevicesAdd: _selectedDevicesAdd,
                          devicesPrices:   _devicesPrices,
                          onDevicesChanged: (v) => setState(() => _selectedDevicesAdd = v),
                          onDevicesTap: () => _onUpgradeTapped(devicesAdd: _selectedDevicesAdd),
                        ),
                      ],

                    // ── Expired subscriber (or on temporary reserve-squad
                    // grace, which reuses the same renew/tariff flow below —
                    // only the top card differs) ──────────────────────────
                    ] else if (hasExpiredSub || isReserveGrace) ...[
                      if (isReserveGrace)
                        _GraceCard(sub: sub!)
                      else
                        _ExpiredCard(sub: sub!),
                      const SizedBox(height: 12),
                      _PlanContextStrip(
                        sub: sub,
                        expired: true,
                        cheapestPriceLabel: () {
                          // Ищем тариф текущей подписки среди загруженных тарифов
                          final subName = (sub.planName ?? '').toLowerCase().trim();
                          TariffInfo? matchTariff;
                          if (subName.isNotEmpty) {
                            try {
                              matchTariff = tariffs?.firstWhere(
                                  (t) => t.name.toLowerCase().trim() == subName);
                            } catch (_) {}
                          }
                          final cheapest = matchTariff?.cheapestPeriod;
                          if (cheapest == null) return null;
                          final perMonth = cheapest.months > 1
                              ? '${(cheapest.priceRub / cheapest.months).round()} ₽/мес'
                              : '${cheapest.priceRub.round()} ₽/мес';
                          return perMonth;
                        }(),
                      ),
                      const SizedBox(height: 12),

                      // Скелетоны карточек, пока тарифы/опции загружаются
                      if (_loadingOptions && _options == null && !hasTariffs) ...[
                        const SkeletonTheme(
                          child: Column(children: [
                            TariffCardSkeleton(),
                            TariffCardSkeleton(),
                          ]),
                        ),
                        const SizedBox(height: 16),

                      ] else if (hasTariffs) ...[
                        _ActionToggle(
                          selected: _showChangeTariff ? 1 : 0,
                          labels: const ['Продлить', 'Сменить тариф'],
                          onChanged: (i) {
                            setState(() {
                              _showChangeTariff       = i == 1;
                              _changeTariffCalcResult = null;
                              _checkoutMode           = false;
                            });
                          },
                        ),
                        const SizedBox(height: 16),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 320),
                          curve: Curves.easeInOutCubic,
                          alignment: Alignment.topCenter,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 240),
                            switchInCurve: Curves.easeOut,
                            switchOutCurve: Curves.easeIn,
                            layoutBuilder: (cur, prev) => Stack(
                              alignment: Alignment.topCenter,
                              children: [...prev, ?cur],
                            ),
                            transitionBuilder: (child, anim) =>
                                FadeTransition(opacity: anim, child: child),
                            child: _showChangeTariff
                                ? _buildChangeTariffSection(tariffs, auth.isLoggedIn)
                                : _buildRenewContent(sub, tariffs),
                          ),
                        ),

                      ] else ...[
                        // Legacy: show plan picker (same as new user)
                        if (_options != null && _options!.periods.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          _PlanCard(
                            periods: _options!.periods,
                            selectedId: _selectedPeriodId,
                            bestId: _bestPeriodId(_options!),
                            onPeriodChanged: (id) => setState(() => _selectedPeriodId = id),
                          ),
                          const SizedBox(height: 16),
                          _BuyButton(
                            isLoggedIn: auth.isLoggedIn,
                            loading: _purchasing,
                            priceKopeks: _selectedPeriodId != null
                                ? _options!.periods
                                    .firstWhere((p) => p.id == _selectedPeriodId,
                                        orElse: () => _options!.periods.first)
                                    .basePriceKopeks
                                : null,
                            hasBalance: _options!.balanceKopeks >=
                                (_selectedPeriodId != null
                                    ? _options!.periods
                                        .firstWhere((p) => p.id == _selectedPeriodId,
                                            orElse: () => _options!.periods.first)
                                        .basePriceKopeks
                                    : 0),
                            onTap: _onBuyTapped,
                          ),
                          const SizedBox(height: 10),
                          const _Disclaimer(),
                        ],
                      ],

                    // ── New user ───────────────────────────────────────────
                    ] else ...[

                      // Trial CTA — shown above the plan list when the user
                      // still has their free pilot period available.
                      if (_trialAvailable && auth.isLoggedIn) ...[
                        const SizedBox(height: 4),
                        _TrialCta(
                          days: _trialDays,
                          loading: _activatingTrial,
                          onTap: _onActivateTrial,
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Loading — skeleton tariff cards
                      if (_loadingOptions && _options == null && !hasTariffs) ...[
                        const SizedBox(height: 12),
                        const SkeletonTheme(
                          child: Column(children: [
                            TariffCardSkeleton(),
                            TariffCardSkeleton(),
                            TariffCardSkeleton(),
                          ]),
                        ),

                      // ── Tariff flow: radio card list ─────────────────────
                      ] else if (hasTariffs) ...[
                        const SizedBox(height: 4),
                        _buildNewUserTariffSection(tariffs, auth.isLoggedIn),

                      // ── Legacy plan picker ───────────────────────────────
                      ] else if (_options != null && _options!.periods.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        _PlanCard(
                          periods: _options!.periods,
                          selectedId: _selectedPeriodId,
                          bestId: _bestPeriodId(_options!),
                          onPeriodChanged: (id) => setState(() => _selectedPeriodId = id),
                        ),
                        const SizedBox(height: 16),
                        _BuyButton(
                          isLoggedIn: auth.isLoggedIn,
                          loading: _purchasing,
                          priceKopeks: _selectedPeriodId != null
                              ? _options!.periods
                                  .firstWhere((p) => p.id == _selectedPeriodId,
                                      orElse: () => _options!.periods.first)
                                  .basePriceKopeks
                              : null,
                          hasBalance: _options!.balanceKopeks >=
                              (_selectedPeriodId != null
                                  ? _options!.periods
                                      .firstWhere((p) => p.id == _selectedPeriodId,
                                          orElse: () => _options!.periods.first)
                                      .basePriceKopeks
                                  : 0),
                          onTap: _onBuyTapped,
                        ),
                        const SizedBox(height: 10),
                        const _Disclaimer(),

                      // Not logged in
                      ] else if (!auth.isLoggedIn && !_loadingOptions) ...[
                        const SizedBox(height: 32),
                        _LoginCard(onLogin: () => showAuthBottomSheet(context)),

                      // Error
                      ] else if (!_loadingOptions) ...[
                        const SizedBox(height: 32),
                        _ErrorCard(onRetry: _loadOptions),
                      ],
                    ],
                  ]),
                ),
              ),
            ],
          ),
        ),

        // Success overlay
        if (_showSuccessOverlay)
          _SuccessOverlay(
            isUpgrade: meNotifier.value?.subscription?.isActive == true,
            onDismiss: () => setState(() => _showSuccessOverlay = false),
          ),
      ]),
    );
  }
}

