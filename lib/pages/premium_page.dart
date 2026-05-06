import 'dart:async';
import 'dart:math' show Random, cos, sin, pi;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/me_response.dart';
import '../services/auth_state.dart';
import '../services/me_service.dart';
import '../services/subscription_api_service.dart';
import '../widgets/telegram_login_button.dart';
import 'auth_bottom_sheet.dart';

// ── Shared helpers ───────────────────────────────────────────────────────────

/// Parses a period label into a month count.
/// Examples: "3 месяца" → 3, "1 год" → 12, "6 мес" → 6
int? _parseMonths(String label) {
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

/// Pluralises "день / дня / дней".
String _pluralDays(int n) {
  final abs = n.abs() % 100;
  final last = abs % 10;
  if (abs >= 11 && abs <= 19) return 'дней';
  if (last == 1) return 'день';
  if (last >= 2 && last <= 4) return 'дня';
  return 'дней';
}

// ═══════════════════════════════════════════════════════════════════════════
//  Palette  ·  "Signal Dark"  — independent design system
// ═══════════════════════════════════════════════════════════════════════════

abstract final class _C {
  // Surfaces
  static const bg      = Color(0xFF07070F);
  static const surface = Color(0xFF111124);
  // Card gradient — identical to Subscription page active-state hero card
  static const cg1     = Color(0xFF0D0B26);
  static const cg2     = Color(0xFF0A0820);

  // Brand
  static const indigo  = Color(0xFF7C6FF7);   // softer indigo/violet
  static const indigoB = Color(0xFF9D8FFF);
  static const indigoD = Color(0xFF4338CA);
  static const teal    = Color(0xFF2DD4BF);   // keep for "current" badge
  static const gold    = Color(0xFFD4A84B);   // metallic gold (premium tier)
  // ignore: unused_field
  static const goldDim = Color(0xFF9A7520);   // reserved for gradients
  static const silver  = Color(0xFF8B96AA);   // cool silver (basic tier)
  static const rose    = Color(0xFFF43F5E);

  // Legacy aliases (still used in chips / buttons)
  static const amber   = gold;
  static const sky     = Color(0xFF60A5FA);   // softer blue for traffic chip

  // Text
  static const t0 = Color(0xFFF0F0FF);
  static const t1 = Color(0xFF8892AA);
  static const t2 = Color(0xFF454565);

  // Borders
  static const b0 = Color(0xFF16162E);
  static const b1 = Color(0xFF1E1E38);

  // Radius
  static const r12 = 12.0;
  static const r16 = 16.0;
  static const r22 = 22.0;
}

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

  // ── Payment polling ────────────────────────────────────────────────────────
  Timer? _pollTimer;
  int    _pollAttempt        = 0;
  bool   _pollingForPayment  = false;
  bool   _pendingPaymentPoll = false;
  bool   _showSuccessOverlay = false;
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

  Future<void> _loadOptions() async {
    if (!mounted) return;
    if (_loadingOptions) { _pendingOptions = true; return; }
    _pendingOptions = false;
    setState(() => _loadingOptions = true);
    try {
      final futures = await Future.wait<dynamic>([
        SubscriptionApiService.getOptions(),
        SubscriptionApiService.getTariffs(),
      ]);
      final opts    = futures[0] as SubscriptionOptions?;
      final tariffs = futures[1] as List<TariffInfo>?;

      if (mounted) {
        setState(() {
          _options = opts;

          // ── Tariff catalog ──────────────────────────────────────────────
          if (tariffs != null && tariffs.isNotEmpty) {
            // Sort by cheapest period price ascending
            final sorted = [...tariffs]..sort((a, b) {
              final ap = a.cheapestPeriod?.priceKopeks ?? 0;
              final bp = b.cheapestPeriod?.priceKopeks ?? 0;
              return ap.compareTo(bp);
            });
            _tariffs = sorted;

            // Auto-select cheapest tariff for new-user buy flow
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
              // Default: always 1 month (cheapest period)
              _selectedTariffPeriodId =
                  selTariff.cheapestPeriod?.id ??
                  selTariff.periods.first.id;
            }

            // Init global period-days selector — default 1 month (cheapest)
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

            // Auto-select for change-tariff (active user) flow
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

            // Auto-select renew period for the current active tariff
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

          // ── Legacy flow ────────────────────────────────────────────────
          if (opts != null && opts.periods.isNotEmpty) {
            _selectedPeriodId ??= _bestPeriodId(opts) ?? opts.periods.first.id;
            if (_renewPeriodId == null && opts.periods.isNotEmpty) {
              _renewPeriodId = opts.periods.first.id;
            }
          }
        });
        if (opts != null) _initManagePrices(opts);
      }
    } catch (e) { debugPrint('PremiumPage._loadOptions: $e'); }
    if (mounted) setState(() => _loadingOptions = false);
    if (_pendingOptions && mounted) {
      _pendingOptions = false;
      _loadOptions();
    }
    // Staggered entrance: reveal accordion items one by one
    _triggerStaggeredEntrance();
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

  String? _bestPeriodId(SubscriptionOptions opts) {
    PeriodOption? best;
    for (final p in opts.periods) {
      if (p.discountPercent > 0 &&
          (best == null || p.discountPercent > best.discountPercent)) { best = p; }
    }
    return best?.id;
  }

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
    _pollTimer?.cancel();
    setState(() { _pollingForPayment = true; _pollAttempt = 0; });
    _pollTimer = Timer.periodic(_pollInterval, _onPollTick);
  }

  Future<void> _onPollTick(Timer timer) async {
    _pollAttempt++;
    await MeService.refresh();
    if (!mounted) { timer.cancel(); return; }
    final sub       = meNotifier.value?.subscription;
    final confirmed = sub != null && sub.isActive && !sub.isTrial;
    if (confirmed || _pollAttempt >= _maxPollAttempts) {
      timer.cancel(); _pollTimer = null;
      if (!mounted) return;
      setState(() => _pollingForPayment = false);
      if (confirmed) {
        await _loadOptions();
        if (mounted) _snack('Подписка активирована!', ok: true);
      } else {
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
      } catch (e) { if (mounted) _snack('Ошибка: $e'); }
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
    } catch (e) { if (mounted) _snack('Ошибка: $e'); }
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
        globalRefreshNotifier.notifyListeners();
        await _loadOptions();
        await Future.delayed(const Duration(milliseconds: 1800));
        if (mounted) setState(() => _showSuccessOverlay = false);
      } else if (r.requiresPayment && r.paymentUrl != null) {
        await _openPaymentUrl(r.paymentUrl!);
      } else { _snack(r.message ?? 'Ошибка при продлении'); }
    } catch (e) { if (mounted) _snack('Ошибка: $e'); }
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
        globalRefreshNotifier.notifyListeners();
        await _loadOptions();
        await Future.delayed(const Duration(milliseconds: 1800));
        if (mounted) setState(() => _showSuccessOverlay = false);
      } else if (r.requiresPayment && r.paymentUrl != null) {
        await _openPaymentUrl(r.paymentUrl!);
      } else { _snack(r.message ?? 'Ошибка при улучшении'); }
    } catch (e) { if (mounted) _snack('Ошибка: $e'); }
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
        globalRefreshNotifier.notifyListeners();
        await _loadOptions();
        await Future.delayed(const Duration(milliseconds: 1800));
        if (mounted) setState(() => _showSuccessOverlay = false);
      } else if (r.requiresPayment && r.paymentUrl != null) {
        await _openPaymentUrl(r.paymentUrl!);
      } else {
        _snack(r.message ?? 'Ошибка при смене тарифа');
      }
    } catch (e) { if (mounted) _snack('Ошибка: $e'); }
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
        globalRefreshNotifier.notifyListeners();
        await _loadOptions();
        await Future.delayed(const Duration(milliseconds: 1800));
        if (mounted) setState(() => _showSuccessOverlay = false);
      } else if (r.requiresPayment && r.paymentUrl != null) {
        await _openPaymentUrl(r.paymentUrl!);
      } else {
        _snack(r.message ?? 'Ошибка при продлении');
      }
    } catch (e) { if (mounted) _snack('Ошибка: $e'); }
    if (mounted) setState(() => _purchasing = false);
  }

  Future<void> _openPaymentUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (mounted) {
          _snack('Страница оплаты открыта. После оплаты вернитесь в приложение.', ok: true);
          _pendingPaymentPoll = true;
        }
      } else {
        if (mounted) _snack('Не удалось открыть страницу оплаты');
      }
    } catch (_) { if (mounted) _snack('Ошибка при открытии оплаты'); }
  }

  void _snack(String msg, {bool ok = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
      backgroundColor: ok ? _C.teal : _C.rose,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_C.r12)),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ));
  }

  // ── Build helpers ─────────────────────────────────────────────────────────

  /// Label for the "Сменить тариф" action button.
  /// Shows prorated price when loaded, "Бесплатно" for downgrades, or falls
  /// back to the tariff's full price while calc is pending.
  String _buildChangeTariffLabel(TariffPeriod? selPeriod) {
    if (selPeriod == null) return 'Сменить тариф';
    if (_changeTariffCalcLoading) return 'Сменить тариф…';
    final calc = _changeTariffCalcResult;
    if (calc != null) {
      if (calc.amountKopeks <= 0) return 'Сменить тариф · Бесплатно';
      return 'Сменить тариф · ${calc.amountRub.toStringAsFixed(0)} ₽';
    }
    // Calc not loaded yet — show the period's base price as a fallback.
    return 'Сменить тариф · ${selPeriod.priceRub.toStringAsFixed(0)} ₽';
  }

  String? _tariffBadge(TariffInfo t) {
    final n = _TariffRadioCard._cleanTariffName(t.name).toLowerCase();
    if (n.contains('безлимит') || n.contains('unlimit')) return 'РЕКОМЕНДУЕМ';
    return null;
  }

  /// Human-readable label for a period length in days.
  static String _daysLabel(int days) {
    if (days <= 31)  return '1 мес';
    if (days <= 62)  return '2 мес';
    if (days <= 93)  return '3 мес';
    if (days <= 124) return '4 мес';
    if (days <= 186) return '6 мес';
    if (days <= 366) return '1 год';
    return '${(days / 30).round()} мес';
  }

  /// Find the period in [tariff] whose days match [days].
  /// Returns cheapest period as fallback.
  static TariffPeriod? _periodForDays(TariffInfo tariff, int days) {
    if (tariff.periods.isEmpty) return null;
    try {
      return tariff.periods.firstWhere((p) => p.days == days);
    } catch (_) {
      return tariff.cheapestPeriod ?? tariff.periods.first;
    }
  }

  /// All unique period-day values across a list of tariffs, sorted ascending.
  static List<int> _uniqueDays(List<TariffInfo> tariffs) {
    return tariffs
        .expand((t) => t.periods.map((p) => p.days))
        .toSet()
        .toList()
      ..sort();
  }

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
          color: _C.indigo,
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

  /// Build change-tariff section (radio cards, current tariff excluded).
  Widget _buildChangeTariffRadioSection(
      List<TariffInfo> tariffs, bool isLoggedIn) {
    final subName = (meNotifier.value?.subscription?.planName ?? '').toLowerCase().trim();
    final available = subName.isNotEmpty
        ? tariffs.where((t) => t.name.toLowerCase().trim() != subName).toList()
        : tariffs;

    if (available.isEmpty) {
      return Padding(
        key: const ValueKey('change-radio'),
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Text('Другие тарифы не доступны',
              style: const TextStyle(color: _C.t2, fontSize: 14)),
        ),
      );
    }

    final days    = _uniqueDays(available);
    final selDays = _selectedPeriodDays ?? (days.isNotEmpty ? days.first : 30);
    final selId   = _changeTariffId ?? available.first.id;

    final selTariff = available.firstWhere(
        (t) => t.id == selId, orElse: () => available.first);
    final selPeriod = _periodForDays(selTariff, selDays);

    return Column(
      key: const ValueKey('change-radio'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Period strip
        if (days.length > 1) ...[
          _PeriodStrip(
            days: days,
            selected: selDays,
            tariffs: available,
            onChanged: (d) {
              final t = available.firstWhere(
                  (t) => t.id == (_changeTariffId ?? available.first.id),
                  orElse: () => available.first);
              final p = _periodForDays(t, d);
              setState(() {
                _selectedPeriodDays      = d;
                _changeTariffPeriodId    = p?.id;
                _changeTariffCalcResult  = null;
              });
              _loadChangeTariffCalc();
            },
          ),
          const SizedBox(height: 14),
        ],

        // Tariff radio cards
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
            child: _TariffRadioCard(
              tariff:     available[i],
              selected:   available[i].id == selId,
              period:     _periodForDays(available[i], selDays),
              badgeLabel: _tariffBadge(available[i]),
              onTap: () {
                final t = available[i];
                final p = _periodForDays(t, selDays);
                setState(() {
                  _changeTariffId          = t.id;
                  _changeTariffPeriodId    = p?.id;
                  _changeTariffCalcResult  = null;
                });
                _loadChangeTariffCalc();
              },
            ),
          ),
        ],

        const SizedBox(height: 16),

        // Continue button — label shows prorated price or "Бесплатно" for downgrades
        _ActionBtn(
          loading: _purchasing || _changeTariffCalcLoading,
          disabled: selPeriod == null,
          color: _C.indigo,
          label: _buildChangeTariffLabel(selPeriod),
          onTap: _onChangeTariffTapped,
        ),

        const SizedBox(height: 6),
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

    if (cur != null && cur.periods.isNotEmpty) {
      final selId = _renewTariffPeriodId ?? cur.periods.first.id;
      final sel   = cur.periods.firstWhere(
          (p) => p.id == selId, orElse: () => cur!.periods.first);

      return Column(
        key: const ValueKey('renew-tariff'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PSectionHeader(
              label: 'ПРОДЛИТЬ', icon: PhosphorIconsRegular.arrowsCounterClockwise),
          const SizedBox(height: 10),
          for (int i = 0; i < cur.periods.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _TariffPeriodTile(
              period: cur.periods[i],
              selected: cur.periods[i].id == selId,
              onTap: () => setState(() => _renewTariffPeriodId = cur!.periods[i].id),
            ),
          ],
          const SizedBox(height: 14),
          _ActionBtn(
            loading: _purchasing,
            disabled: false,
            color: _C.indigo,
            label: 'Продлить за ${sel.priceRub.toStringAsFixed(0)} ₽',
            onTap: _onRenewCurrentTariffTapped,
          ),
          const SizedBox(height: 6),
          const _Disclaimer(),
        ],
      );
    }

    // Legacy fallback
    final opts = _options;
    if (opts == null) return const SizedBox.shrink();
    final selRenewKopeks = _renewPeriodId != null ? _renewPrices[_renewPeriodId] : null;

    return Column(
      key: const ValueKey('renew-legacy'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PSectionHeader(
            label: 'ПРОДЛИТЬ', icon: PhosphorIconsRegular.arrowsCounterClockwise),
        const SizedBox(height: 10),
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
        const SizedBox(height: 14),
        _ActionBtn(
          loading: _purchasing,
          disabled: _renewPeriodId == null || selRenewKopeks == null,
          color: _C.indigo,
          label: selRenewKopeks != null
              ? 'Продлить за ${(selRenewKopeks / 100).toStringAsFixed(0)} ₽'
              : 'Продлить подписку',
          onTap: _onRenewTapped,
        ),
        const SizedBox(height: 6),
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
    final hasActivePaidSub =
        sub != null && sub.isActive && !sub.isTrial && !isDateExpired;

    // Expired: has a subscription (non-trial) that is no longer active
    final hasExpiredSub = sub != null && !sub.isTrial && !hasActivePaidSub;

    // ── Tariff helpers ─────────────────────────────────────────────────────
    final tariffs      = _tariffs;
    final hasTariffs   = tariffs != null && tariffs.isNotEmpty;

    // (tariff selection is fully managed inside _TariffAccordionItem)

    return Scaffold(
      backgroundColor: _C.bg,
      body: Stack(children: [

        // Ambient aurora background blobs
        const _Aurora(),

        RefreshIndicator(
          color: _C.indigo,
          backgroundColor: _C.surface,
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
                            });
                            if (i == 1) _loadChangeTariffCalc();
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
                                ? _buildChangeTariffRadioSection(tariffs, auth.isLoggedIn)
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

                    // ── Expired subscriber ────────────────────────────────
                    ] else if (hasExpiredSub) ...[
                      _ExpiredCard(sub: sub),
                      const SizedBox(height: 12),
                      _PlanContextStrip(sub: sub, expired: true),
                      const SizedBox(height: 12),

                      if (hasTariffs) ...[
                        _ActionToggle(
                          selected: _showChangeTariff ? 1 : 0,
                          labels: const ['Продлить', 'Сменить тариф'],
                          onChanged: (i) {
                            setState(() {
                              _showChangeTariff       = i == 1;
                              _changeTariffCalcResult = null;
                            });
                            if (i == 1) _loadChangeTariffCalc();
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
                                ? _buildChangeTariffRadioSection(tariffs, auth.isLoggedIn)
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

                      // Loading
                      if (_loadingOptions && _options == null && !hasTariffs) ...[
                        const SizedBox(height: 80),
                        const Center(child: CircularProgressIndicator(
                            color: _C.indigo, strokeWidth: 2.5)),

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

// ═══════════════════════════════════════════════════════════════════════════
//  Aurora background — ambient gradient blobs
// ═══════════════════════════════════════════════════════════════════════════

class _Aurora extends StatelessWidget {
  const _Aurora();

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: IgnorePointer(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF0D0A22),   // тёмно-фиолетовый сверху
              Color(0xFF07070F),   // нейтральный чёрный в центре
              Color(0xFF07070D),   // почти чёрный снизу
            ],
            stops: [0.0, 0.50, 1.0],
          ),
        ),
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Header
// ═══════════════════════════════════════════════════════════════════════════

class _Header extends StatelessWidget {
  final bool isManage;
  final bool isExpired;
  final double? balanceRub;
  final String currency;
  const _Header({
    required this.isManage,
    this.isExpired = false,
    this.balanceRub,
    this.currency = 'RUB',
  });

  @override
  Widget build(BuildContext context) {
    final String eyebrow;
    final String title;
    if (isExpired) {
      eyebrow = 'ПОДПИСКА';
      title   = 'Истекла';
    } else if (isManage) {
      eyebrow = 'УПРАВЛЕНИЕ';
      title   = 'Моя подписка';
    } else {
      eyebrow = 'ТАРИФ';
      title   = 'Выберите план';
    }

    final top = MediaQuery.of(context).padding.top;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, top + 22, 20, 10),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              eyebrow,
              style: const TextStyle(
                color: _C.t2, fontSize: 10,
                fontWeight: FontWeight.w700, letterSpacing: 2.5,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              title,
              style: TextStyle(
                color: isExpired ? _C.rose : _C.t0,
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.8,
                height: 1,
              ),
            ),
          ]),
        ),
        if (balanceRub != null) _BalanceChip(rub: balanceRub!, currency: currency),
      ]),
    );
  }
}

class _BalanceChip extends StatelessWidget {
  final double rub; final String currency;
  const _BalanceChip({required this.rub, required this.currency});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
    decoration: BoxDecoration(
      color: _C.surface,
      borderRadius: BorderRadius.circular(50),
      border: Border.all(color: _C.b1),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 7, height: 7,
        decoration: const BoxDecoration(color: _C.teal, shape: BoxShape.circle),
      ),
      const SizedBox(width: 7),
      Text(
        '${rub.toStringAsFixed(0)} $currency',
        style: const TextStyle(
            color: _C.t0, fontSize: 13, fontWeight: FontWeight.w700),
      ),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Action toggle — "Продлить / Сменить тариф" tab switcher
// ═══════════════════════════════════════════════════════════════════════════

class _ActionToggle extends StatelessWidget {
  final int selected;
  final List<String> labels;
  final ValueChanged<int> onChanged;
  const _ActionToggle({
    required this.selected,
    required this.labels,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Container(
    height: 48,
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: _C.surface,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: _C.b1),
    ),
    child: Row(children: [
      for (int i = 0; i < labels.length; i++)
        Expanded(
          child: GestureDetector(
            onTap: () => onChanged(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOutCubic,
              decoration: BoxDecoration(
                gradient: selected == i
                    ? const LinearGradient(
                        colors: [_C.indigo, _C.indigoD],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight)
                    : null,
                borderRadius: BorderRadius.circular(11),
                boxShadow: selected == i
                    ? [BoxShadow(
                        color: _C.indigo.withValues(alpha: 0.32),
                        blurRadius: 14, offset: const Offset(0, 3))]
                    : null,
              ),
              child: Center(
                child: Text(
                  labels[i],
                  style: TextStyle(
                    color: selected == i ? Colors.white : _C.t1,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Features banner — top "what you get" list
// ═══════════════════════════════════════════════════════════════════════════

class _FeaturesBanner extends StatefulWidget {
  const _FeaturesBanner();

  static const items = [
    (PhosphorIconsFill.youtubeLogo,        'YouTube без рекламы',           Color(0xFFFF4444)),
    (PhosphorIconsFill.gauge,              'Максимальная скорость',          Color(0xFFD4A84B)),
    (PhosphorIconsFill.globeHemisphereEast,'Серверы по всему миру',          Color(0xFF7C6FF7)),
    (PhosphorIconsFill.headset,            'Приоритетная поддержка 24/7',    Color(0xFF2DD4BF)),
  ];

  @override
  State<_FeaturesBanner> createState() => _FeaturesBannerState();
}

class _FeaturesBannerState extends State<_FeaturesBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  // 4 items × 60 ms stagger + 320 ms reveal = 500 ms total
  static const _staggerMs = 60.0;
  static const _revealMs  = 320.0;
  static const _n         = 4;      // == _FeaturesBanner.items.length
  static const _totalMs   = 500.0;  // (4−1)×60 + 320

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < _n; i++) ...[
              if (i > 0) const SizedBox(height: 14),
              Builder(builder: (_) {
                final start = (i * _staggerMs) / _totalMs;
                final end   = (i * _staggerMs + _revealMs) / _totalMs;
                final local = ((_ctrl.value - start) / (end - start)).clamp(0.0, 1.0);
                final v     = Curves.easeOutCubic.transform(local);
                return Opacity(
                  opacity: v,
                  child: Transform.scale(
                    scale: 0.97 + 0.03 * v,
                    alignment: Alignment.centerLeft,
                    child: _FeatureRow(
                      icon:  _FeaturesBanner.items[i].$1,
                      label: _FeaturesBanner.items[i].$2,
                      color: _FeaturesBanner.items[i].$3,
                    ),
                  ),
                );
              }),
            ],
          ],
        );
      },
    );
  }
}

class _FeatureRow extends StatelessWidget {
  final PhosphorIconData icon;
  final String label;
  final Color  color;
  const _FeatureRow({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Row(children: [
    // Circle background + icon
    Container(
      width: 42, height: 42,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        shape: BoxShape.circle,
      ),
      child: Center(child: PhosphorIcon(icon, color: color, size: 22)),
    ),
    const SizedBox(width: 14),
    Expanded(
      child: Text(label, style: const TextStyle(
          color: _C.t0, fontSize: 14, fontWeight: FontWeight.w600)),
    ),
  ]);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Period strip — horizontal pill selector ("1 мес / 3 мес / 1 год …")
// ═══════════════════════════════════════════════════════════════════════════

class _PeriodStrip extends StatelessWidget {
  final List<int>         days;
  final int               selected;
  final List<TariffInfo>  tariffs;   // to compute per-period discount hints
  final ValueChanged<int> onChanged;

  const _PeriodStrip({
    required this.days,
    required this.selected,
    required this.tariffs,
    required this.onChanged,
  });

  /// Max discount % across all tariffs for [d] days period.
  int _maxDiscount(int d) {
    int best = 0;
    for (final t in tariffs) {
      try {
        final p = t.periods.firstWhere((p) => p.days == d);
        if (p.discountPercent > best) best = p.discountPercent;
      } catch (_) {}
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'ПЕРИОД ПОДПИСКИ',
          style: TextStyle(
            color: _C.t2, fontSize: 10,
            fontWeight: FontWeight.w700, letterSpacing: 2.2,
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // extra top padding so discount badges (-N%) don't clip
          padding: const EdgeInsets.only(top: 10, bottom: 2),
          child: Row(
            children: [
              for (int i = 0; i < days.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                _PeriodPill(
                  label:    _PremiumPageState._daysLabel(days[i]),
                  discount: _maxDiscount(days[i]),
                  selected: days[i] == selected,
                  onTap: () => onChanged(days[i]),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _PeriodPill extends StatefulWidget {
  final String label;
  final int    discount;
  final bool   selected;
  final VoidCallback onTap;
  const _PeriodPill({
    required this.label,
    required this.discount,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_PeriodPill> createState() => _PeriodPillState();
}

class _PeriodPillState extends State<_PeriodPill> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown:  (_) => setState(() => _pressed = true),
      onTapUp:    (_) { widget.onTap(); setState(() => _pressed = false); },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.91 : 1.0,
        duration: _pressed
            ? const Duration(milliseconds: 80)
            : const Duration(milliseconds: 400),
        curve: _pressed ? Curves.easeIn : Curves.elasticOut,
        child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              gradient: widget.selected
                  ? const LinearGradient(
                      colors: [_C.indigo, _C.indigoD],
                      begin: Alignment.topLeft, end: Alignment.bottomRight)
                  : null,
              color: widget.selected ? null : _C.surface,
              borderRadius: BorderRadius.circular(50),
              border: Border.all(
                color: widget.selected ? _C.indigo : _C.b1,
                width: 1.5,
              ),
              boxShadow: widget.selected
                  ? [BoxShadow(
                      color: _C.indigo.withValues(alpha: 0.35),
                      blurRadius: 12, offset: const Offset(0, 3))]
                  : null,
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                color: widget.selected ? Colors.white : _C.t1,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          // Discount badge
          if (widget.discount > 0)
            Positioned(
              top: -8, right: -4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: _C.gold,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '-${widget.discount}%',
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 9, fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
        ],
      ),
    ));   // AnimatedScale
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Tariff radio card — compact row: icon | name+chips | price | radio
// ═══════════════════════════════════════════════════════════════════════════

class _TariffRadioCard extends StatefulWidget {
  final TariffInfo   tariff;
  final bool         selected;
  final TariffPeriod? period;
  final String?      badgeLabel;
  final VoidCallback onTap;

  const _TariffRadioCard({
    required this.tariff,
    required this.selected,
    required this.period,
    required this.onTap,
    this.badgeLabel,
  });

  static String _cleanTariffName(String name) =>
      name.replaceFirst(RegExp(r'^[^a-zA-Zа-яёА-ЯЁ]+'), '').trim();

  @override
  State<_TariffRadioCard> createState() => _TariffRadioCardState();
}

class _TariffRadioCardState extends State<_TariffRadioCard> {
  bool _pressed = false;

  static (PhosphorIconData, Color) _tariffStyle(TariffInfo t) {
    final n = _TariffRadioCard._cleanTariffName(t.name).toLowerCase();
    if (n.contains('семей') || n.contains('family')) {
      return (PhosphorIconsFill.usersThree, const Color(0xFF7C6FF7));
    }
    if (n.contains('безлимит') || n.contains('unlimit') || n.contains('безлим')) {
      return (PhosphorIconsFill.rocketLaunch, _C.gold);
    }
    if (n.contains('популяр') || n.contains('popular') || n.contains('стандарт')) {
      return (PhosphorIconsFill.fire, const Color(0xFFFF6B3D));
    }
    if (n.contains('базов') || n.contains('basic') || n.contains('старт') || n.contains('lite')) {
      return (PhosphorIconsFill.shieldCheck, _C.silver);
    }
    if (n.contains('бизнес') || n.contains('business') || n.contains('корпор')) {
      return (PhosphorIconsFill.crown, _C.gold);
    }
    // Tier fallback
    return switch (t.tierLevel) {
      >= 3 => (PhosphorIconsFill.crown,      _C.gold),
      2    => (PhosphorIconsFill.fire,        const Color(0xFFFF6B3D)),
      _    => (PhosphorIconsFill.shieldCheck, _C.silver),
    };
  }

  @override
  Widget build(BuildContext context) {
    final (iconData, accent) = _tariffStyle(widget.tariff);
    final price   = widget.period?.priceRub;
    final monthly = widget.period?.pricePerMonthRub;
    final selected = widget.selected;

    return AnimatedScale(
      scale: _pressed ? 0.97 : 1.0,
      duration: _pressed
          ? const Duration(milliseconds: 80)
          : const Duration(milliseconds: 260),
      curve: _pressed ? Curves.easeIn : Curves.easeOutCubic,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
        // ── Card body ─────────────────────────────────────────────────────
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOutCubic,
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.08)
                : _C.surface,
            borderRadius: BorderRadius.circular(_C.r16),
            border: Border.all(
              color: selected ? accent.withValues(alpha: 0.75) : _C.b1,
              width: 1.5,           // constant — no layout shift on select
            ),
            boxShadow: selected
                ? [BoxShadow(
                    color: accent.withValues(alpha: 0.20),
                    blurRadius: 22, offset: const Offset(0, 6))]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onHighlightChanged: (h) => setState(() => _pressed = h),
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(_C.r16),
              splashColor: accent.withValues(alpha: 0.08),
              highlightColor: accent.withValues(alpha: 0.04),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                child: Row(children: [

                  // ── Tier icon (no background, bare glow) ─────────────────
                  SizedBox(
                    width: 40,
                    child: Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        padding: const EdgeInsets.all(4),
                        decoration: selected
                            ? BoxDecoration(
                                shape: BoxShape.circle,
                                boxShadow: [BoxShadow(
                                  color: accent.withValues(alpha: 0.40),
                                  blurRadius: 14, spreadRadius: 0)],
                              )
                            : null,
                        child: PhosphorIcon(iconData, color: selected ? accent : accent.withValues(alpha: 0.55), size: 30),
                      ),
                    ),
                  ),
                  const SizedBox(width: 13),

                  // ── Name + feature chips ──────────────────────────────────
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _TariffRadioCard._cleanTariffName(widget.tariff.name),
                          style: TextStyle(
                            color: selected ? _C.t0 : _C.t1,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (widget.tariff.trafficLimitGb == 0)
                              _MiniPhosphorChip(
                                  icon: PhosphorIconsFill.infinity,
                                  label: 'Безлимит',
                                  color: _C.gold)
                            else
                              _MiniPhosphorChip(
                                  icon: PhosphorIconsRegular.database,
                                  label: 'Обход: ${widget.tariff.trafficLimitGb} ГБ',
                                  color: _C.sky),
                            const SizedBox(height: 4),
                            _MiniPhosphorChip(
                                icon: PhosphorIconsRegular.devices,
                                label: widget.tariff.deviceLabel,
                                color: _C.indigoB),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),

                  // ── Price column ──────────────────────────────────────────
                  if (price != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 88),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${price.toStringAsFixed(0)} ₽',
                            style: TextStyle(
                              color: selected ? accent : _C.t0,
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            monthly != null && widget.period!.days > 31
                                ? '~${monthly.round()} ₽/мес'
                                : '/мес',
                            style: const TextStyle(color: _C.t2, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(width: 10),

                  // ── Radio circle ──────────────────────────────────────────
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 22, height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? accent : Colors.transparent,
                      border: Border.all(
                        color: selected ? accent : _C.t2,
                        width: 2,
                      ),
                    ),
                    child: selected
                        ? Center(
                            child: Container(
                              width: 8, height: 8,
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                            ),
                          )
                        : null,
                  ),
                ]),
              ),
            ),
          ),
        ),

        // ── Badge chip floating above the card ───────────────────────────
        if (widget.badgeLabel != null)
          Positioned(
            top: -14,
            right: 18,
            child: _BadgeChip(label: widget.badgeLabel!, tier: widget.tariff.tierLevel),
          ),
      ],
      ),    // Stack
    );     // AnimatedScale
  }
}

// ── Phosphor chip (used in accordion header) ──────────────────────────────
class _MiniPhosphorChip extends StatelessWidget {
  final PhosphorIconData icon;
  final String label;
  final Color color;
  const _MiniPhosphorChip(
      {required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      PhosphorIcon(icon, size: 11, color: color),
      const SizedBox(width: 4),
      Text(label,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w700)),
    ]),
  );
}


// Tier badge chip (Популярный, Премиум, etc.)
class _BadgeChip extends StatefulWidget {
  final String label;
  final int tier;
  const _BadgeChip({required this.label, required this.tier});

  @override
  State<_BadgeChip> createState() => _BadgeChipState();
}

class _BadgeChipState extends State<_BadgeChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glow;

  @override
  void initState() {
    super.initState();
    _glow = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() { _glow.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    const c = _C.gold;
    // Solid dark pill — always legible regardless of card selection state
    // (gold-accent selected cards would swallow a translucent gold badge).
    return AnimatedBuilder(
      animation: _glow,
      builder: (_, child) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          // Near-black bg: maximum contrast on every card variant
          color: const Color(0xFF09091A),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: c.withValues(alpha: 0.55 + 0.45 * _glow.value),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: c.withValues(alpha: 0.12 + 0.28 * _glow.value),
              blurRadius: 8 + 10 * _glow.value,
              spreadRadius: 0,
            ),
          ],
        ),
        child: child,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('★ ',
              style: TextStyle(
                  color: _C.gold, fontSize: 8, height: 1.1)),
          Text(widget.label,
              style: const TextStyle(
                  color: Color(0xFFFFF8E7),   // warm white — readable on dark
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.6)),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Tariff period tile — animated selectable row (prices pre-loaded from model)
// ═══════════════════════════════════════════════════════════════════════════

class _TariffPeriodTile extends StatefulWidget {
  final TariffPeriod period;
  final bool selected;
  final VoidCallback onTap;

  const _TariffPeriodTile({
    required this.period,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_TariffPeriodTile> createState() => _TariffPeriodTileState();
}

class _TariffPeriodTileState extends State<_TariffPeriodTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final period     = widget.period;
    final selected   = widget.selected;
    final priceRub   = period.priceRub;
    final monthlyRub = period.pricePerMonthRub;
    final discount   = period.discountPercent;
    final origRub    = period.originalPriceRub;

    return GestureDetector(
      onTapDown:   (_) => setState(() => _pressed = true),
      onTapUp:     (_) { widget.onTap(); setState(() => _pressed = false); },
      onTapCancel: ()  => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.975 : 1.0,
        duration: _pressed
            ? const Duration(milliseconds: 70)
            : const Duration(milliseconds: 380),
        curve: _pressed ? Curves.easeIn : Curves.elasticOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            // Subtle gradient background when selected
            gradient: selected
                ? LinearGradient(
                    colors: [
                      _C.indigo.withValues(alpha: 0.14),
                      _C.indigoD.withValues(alpha: 0.06),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            color: selected ? null : _C.surface,
            borderRadius: BorderRadius.circular(_C.r12),
            border: Border.all(
              color: selected ? _C.indigo.withValues(alpha: 0.80) : _C.b1,
              width: selected ? 1.5 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                        color: _C.indigo.withValues(alpha: 0.20),
                        blurRadius: 18, offset: const Offset(0, 5)),
                    BoxShadow(
                        color: _C.indigo.withValues(alpha: 0.08),
                        blurRadius: 40, offset: const Offset(0, 10)),
                  ]
                : null,
          ),
          child: Row(children: [

            // ── Animated radio ─────────────────────────────────────────────
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 22, height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? _C.indigo : Colors.transparent,
                border: Border.all(
                  color: selected ? _C.indigo : _C.t2,
                  width: 2,
                ),
                boxShadow: selected
                    ? [BoxShadow(
                        color: _C.indigo.withValues(alpha: 0.45),
                        blurRadius: 8)]
                    : null,
              ),
              child: selected
                  ? const Center(
                      child: Icon(Icons.check_rounded, size: 13, color: Colors.white))
                  : null,
            ),

            const SizedBox(width: 14),

            // ── Period label + monthly hint ────────────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    period.label,
                    style: TextStyle(
                      color: selected ? _C.t0 : _C.t1,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (monthlyRub != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      '~${monthlyRub.round()} ₽/мес',
                      style: TextStyle(
                        color: selected
                            ? _C.indigoB.withValues(alpha: 0.85)
                            : _C.t2,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // ── Price column ───────────────────────────────────────────────
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (discount > 0)
                  Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      gradient: selected
                          ? const LinearGradient(
                              colors: [Color(0xFF2DD4BF), Color(0xFF059669)])
                          : null,
                      color: selected ? null : _C.teal.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '−$discount%',
                      style: TextStyle(
                        color: selected ? Colors.white : _C.teal,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                if (origRub != null)
                  Text(
                    '${origRub.toStringAsFixed(0)} ₽',
                    style: const TextStyle(
                      color: _C.t2, fontSize: 11,
                      decoration: TextDecoration.lineThrough,
                      decorationColor: _C.t2,
                    ),
                  ),
                Text(
                  '${priceRub.toStringAsFixed(0)} ₽',
                  style: TextStyle(
                    color: selected ? _C.indigoB : _C.t0,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Plan picker card  — for new users (legacy flow, no tariffs)
// ═══════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════
//  Plan purchase card — animated shimmer sweep + pulsing border glow.
//  The border oscillates between violet and gold (Itten pair) to draw the eye.
// ═══════════════════════════════════════════════════════════════════════════

class _PlanCard extends StatefulWidget {
  final List<PeriodOption> periods;
  final String? selectedId;
  final String? bestId;
  final ValueChanged<String> onPeriodChanged;

  const _PlanCard({
    required this.periods,
    required this.selectedId,
    required this.bestId,
    required this.onPeriodChanged,
  });

  @override
  State<_PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<_PlanCard> with TickerProviderStateMixin {
  // Diagonal shimmer sweep across the card surface
  late final AnimationController _shimmerCtrl;
  // Border glow pulse: violet ↔ gold (Itten complementary)
  late final AnimationController _glowCtrl;
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4200),
    )..repeat();
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
    _glow = CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _shimmerCtrl.dispose();
    _glowCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sel = widget.selectedId != null
        ? widget.periods.firstWhere(
            (p) => p.id == widget.selectedId,
            orElse: () => widget.periods.first)
        : widget.periods.first;
    final priceRub = sel.basePriceKopeks / 100;
    final origRub  = sel.originalPriceKopeks > sel.basePriceKopeks
        ? sel.originalPriceKopeks / 100 : null;
    final traffic  = _trafficLabel(sel);
    final devices  = _devicesLabel(sel);

    return AnimatedBuilder(
      animation: Listenable.merge([_shimmerCtrl, _glow]),
      builder: (_, child) {
        final g = _glow.value;
        return Stack(
          children: [
            // ── Main card ─────────────────────────────────────────────────
            Container(
              decoration: BoxDecoration(
                // Deep indigo gradient — same rich tone as Subscription hero card.
                gradient: const LinearGradient(
                  colors: [_C.cg1, _C.cg2],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(_C.r22),
                border: Border.all(
                  color: Color.lerp(
                    _C.indigo.withValues(alpha: 0.28),
                    _C.gold.withValues(alpha: 0.50),
                    g,
                  )!,
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: _C.indigo.withValues(alpha: 0.10 + g * 0.18),
                    blurRadius: 50 + g * 22,
                    offset: const Offset(0, 12),
                  ),
                  BoxShadow(
                    color: _C.gold.withValues(alpha: g * 0.10),
                    blurRadius: 28,
                    offset: Offset.zero,
                  ),
                ],
              ),
              child: Column(children: [

                // ── Period selector ────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
                  child: Row(children: [
                    for (int i = 0; i < widget.periods.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      Expanded(
                        child: _PeriodChip(
                          period: widget.periods[i],
                          selected: widget.periods[i].id == widget.selectedId,
                          isBest: widget.periods[i].id == widget.bestId,
                          onTap: () => widget.onPeriodChanged(widget.periods[i].id),
                        ),
                      ),
                    ],
                  ]),
                ),

                // ── Price block ────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 28, 22, 0),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (origRub != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(children: [
                              Text(
                                '${origRub.toStringAsFixed(0)} ₽',
                                style: const TextStyle(
                                  color: _C.t2,
                                  fontSize: 15,
                                  decoration: TextDecoration.lineThrough,
                                  decorationColor: _C.t2,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: _C.amber.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '−${sel.discountPercent}%',
                                  style: const TextStyle(
                                      color: _C.amber,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800),
                                ),
                              ),
                            ]),
                          ),
                        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250),
                            transitionBuilder: (child, anim) => FadeTransition(
                              opacity: anim,
                              child: SlideTransition(
                                position: Tween<Offset>(
                                    begin: const Offset(0, 0.15),
                                    end: Offset.zero)
                                    .animate(CurvedAnimation(
                                        parent: anim,
                                        curve: Curves.easeOut)),
                                child: child,
                              ),
                            ),
                            child: Text(
                              priceRub.toStringAsFixed(0),
                              key: ValueKey(sel.id),
                              style: const TextStyle(
                                color: _C.t0, fontSize: 68,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -3, height: 1,
                              ),
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.only(bottom: 10, left: 4),
                            child: Text('₽', style: TextStyle(
                                color: _C.t1,
                                fontSize: 24,
                                fontWeight: FontWeight.w700)),
                          ),
                        ]),
                        const SizedBox(height: 5),
                        Text(
                          'за период · ${sel.label.toLowerCase()}',
                          style: const TextStyle(color: _C.t2, fontSize: 13),
                        ),
                      ]),
                    ),
                  ]),
                ),

                Container(
                    margin: const EdgeInsets.fromLTRB(22, 20, 22, 0),
                    height: 1,
                    color: _C.b1),

                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
                  child: Row(children: [
                    _FeatureChip(
                        icon: Icons.bolt_rounded,
                        label: traffic,
                        color: _C.sky),
                    const SizedBox(width: 8),
                    _FeatureChip(
                        icon: Icons.devices_rounded,
                        label: devices,
                        color: _C.indigo),
                    const SizedBox(width: 8),
                    const _FeatureChip(
                        icon: Icons.verified_user_rounded,
                        label: 'Без логов',
                        color: _C.teal),
                  ]),
                ),
              ]),
            ),

            // ── Diagonal shimmer sweep overlay ─────────────────────────────
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_C.r22),
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment(
                          -2.5 + _shimmerCtrl.value * 5.0, -1.0),
                        end: Alignment(
                          -2.0 + _shimmerCtrl.value * 5.0, 1.0),
                        colors: [
                          Colors.transparent,
                          Colors.white.withValues(alpha: 0.04),
                          Colors.white.withValues(alpha: 0.09),
                          Colors.white.withValues(alpha: 0.04),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.3, 0.5, 0.7, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static String _trafficLabel(PeriodOption p) {
    final tCfg = p.traffic;
    if (tCfg == null) return '∞ ГБ';
    int? val = tCfg.defaultValue;
    if (val == null && tCfg.options.isNotEmpty) {
      val = tCfg.options
          .firstWhere((o) => o.isDefault, orElse: () => tCfg.options.first)
          .value;
    }
    if (val == null || val == 0) return '∞ ГБ';
    return '$val ГБ';
  }

  static String _devicesLabel(PeriodOption p) {
    final dCfg = p.devices;
    if (dCfg == null) return '1 устр.';
    final val = dCfg.defaultValue ?? dCfg.minimum;
    return '$val устр.';
  }
}

// Period chip — pulsing amber glow on the "best value" chip
class _PeriodChip extends StatefulWidget {
  final PeriodOption period;
  final bool selected, isBest;
  final VoidCallback onTap;
  const _PeriodChip({
    required this.period, required this.selected,
    required this.isBest, required this.onTap,
  });

  @override
  State<_PeriodChip> createState() => _PeriodChipState();
}

class _PeriodChipState extends State<_PeriodChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  late final Animation<double>   _glow;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _glow = CurvedAnimation(parent: _pulse, curve: Curves.easeInOut);
    if (widget.isBest) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_PeriodChip old) {
    super.didUpdateWidget(old);
    if (widget.isBest && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.isBest && _pulse.isAnimating) {
      _pulse.stop();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Non-best chips keep the simple AnimatedContainer transition
    if (!widget.isBest) {
      return GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            gradient: widget.selected
                ? const LinearGradient(
                    colors: [_C.indigo, _C.indigoD],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight)
                : null,
            color: widget.selected ? null : _C.b1,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: widget.selected
                  ? Colors.transparent
                  : _C.indigo.withValues(alpha: 0.22),
              width: 1.5,
            ),
            boxShadow: widget.selected
                ? [BoxShadow(
                    color: _C.indigo.withValues(alpha: 0.35),
                    blurRadius: 16,
                    offset: const Offset(0, 4))]
                : null,
          ),
          child: _label(),
        ),
      );
    }

    // Best chip — animated pulse on border + shadow
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _glow,
        builder: (_, child) {
          final g = _glow.value;
          return Container(
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(
              gradient: widget.selected
                  ? const LinearGradient(
                      colors: [_C.indigo, _C.indigoD],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight)
                  : null,
              color: widget.selected ? null : _C.b1,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: widget.selected
                    ? Colors.transparent
                    : _C.amber.withValues(alpha: 0.48 + g * 0.42),
                width: 1.5,
              ),
              boxShadow: [
                if (widget.selected)
                  BoxShadow(
                    color: _C.indigo.withValues(alpha: 0.35),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  )
                else
                  BoxShadow(
                    color: _C.amber.withValues(alpha: 0.14 + g * 0.28),
                    blurRadius: 10 + g * 14,
                    offset: const Offset(0, 2),
                  ),
              ],
            ),
            child: _label(),
          );
        },
      ),
    );
  }

  Widget _label() => Column(mainAxisSize: MainAxisSize.min, children: [
    Text(
      '★ ВЫГОДНО',
      style: TextStyle(
        color: widget.selected
            ? Colors.white.withValues(alpha: 0.8)
            : _C.amber,
        fontSize: 8,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.5,
      ),
    ),
    const SizedBox(height: 2),
    Text(
      widget.period.label,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: widget.selected ? Colors.white : _C.amber,
        fontSize: 13,
        fontWeight: FontWeight.w700,
      ),
    ),
  ]);
}

// Feature chip row item
class _FeatureChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _FeatureChip({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(_C.r12),
        border: Border.all(color: color.withValues(alpha: 0.32)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.12),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(height: 5),
        Text(
          label,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w700),
        ),
      ]),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Buy CTA button
// ═══════════════════════════════════════════════════════════════════════════

class _BuyButton extends StatelessWidget {
  final bool isLoggedIn, loading, hasBalance;
  final int? priceKopeks;   // null → "Выберите тариф"
  final VoidCallback onTap;
  const _BuyButton({
    required this.isLoggedIn, required this.loading,
    required this.hasBalance, required this.priceKopeks,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final needPay = isLoggedIn && !hasBalance && (priceKopeks ?? 0) > 0;
    final color   = needPay ? _C.teal : _C.indigo;

    final String label;
    if (loading) {
      label = '';
    } else if (!isLoggedIn) {
      label = 'Войти через Telegram';
    } else if (priceKopeks == null) {
      label = 'Выберите тариф';
    } else if (needPay) {
      final rub = (priceKopeks! / 100).toStringAsFixed(0);
      label = 'Оплатить $rub ₽';
    } else {
      final rub = (priceKopeks! / 100).toStringAsFixed(0);
      label = 'Подключить за $rub ₽';
    }

    return GestureDetector(
      onTap: loading ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 62,
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [color, Color.lerp(color, Colors.black, 0.28)!],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(_C.r16),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: loading ? 0.12 : 0.38),
              blurRadius: 28, offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Center(
          child: loading
              ? const SizedBox(
                  width: 24, height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  if (!isLoggedIn)
                    const Icon(Icons.telegram_rounded, color: Colors.white, size: 20)
                  else
                    PhosphorIcon(PhosphorIconsBold.shieldCheck,
                        color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                  Text(label, style: const TextStyle(
                      color: Colors.white, fontSize: 17,
                      fontWeight: FontWeight.w700, letterSpacing: 0.1)),
                ]),
        ),
      ),
    );
  }
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context) => const Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(Icons.lock_outline_rounded, size: 11, color: _C.t2),
      SizedBox(width: 5),
      Text('Безопасная оплата · YooKassa',
          style: TextStyle(color: _C.t2, fontSize: 11)),
    ],
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Subscription status band (replaces the old large _ActiveCard)
//
//  Design: Itten complementary pair — cool indigo base + warm gold accent.
//  Compact horizontal strip so the action section (renew/change) is the focus.
// ═══════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════
//  Active membership card — compact context banner.
//  Full subscription stats live on the Subscription page; here we show only
//  the key membership signal (status + plan + days) before the action buttons.
//  Background #1C1A3A is visibly brighter than aurora #0D0A22.
// ═══════════════════════════════════════════════════════════════════════════

class _ActiveCard extends StatelessWidget {
  final MeSubscription sub;
  const _ActiveCard({required this.sub});

  @override
  Widget build(BuildContext context) {
    final expDate  = sub.expireDate;
    final daysLeft = expDate?.difference(DateTime.now()).inDays;
    final planName = sub.planName ?? (sub.isTrial ? 'Пробный' : 'Premium');

    // Urgency palette: calm gold → warm amber → alert rose
    final Color accent = daysLeft == null || daysLeft > 7
        ? _C.gold
        : daysLeft > 3
            ? const Color(0xFFFBBF24)
            : _C.rose;

    // Badge colour: teal for a healthy active sub (green = "all OK" signal).
    // Trial and urgency states keep the urgency accent.
    final Color badgeColor = (!sub.isTrial && accent == _C.gold)
        ? _C.teal
        : accent;

    final String daysLabel = daysLeft == null
        ? '—'
        : daysLeft >= 0
            ? '$daysLeft ${_pluralDays(daysLeft)}'
            : 'истекла';

    final String expiryLabel = expDate == null
        ? '—'
        : '${expDate.day.toString().padLeft(2, '0')}'
          '.${expDate.month.toString().padLeft(2, '0')}'
          '.${expDate.year}';

    return Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_C.r16),
        gradient: const LinearGradient(
          colors: [_C.cg1, _C.cg2],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: accent.withValues(alpha: 0.30),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.16),
            blurRadius: 32,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

        // ── Top stripe — animated shimmer (Itten: gold ↔ violet) ───────────
        _ShimmerStripe(leading: accent, trailing: _C.indigo),

        // ── Main row: status pill + plan name + days remaining ────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: badgeColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: badgeColor.withValues(alpha: 0.35)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _PulsingDot(color: badgeColor),
                const SizedBox(width: 5),
                Text(
                  sub.isTrial ? 'ПРОБНЫЙ' : 'АКТИВНА',
                  style: TextStyle(
                    color: badgeColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ]),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                planName,
                style: const TextStyle(
                  color: _C.t0, fontSize: 14, fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              daysLabel,
              style: TextStyle(
                color: accent, fontSize: 14, fontWeight: FontWeight.w700,
              ),
            ),
          ]),
        ),

        // ── Bottom row: expiry + autopay ──────────────────────────────────
        Container(height: 1, color: _C.b0),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 9, 16, 11),
          child: Row(children: [
            PhosphorIcon(PhosphorIconsRegular.calendarBlank,
                color: accent, size: 13),
            const SizedBox(width: 5),
            Text(
              'до $expiryLabel',
              style: TextStyle(
                color: accent, fontSize: 12, fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            PhosphorIcon(
              PhosphorIconsRegular.arrowsClockwise,
              color: sub.autopayEnabled ? _C.teal : _C.t2,
              size: 13,
            ),
            const SizedBox(width: 5),
            Text(
              sub.autopayEnabled ? 'Автопродление' : 'Без автопродления',
              style: TextStyle(
                color: sub.autopayEnabled ? _C.teal : _C.t2, fontSize: 12,
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Expired subscription band
// ═══════════════════════════════════════════════════════════════════════════

class _ExpiredCard extends StatelessWidget {
  final MeSubscription sub;
  const _ExpiredCard({required this.sub});

  @override
  Widget build(BuildContext context) {
    final planName  = sub.planName ?? 'Premium';
    final expiredAt = sub.formattedExpiry;

    return Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_C.r16),
        gradient: const LinearGradient(
          colors: [Color(0xFF1A0A0E), Color(0xFF110810)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border(
          left:   BorderSide(color: _C.rose, width: 3),
          top:    BorderSide(color: _C.rose.withValues(alpha: 0.15)),
          right:  BorderSide(color: _C.rose.withValues(alpha: 0.15)),
          bottom: BorderSide(color: _C.rose.withValues(alpha: 0.15)),
        ),
        boxShadow: [
          BoxShadow(
            color: _C.rose.withValues(alpha: 0.08),
            blurRadius: 20, offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(children: [
          PhosphorIcon(PhosphorIconsFill.warningCircle,
              color: _C.rose, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(planName,
                    style: const TextStyle(
                        color: _C.t1, fontSize: 15,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text('истекла $expiredAt',
                    style: const TextStyle(
                        color: _C.t2, fontSize: 12)),
              ],
            ),
          ),
          _MiniChip(label: 'Доступ закрыт', color: _C.rose, bordered: true),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Plan context strip — sits between status card and ActionToggle.
//  Active: shows exact expiry date + autopay state.
//  Expired: shows what the plan included (context for renewal decision).
// ═══════════════════════════════════════════════════════════════════════════

class _PlanContextStrip extends StatelessWidget {
  final MeSubscription sub;
  final bool expired;
  const _PlanContextStrip({required this.sub, this.expired = false});

  @override
  Widget build(BuildContext context) {
    if (expired) {
      // "What you had" — context for renewal
      final planName = sub.planName;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Wrap(
          spacing: 14,
          runSpacing: 6,
          children: [
            if (planName != null && planName.isNotEmpty)
              _CtxItem(
                icon: PhosphorIconsRegular.sparkle,
                label: planName,
                color: _C.t1,
              ),
            _CtxItem(
              icon: PhosphorIconsRegular.devices,
              label: '${sub.deviceLimit} ${_devWord(sub.deviceLimit)}',
              color: _C.t2,
            ),
            _CtxItem(
              icon: PhosphorIconsRegular.database,
              label: sub.trafficLimitGb == 0
                  ? 'безлимит'
                  : '${sub.trafficLimitGb} ГБ',
              color: _C.t2,
            ),
          ],
        ),
      );
    }

    // Active: exact expiry + autopay status
    final expDate  = sub.expireDate;
    final daysLeft = expDate?.difference(DateTime.now()).inDays;
    final urgency  = (daysLeft != null && daysLeft <= 7) ? _C.rose
                   : (daysLeft != null && daysLeft <= 30) ? const Color(0xFFFBBF24)
                   : _C.gold;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Wrap(
        spacing: 14,
        runSpacing: 6,
        children: [
          if (expDate != null)
            _CtxItem(
              icon: PhosphorIconsRegular.calendarCheck,
              label: 'до ${sub.formattedExpiry}',
              color: urgency,
            ),
          _CtxItem(
            icon: sub.autopayEnabled
                ? PhosphorIconsFill.arrowsClockwise
                : PhosphorIconsRegular.arrowsClockwise,
            label: sub.autopayEnabled ? 'Автопродление' : 'Без автопродления',
            color: sub.autopayEnabled ? _C.teal : _C.t2,
          ),
        ],
      ),
    );
  }

  static String _devWord(int n) {
    final m10 = n % 10, m100 = n % 100;
    if (m100 >= 11 && m100 <= 19) return 'устройств';
    if (m10 == 1) return 'устройство';
    if (m10 >= 2 && m10 <= 4) return 'устройства';
    return 'устройств';
  }
}

// One icon + label pair used in _PlanContextStrip
class _CtxItem extends StatelessWidget {
  final PhosphorIconData icon;
  final String           label;
  final Color            color;
  const _CtxItem({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      PhosphorIcon(icon, color: color.withValues(alpha: 0.80), size: 13),
      const SizedBox(width: 5),
      Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          height: 1,
        ),
      ),
    ],
  );
}

// Small reusable chip used in the status bands above
class _MiniChip extends StatelessWidget {
  final String label;
  final Color  color;
  final bool   bordered;
  const _MiniChip({
    required this.label,
    required this.color,
    this.bordered = false,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(8),
      border: bordered
          ? Border.all(color: color.withValues(alpha: 0.30))
          : null,
    ),
    child: Text(
      label,
      style: TextStyle(
          color: color, fontSize: 11, fontWeight: FontWeight.w700),
    ),
  );
}

class _TrafficBar extends StatefulWidget {
  final double fraction;
  const _TrafficBar({required this.fraction});

  @override
  State<_TrafficBar> createState() => _TrafficBarState();
}

class _TrafficBarState extends State<_TrafficBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _ctrl.forward();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _anim,
    builder: (context, child) {
      final v = _anim.value * widget.fraction;
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Container(
          height: 7,
          color: _C.b1,
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: v.clamp(0.0, 1.0),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: v > 0.85
                      ? [_C.amber, _C.rose]
                      : [_C.teal, _C.sky],
                ),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
        ),
      );
    },
  );
}

// ── Animated shimmer stripe — white flash sweeping left → right ──────────────

class _ShimmerStripe extends StatefulWidget {
  final Color leading;   // e.g. gold / amber / rose (urgency accent)
  final Color trailing;  // e.g. violet (brand colour)
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
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
    _scale = Tween<double>(begin: 0.7, end: 1.3)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => ScaleTransition(
    scale: _scale,
    child: Container(
      width: 7, height: 7,
      decoration: BoxDecoration(
        color: widget.color,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(
            color: widget.color.withValues(alpha: 0.7), blurRadius: 5)],
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Manage section — renew / traffic / devices
// ═══════════════════════════════════════════════════════════════════════════

class _ManageSection extends StatelessWidget {
  final MeSubscription sub;
  final SubscriptionOptions? options;
  final bool loading;

  // Renew
  final String? renewPeriodId;
  final String? bestRenewId;
  final Map<String, int?> renewPrices;
  final ValueChanged<String> onRenewPeriodChanged;
  final VoidCallback onRenewTap;

  // Traffic
  final bool trafficAvailable;
  final List<TrafficTopupPackage> topupPackages;
  final int? selectedTrafficGb;
  final Map<int, int?> trafficPrices;
  final ValueChanged<int> onTrafficChanged;
  final VoidCallback onTrafficTap;

  // Devices
  final bool devicesAvailable;
  final List<int> devicesOpts;
  final int? selectedDevicesAdd;
  final Map<int, int?> devicesPrices;
  final ValueChanged<int> onDevicesChanged;
  final VoidCallback onDevicesTap;

  const _ManageSection({
    required this.sub,
    required this.options,
    required this.loading,
    required this.renewPeriodId,
    required this.bestRenewId,
    required this.renewPrices,
    required this.onRenewPeriodChanged,
    required this.onRenewTap,
    required this.trafficAvailable,
    required this.topupPackages,
    required this.selectedTrafficGb,
    required this.trafficPrices,
    required this.onTrafficChanged,
    required this.onTrafficTap,
    required this.devicesAvailable,
    required this.devicesOpts,
    required this.selectedDevicesAdd,
    required this.devicesPrices,
    required this.onDevicesChanged,
    required this.onDevicesTap,
  });

  @override
  Widget build(BuildContext context) {
    if (options == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.only(top: 40),
          child: CircularProgressIndicator(color: _C.indigo, strokeWidth: 2.5),
        ),
      );
    }

    final selRenewKopeks = renewPeriodId != null ? renewPrices[renewPeriodId] : null;

    final devicesAllFree = devicesOpts.isNotEmpty &&
        devicesPrices.values.isNotEmpty &&
        devicesPrices.values.every((p) => p != null && p == 0);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

      // ── RENEW ──────────────────────────────────────────────────────────────
      _SectionHeader(label: 'ПРОДЛИТЬ', icon: Icons.refresh_rounded),
      const SizedBox(height: 10),
      for (int i = 0; i < options!.periods.length; i++) ...[
        if (i > 0) const SizedBox(height: 8),
        _PeriodTile(
          period: options!.periods[i],
          selected: options!.periods[i].id == renewPeriodId,
          priceKopeks: renewPrices[options!.periods[i].id],
          months: _parseMonths(options!.periods[i].label),
          onTap: () => onRenewPeriodChanged(options!.periods[i].id),
        ),
      ],
      const SizedBox(height: 14),
      _ActionBtn(
        loading: loading,
        disabled: renewPeriodId == null || selRenewKopeks == null,
        color: _C.indigo,
        label: selRenewKopeks != null
            ? 'Продлить за ${(selRenewKopeks / 100).toStringAsFixed(0)} ₽'
            : 'Продлить подписку',
        onTap: onRenewTap,
      ),

      // ── TRAFFIC ────────────────────────────────────────────────────────────
      if (trafficAvailable && topupPackages.isNotEmpty) ...[
        const SizedBox(height: 24),
        _SectionHeader(label: 'ДОКУПИТЬ ТРАФИК', icon: Icons.data_usage_rounded),
        const SizedBox(height: 12),
        _HorizontalOptionRow(
          items: topupPackages.map((p) {
            final k = trafficPrices[p.gb];
            return _OptionItem(
              id: p.gb.toString(),
              topLabel: '+${p.gb} ГБ',
              bottomLabel: k == null ? '…' : (k == 0 ? 'Бесп.' : '${(k / 100).toStringAsFixed(0)} ₽'),
              selected: p.gb == selectedTrafficGb,
              accentColor: _C.sky,
            );
          }).toList(),
          onSelect: (id) => onTrafficChanged(int.parse(id)),
        ),
        const SizedBox(height: 14),
        _ActionBtn(
          loading: loading,
          disabled: selectedTrafficGb == null || trafficPrices[selectedTrafficGb] == null,
          color: _C.sky,
          label: selectedTrafficGb != null && trafficPrices[selectedTrafficGb] != null
              ? 'Добавить $selectedTrafficGb ГБ за ${(trafficPrices[selectedTrafficGb]! / 100).toStringAsFixed(0)} ₽'
              : 'Добавить трафик',
          onTap: onTrafficTap,
        ),
      ],

      // ── DEVICES ────────────────────────────────────────────────────────────
      if (devicesAvailable && devicesOpts.isNotEmpty && !devicesAllFree) ...[
        const SizedBox(height: 24),
        _SectionHeader(label: 'УСТРОЙСТВА', icon: Icons.devices_rounded),
        const SizedBox(height: 12),
        _HorizontalOptionRow(
          items: devicesOpts.map((add) {
            final target = sub.deviceLimit + add;
            final k      = devicesPrices[add];
            return _OptionItem(
              id: add.toString(),
              topLabel: '+$add устр.',
              bottomLabel: k == null ? '…' : (k == 0 ? 'Бесп.' : '${(k / 100).toStringAsFixed(0)} ₽'),
              subLabel: '${sub.deviceLimit}→$target',
              selected: add == selectedDevicesAdd,
              accentColor: _C.indigoB,
            );
          }).toList(),
          onSelect: (id) => onDevicesChanged(int.parse(id)),
        ),
        const SizedBox(height: 14),
        _ActionBtn(
          loading: loading,
          disabled: selectedDevicesAdd == null || devicesPrices[selectedDevicesAdd] == null,
          color: _C.indigoB,
          label: selectedDevicesAdd != null && devicesPrices[selectedDevicesAdd] != null
              ? 'Добавить $selectedDevicesAdd устр. за ${(devicesPrices[selectedDevicesAdd]! / 100).toStringAsFixed(0)} ₽'
              : 'Добавить устройства',
          onTap: onDevicesTap,
        ),
      ],

      const SizedBox(height: 6),
      const _Disclaimer(),
    ]);
  }

}

// ═══════════════════════════════════════════════════════════════════════════
//  Period tile — full-width selectable row (used in manage/renew, prices async)
// ═══════════════════════════════════════════════════════════════════════════

class _PeriodTile extends StatelessWidget {
  final PeriodOption period;
  final bool selected;
  final int? priceKopeks;
  final int? months;
  final VoidCallback onTap;

  const _PeriodTile({
    required this.period,
    required this.selected,
    required this.priceKopeks,
    required this.months,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final priceRub   = priceKopeks != null ? priceKopeks! / 100 : null;
    final monthlyRub = (months != null && months! > 1 && priceRub != null)
        ? priceRub / months!
        : null;
    final discount   = period.discountPercent;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected
              ? _C.indigo.withValues(alpha: 0.10)
              : _C.surface,
          borderRadius: BorderRadius.circular(_C.r12),
          border: Border.all(
            color: selected ? _C.indigo : _C.b1,
            width: selected ? 1.5 : 1,
          ),
          boxShadow: selected
              ? [BoxShadow(
                  color: _C.indigo.withValues(alpha: 0.15),
                  blurRadius: 14, offset: const Offset(0, 4))]
              : null,
        ),
        child: Row(children: [

          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 20, height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? _C.indigo : Colors.transparent,
              border: Border.all(
                color: selected ? _C.indigo : _C.t2,
                width: 2,
              ),
            ),
            child: selected
                ? const Center(
                    child: Icon(Icons.check_rounded, size: 11, color: Colors.white))
                : null,
          ),

          const SizedBox(width: 14),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  period.label,
                  style: TextStyle(
                    color: selected ? _C.t0 : _C.t1,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (monthlyRub != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    '~${monthlyRub.round()} ₽/мес',
                    style: TextStyle(
                      color: selected
                          ? _C.indigo.withValues(alpha: 0.75)
                          : _C.t2,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),

          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (discount > 0)
                Container(
                  margin: const EdgeInsets.only(bottom: 5),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _C.teal.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _C.teal.withValues(alpha: 0.30),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    '−$discount%',
                    style: const TextStyle(
                      color: _C.teal,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              if (priceRub != null)
                Text(
                  '${priceRub.toStringAsFixed(0)} ₽',
                  style: TextStyle(
                    color: selected ? _C.indigo : _C.t0,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                )
              else
                const SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: _C.t2)),
            ],
          ),
        ]),
      ),
    );
  }
}

// Section header
class _SectionHeader extends StatelessWidget {
  final String label;
  final IconData icon;
  const _SectionHeader({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) => Row(children: [
    Icon(icon, color: _C.t2, size: 13),
    const SizedBox(width: 7),
    Text(label, style: const TextStyle(
        color: _C.t2, fontSize: 10,
        fontWeight: FontWeight.w800, letterSpacing: 1.8)),
    const SizedBox(width: 10),
    Expanded(child: Container(height: 1, color: _C.b1)),
  ]);
}

// Phosphor-based section header variant
class _PSectionHeader extends StatelessWidget {
  final String label;
  final PhosphorIconData icon;
  const _PSectionHeader({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) => Row(children: [
    PhosphorIcon(icon, color: _C.t2, size: 14),
    const SizedBox(width: 7),
    Text(label, style: const TextStyle(
        color: _C.t2, fontSize: 10,
        fontWeight: FontWeight.w800, letterSpacing: 1.8)),
    const SizedBox(width: 10),
    Expanded(child: Container(height: 1, color: _C.b1)),
  ]);
}

// Option item data
class _OptionItem {
  final String id;
  final String topLabel;
  final String bottomLabel;
  final String? subLabel;
  final bool selected;
  final Color accentColor;

  const _OptionItem({
    required this.id,
    required this.topLabel,
    required this.bottomLabel,
    this.subLabel,
    required this.selected,
    required this.accentColor,
  });
}

// Horizontal scrollable option row
class _HorizontalOptionRow extends StatelessWidget {
  final List<_OptionItem> items;
  final ValueChanged<String> onSelect;
  const _HorizontalOptionRow({required this.items, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    if (items.length <= 4) {
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (int i = 0; i < items.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(child: _OptionCard(item: items[i], onTap: () => onSelect(items[i].id))),
            ],
          ],
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (int i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          SizedBox(
            width: 90,
            child: _OptionCard(item: items[i], onTap: () => onSelect(items[i].id)),
          ),
        ],
      ]),
    );
  }
}

// Individual selectable option card
class _OptionCard extends StatelessWidget {
  final _OptionItem item;
  final VoidCallback onTap;
  const _OptionCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 10),
      decoration: BoxDecoration(
        color: item.selected
            ? item.accentColor.withValues(alpha: 0.12)
            : _C.surface,
        borderRadius: BorderRadius.circular(_C.r12),
        border: Border.all(
          color: item.selected ? item.accentColor : _C.b1,
          width: item.selected ? 1.5 : 1,
        ),
        boxShadow: item.selected
            ? [BoxShadow(
                color: item.accentColor.withValues(alpha: 0.18),
                blurRadius: 14, offset: const Offset(0, 4))]
            : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
        Text(
          item.topLabel,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: item.selected ? item.accentColor : _C.t1,
            fontSize: 13, fontWeight: FontWeight.w700,
          ),
        ),
        if (item.subLabel != null) ...[
          const SizedBox(height: 3),
          Text(
            item.subLabel!,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: item.selected ? item.accentColor.withValues(alpha: 0.7) : _C.t2,
              fontSize: 9,
            ),
          ),
        ],
        const SizedBox(height: 5),
        Text(
          item.bottomLabel,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: item.selected ? item.accentColor : _C.t0,
            fontSize: 12, fontWeight: FontWeight.w800,
          ),
        ),
      ]),
    ),
  );
}

// Shared action button for manage section
class _ActionBtn extends StatefulWidget {
  final bool loading, disabled;
  final Color color;
  final String label;
  final VoidCallback onTap;
  const _ActionBtn({
    required this.loading, required this.disabled,
    required this.color, required this.label, required this.onTap,
  });

  @override
  State<_ActionBtn> createState() => _ActionBtnState();
}

class _ActionBtnState extends State<_ActionBtn>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() { _pulse.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _pressed ? 0.97 : 1.0,
      duration: _pressed
          ? const Duration(milliseconds: 80)
          : const Duration(milliseconds: 400),
      curve: _pressed ? Curves.easeIn : Curves.elasticOut,
      child: GestureDetector(
        onTapDown:  (_) { if (!widget.loading && !widget.disabled) setState(() => _pressed = true); },
        onTapUp:    (_) { widget.onTap(); setState(() => _pressed = false); },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (_, child) {
            final p = widget.disabled ? 0.0 : _pulse.value;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 56, width: double.infinity,
              decoration: BoxDecoration(
                gradient: widget.disabled
                    ? null
                    : LinearGradient(
                        colors: [widget.color, Color.lerp(widget.color, Colors.black, 0.28)!],
                        begin: Alignment.topLeft, end: Alignment.bottomRight),
                color: widget.disabled ? _C.surface : null,
                borderRadius: BorderRadius.circular(_C.r16),
                border: widget.disabled ? Border.all(color: _C.b1) : null,
                boxShadow: widget.disabled ? null : [
                  BoxShadow(
                    color: widget.color.withValues(alpha: 0.24 + 0.18 * p),
                    blurRadius: 16 + 12 * p,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: child,
            );
          },
          child: Center(
            child: widget.loading
                ? const SizedBox(
                    width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.4),
                          end: Offset.zero,
                        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
                        child: child,
                      ),
                    ),
                    child: Text(
                      widget.label,
                      key: ValueKey(widget.label),
                      style: TextStyle(
                        color: widget.disabled ? _C.t2 : Colors.white,
                        fontSize: 15, fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Not-logged-in card
// ═══════════════════════════════════════════════════════════════════════════

class _LoginCard extends StatelessWidget {
  final VoidCallback onLogin;
  const _LoginCard({required this.onLogin});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(28, 36, 28, 32),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [_C.cg1, _C.cg2],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      borderRadius: BorderRadius.circular(_C.r22),
      border: Border.all(color: _C.indigo.withValues(alpha: 0.25)),
    ),
    child: Column(children: [
      Container(
        width: 80, height: 80,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [_C.indigo, _C.indigoD],
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
                color: _C.indigo.withValues(alpha: 0.45),
                blurRadius: 28, offset: const Offset(0, 8)),
          ],
        ),
        child: const Icon(Icons.lock_person_rounded, color: Colors.white, size: 38),
      ),
      const SizedBox(height: 22),
      const Text(
        'Войдите, чтобы\nувидеть тарифы',
        textAlign: TextAlign.center,
        style: TextStyle(
            color: _C.t0, fontSize: 22,
            fontWeight: FontWeight.w800, height: 1.25, letterSpacing: -0.3),
      ),
      const SizedBox(height: 8),
      const Text(
        'Тарифы формируются индивидуально.\nАвторизуйтесь через Telegram.',
        textAlign: TextAlign.center,
        style: TextStyle(color: _C.t1, fontSize: 14, height: 1.55),
      ),
      const SizedBox(height: 28),
      TelegramLoginButton(onTap: onLogin),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Error card
// ═══════════════════════════════════════════════════════════════════════════

class _ErrorCard extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorCard({required this.onRetry});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(28),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [_C.cg1, _C.cg2],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      borderRadius: BorderRadius.circular(_C.r22),
      border: Border.all(color: _C.b1),
    ),
    child: Column(children: [
      Container(
        width: 60, height: 60,
        decoration: BoxDecoration(
            color: _C.rose.withValues(alpha: 0.10), shape: BoxShape.circle),
        child: const Icon(Icons.wifi_off_rounded, color: _C.rose, size: 28),
      ),
      const SizedBox(height: 16),
      const Text('Не удалось загрузить тарифы',
          textAlign: TextAlign.center,
          style: TextStyle(color: _C.t0, fontSize: 17, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      const Text('Проверьте подключение к интернету',
          textAlign: TextAlign.center,
          style: TextStyle(color: _C.t1, fontSize: 13)),
      const SizedBox(height: 20),
      GestureDetector(
        onTap: onRetry,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 11),
          decoration: BoxDecoration(
              color: _C.indigo.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(50),
              border: Border.all(color: _C.indigo.withValues(alpha: 0.35))),
          child: const Text('Попробовать снова',
              style: TextStyle(color: _C.indigo, fontSize: 14, fontWeight: FontWeight.w700)),
        ),
      ),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Payment polling card
// ═══════════════════════════════════════════════════════════════════════════

class _PollingCard extends StatelessWidget {
  const _PollingCard();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(32),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [_C.cg1, _C.cg2],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      borderRadius: BorderRadius.circular(_C.r22),
      border: Border.all(color: _C.indigo.withValues(alpha: 0.28))),
    child: Column(children: [
      const SizedBox(
          width: 52, height: 52,
          child: CircularProgressIndicator(strokeWidth: 3, color: _C.indigo)),
      const SizedBox(height: 24),
      const Text('Обрабатываем платёж…',
          textAlign: TextAlign.center,
          style: TextStyle(color: _C.t0, fontSize: 20, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      const Text('Ожидаем подтверждение.\nОбычно это занимает меньше минуты.',
          textAlign: TextAlign.center,
          style: TextStyle(color: _C.t1, fontSize: 14, height: 1.6)),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Success overlay
// ═══════════════════════════════════════════════════════════════════════════

// ── Particle data ─────────────────────────────────────────────────────────────

class _Particle {
  final double angle;   // radians
  final double speed;   // relative 0.5–1.5
  final double delay;   // normalised 0.0–0.35 (start offset)
  final Color  color;
  final double radius;  // px 3–7

  const _Particle({
    required this.angle,
    required this.speed,
    required this.delay,
    required this.color,
    required this.radius,
  });
}

class _ParticlePainter extends CustomPainter {
  final double progress;
  final List<_Particle> particles;
  // Vertical offset so particles burst from the icon, not screen centre
  final double originOffsetY;

  const _ParticlePainter({
    required this.progress,
    required this.particles,
    this.originOffsetY = -60,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2 + originOffsetY;
    final paint = Paint()..style = PaintingStyle.fill;

    for (final p in particles) {
      if (progress <= p.delay) continue;
      final t = ((progress - p.delay) / (1.0 - p.delay)).clamp(0.0, 1.0);
      // Quick fade-in, slow fade-out
      final opacity = t < 0.45 ? t / 0.45 : (1.0 - t) / 0.55;
      final dist = p.speed * t * 190;
      final dx = cx + dist * cos(p.angle);
      final dy = cy + dist * sin(p.angle) + 55 * t * t; // gravity bow
      final r  = (p.radius * (1.0 - t * 0.35)).clamp(1.0, 12.0);
      paint.color = p.color.withValues(alpha: (opacity * 0.92).clamp(0.0, 1.0));
      canvas.drawCircle(Offset(dx, dy), r, paint);
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) => old.progress != progress;
}

// ── Success overlay ───────────────────────────────────────────────────────────

class _SuccessOverlay extends StatefulWidget {
  final bool isUpgrade;
  final VoidCallback? onDismiss;
  const _SuccessOverlay({required this.isUpgrade, this.onDismiss});

  @override
  State<_SuccessOverlay> createState() => _SuccessOverlayState();
}

class _SuccessOverlayState extends State<_SuccessOverlay>
    with TickerProviderStateMixin {
  // Main sequence: fade-in → icon scale → text slide
  late final AnimationController _mainCtrl;
  // Particle burst, fires after icon pops
  late final AnimationController _particleCtrl;
  // Expanding ring pulse after icon lands
  late final AnimationController _pulseCtrl;

  late final Animation<double> _fadeIn;
  late final Animation<double> _scaleIcon;
  late final Animation<double> _fadeText;
  late final Animation<double> _slideText;

  late final List<_Particle> _particles;

  static const _particleColors = [
    Color(0xFF7C6FF7), // violet
    Color(0xFF2DD4BF), // teal
    Color(0xFFFBBF24), // amber
    Color(0xFF34D399), // emerald
    Color(0xFF60A5FA), // sky-blue
    Color(0xFFF472B6), // pink
  ];

  @override
  void initState() {
    super.initState();

    // Pre-generate particles with randomised properties
    final rng = Random();
    _particles = List.generate(22, (i) {
      final baseAngle = (i / 22) * 2 * pi;
      return _Particle(
        angle:  baseAngle + (rng.nextDouble() - 0.5) * 0.6,
        speed:  0.55 + rng.nextDouble() * 0.9,
        delay:  rng.nextDouble() * 0.3,
        color:  _particleColors[rng.nextInt(_particleColors.length)],
        radius: 3.0 + rng.nextDouble() * 4.0,
      );
    });

    _mainCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1800));
    _particleCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1300));
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 650));

    _fadeIn    = CurvedAnimation(parent: _mainCtrl,
        curve: const Interval(0.00, 0.25, curve: Curves.easeOut));
    _scaleIcon = CurvedAnimation(parent: _mainCtrl,
        curve: const Interval(0.08, 0.50, curve: Curves.elasticOut));
    _fadeText  = CurvedAnimation(parent: _mainCtrl,
        curve: const Interval(0.48, 0.74, curve: Curves.easeOut));
    _slideText = CurvedAnimation(parent: _mainCtrl,
        curve: const Interval(0.48, 0.74, curve: Curves.easeOutCubic));

    _mainCtrl.forward();

    // Staggered trigger: particles + haptic when icon starts landing
    Future<void>.delayed(const Duration(milliseconds: 230), () {
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      _particleCtrl.forward();
    });
    // Pulse ring fires right as elasticOut settles
    Future<void>.delayed(const Duration(milliseconds: 460), () {
      if (mounted) _pulseCtrl.forward();
    });
  }

  @override
  void dispose() {
    _mainCtrl.dispose();
    _particleCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: widget.onDismiss,
    behavior: HitTestBehavior.opaque,
    child: FadeTransition(
      opacity: _fadeIn,
      child: Container(
        color: _C.bg.withValues(alpha: 0.97),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── Particle burst ──────────────────────────────────────────
            AnimatedBuilder(
              animation: _particleCtrl,
              builder: (_, _) => CustomPaint(
                painter: _ParticlePainter(
                  progress:      _particleCtrl.value,
                  particles:     _particles,
                  originOffsetY: -70,
                ),
              ),
            ),

            // ── Main content ────────────────────────────────────────────
            Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [

                // Icon + expanding pulse ring
                AnimatedBuilder(
                  animation: Listenable.merge([_scaleIcon, _pulseCtrl]),
                  builder: (_, child) => Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: [
                      // Pulse ring
                      if (_pulseCtrl.value > 0)
                        Opacity(
                          opacity: (1.0 - _pulseCtrl.value).clamp(0.0, 1.0),
                          child: Container(
                            width:  108 + _pulseCtrl.value * 72,
                            height: 108 + _pulseCtrl.value * 72,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: _C.teal.withValues(alpha: 0.55),
                                  width: 2.5),
                            ),
                          ),
                        ),
                      child!,
                    ],
                  ),
                  child: ScaleTransition(
                    scale: _scaleIcon,
                    child: Container(
                      width: 108, height: 108,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                            colors: [_C.teal, Color(0xFF059669)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight),
                        boxShadow: [
                          BoxShadow(color: _C.teal.withValues(alpha: 0.55),
                              blurRadius: 50, offset: const Offset(0, 10)),
                          BoxShadow(color: _C.teal.withValues(alpha: 0.25),
                              blurRadius: 90, spreadRadius: 10),
                        ],
                      ),
                      child: const Icon(
                          Icons.check_rounded, color: Colors.white, size: 54),
                    ),
                  ),
                ),

                const SizedBox(height: 32),

                // Text slides up as it fades in (dopamine payoff moment)
                AnimatedBuilder(
                  animation: _fadeText,
                  builder: (_, _) => Opacity(
                    opacity: _fadeText.value,
                    child: Transform.translate(
                      offset: Offset(0, 22 * (1.0 - _slideText.value)),
                      child: Column(children: [
                        Text(
                          widget.isUpgrade ? 'Готово!' : 'Подписка активна',
                          style: const TextStyle(
                              color: _C.t0, fontSize: 30,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          widget.isUpgrade
                              ? 'Изменения применены'
                              : 'Добро пожаловать',
                          style: const TextStyle(color: _C.t1, fontSize: 16),
                        ),
                      ]),
                    ),
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
    ),
  );
}
