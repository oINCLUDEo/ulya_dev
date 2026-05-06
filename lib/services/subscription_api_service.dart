import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../config/app_config.dart';
import 'auth_state.dart';

/// Models for the subscription API responses.

class SubscriptionOptions {
  final bool hasSubscription;
  final List<PeriodOption> periods;
  final int balanceKopeks;
  final double balanceRub;
  final String currency;
  final Map<String, dynamic>? currentSubscription;

  // Traffic top-up (докупка ГБ к текущей подписке через /upgrade)
  final bool trafficTopupEnabled;
  final List<TrafficTopupPackage> trafficTopupPackages;
  final int? availableTopupGb;

  const SubscriptionOptions({
    required this.hasSubscription,
    required this.periods,
    required this.balanceKopeks,
    required this.balanceRub,
    required this.currency,
    this.currentSubscription,
    this.trafficTopupEnabled = false,
    this.trafficTopupPackages = const [],
    this.availableTopupGb,
  });

  factory SubscriptionOptions.fromJson(Map<String, dynamic> json) {
    final ctx = json['context'] as Map<String, dynamic>? ?? {};
    final periodsRaw = ctx['periods'] as List<dynamic>? ?? [];
    final packagesRaw = ctx['traffic_topup_packages'] as List<dynamic>? ?? [];
    return SubscriptionOptions(
      hasSubscription: json['has_subscription'] as bool? ?? false,
      periods: periodsRaw
          .whereType<Map<String, dynamic>>()
          .map(PeriodOption.fromJson)
          .toList(),
      balanceKopeks: (ctx['balance_kopeks'] as num?)?.toInt() ?? 0,
      balanceRub: (ctx['balance_rub'] as num?)?.toDouble() ?? 0.0,
      currency: ctx['currency'] as String? ?? 'RUB',
      currentSubscription: ctx['current_subscription'] as Map<String, dynamic>?,
      trafficTopupEnabled: ctx['traffic_topup_enabled'] as bool? ?? false,
      trafficTopupPackages: packagesRaw
          .whereType<Map<String, dynamic>>()
          .map(TrafficTopupPackage.fromJson)
          .toList(),
      availableTopupGb: (ctx['available_topup_gb'] as num?)?.toInt(),
    );
  }
}

class PeriodOption {
  final String id;
  final String label;
  final int basePriceKopeks;
  final int originalPriceKopeks;
  final int discountPercent;
  final TrafficConfig? traffic;
  final DevicesConfig? devices;

  const PeriodOption({
    required this.id,
    required this.label,
    required this.basePriceKopeks,
    this.originalPriceKopeks = 0,
    this.discountPercent = 0,
    this.traffic,
    this.devices,
  });

  bool get hasBestValue => discountPercent > 0;

  factory PeriodOption.fromJson(Map<String, dynamic> json) {
    final base = (json['price_kopeks'] as num?)?.toInt() ??
        (json['base_price'] as num?)?.toInt() ??
        0;
    final original =
        (json['original_price_kopeks'] as num?)?.toInt() ?? base;
    return PeriodOption(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      basePriceKopeks: base,
      originalPriceKopeks: original,
      discountPercent: (json['discount_percent'] as num?)?.toInt() ?? 0,
      traffic: json['traffic'] != null
          ? TrafficConfig.fromJson(json['traffic'] as Map<String, dynamic>)
          : null,
      devices: json['devices'] != null
          ? DevicesConfig.fromJson(json['devices'] as Map<String, dynamic>)
          : null,
    );
  }
}

class TrafficOption {
  final int value;
  final String label;
  final int priceKopeks;
  final bool isDefault;

  const TrafficOption({
    required this.value,
    required this.label,
    required this.priceKopeks,
    this.isDefault = false,
  });

  factory TrafficOption.fromJson(Map<String, dynamic> json) {
    return TrafficOption(
      value: (json['value'] as num?)?.toInt() ?? 0,
      label: json['label'] as String? ?? '',
      priceKopeks: (json['price_kopeks'] as num?)?.toInt() ?? 0,
      isDefault: json['is_default'] as bool? ?? false,
    );
  }
}

class TrafficTopupPackage {
  final int gb;             // GB increment — send directly as traffic_add
  final int priceKopeks;    // final price after discounts
  final String priceLabel;  // formatted e.g. "89 ₽"
  final int? originalPriceKopeks;
  final int discountPercent;

  const TrafficTopupPackage({
    required this.gb,
    required this.priceKopeks,
    required this.priceLabel,
    this.originalPriceKopeks,
    this.discountPercent = 0,
  });

  factory TrafficTopupPackage.fromJson(Map<String, dynamic> j) {
    return TrafficTopupPackage(
      gb: (j['gb'] as num?)?.toInt() ?? 0,
      priceKopeks: (j['price_kopeks'] as num?)?.toInt() ?? 0,
      priceLabel: j['price_label'] as String? ?? '',
      originalPriceKopeks: (j['original_price_kopeks'] as num?)?.toInt(),
      discountPercent: (j['discount_percent'] as num?)?.toInt() ?? 0,
    );
  }
}

class TrafficConfig {
  final bool selectable;
  final int? defaultValue;
  final int? currentValue;
  final List<TrafficOption> options;

  const TrafficConfig({
    required this.selectable,
    this.defaultValue,
    this.currentValue,
    required this.options,
  });

  factory TrafficConfig.fromJson(Map<String, dynamic> json) {
    final opts = (json['options'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(TrafficOption.fromJson)
        .toList();
    return TrafficConfig(
      selectable: json['selectable'] as bool? ?? false,
      defaultValue: (json['default'] as num?)?.toInt(),
      currentValue: (json['current'] as num?)?.toInt(),
      options: opts,
    );
  }
}

class DevicesConfig {
  final int minimum;
  final int? maximum;
  final int? defaultValue;
  final int? currentValue;
  final List<int> options;

  const DevicesConfig({
    required this.minimum,
    this.maximum,
    this.defaultValue,
    this.currentValue,
    required this.options,
  });

  factory DevicesConfig.fromJson(Map<String, dynamic> json) {
    // Backend sends 'min'/'max'; fall back to 'minimum'/'maximum' for compat.
    final min = (json['min'] as num?)?.toInt() ??
        (json['minimum'] as num?)?.toInt() ??
        1;
    final max = (json['max'] as num?)?.toInt() ??
        (json['maximum'] as num?)?.toInt();
    final current = (json['current'] as num?)?.toInt();
    final defaultVal = (json['default'] as num?)?.toInt() ?? current ?? min;

    // Build selectable options list from range (cap at 10 choices).
    List<int> opts;
    final rawOpts = json['options'] as List<dynamic>?;
    if (rawOpts != null && rawOpts.isNotEmpty) {
      opts = rawOpts.whereType<num>().map((e) => e.toInt()).toList();
    } else if (max != null && max > min) {
      // Generate a reasonable set of options.
      final step = ((max - min) / 9).ceil().clamp(1, 9999);
      opts = [];
      for (var v = min; v <= max; v += step) {
        opts.add(v);
      }
      if (opts.isEmpty || opts.last != max) opts.add(max);
    } else {
      opts = [min];
    }

    return DevicesConfig(
      minimum: min,
      maximum: max,
      defaultValue: defaultVal,
      currentValue: current,
      options: opts,
    );
  }
}

class CalcResult {
  final int totalKopeks;
  final double totalRub;
  final Map<String, dynamic> preview;

  const CalcResult({
    required this.totalKopeks,
    required this.totalRub,
    required this.preview,
  });

  factory CalcResult.fromJson(Map<String, dynamic> json) {
    return CalcResult(
      totalKopeks: (json['total_kopeks'] as num?)?.toInt() ?? 0,
      totalRub: (json['total_rub'] as num?)?.toDouble() ?? 0.0,
      preview: json['preview'] as Map<String, dynamic>? ?? {},
    );
  }
}

class BuyResult {
  final String status;
  final String? message;
  final String? paymentUrl;
  final int? amountKopeks;
  final Map<String, dynamic>? subscription;

  const BuyResult({
    required this.status,
    this.message,
    this.paymentUrl,
    this.amountKopeks,
    this.subscription,
  });

  bool get isSuccess => status == 'success';
  bool get requiresPayment => status == 'payment_required';

  factory BuyResult.fromJson(Map<String, dynamic> json) {
    return BuyResult(
      status: json['status'] as String? ?? 'error',
      message: json['message'] as String?,
      paymentUrl: json['payment_url'] as String?,
      amountKopeks: (json['amount_kopeks'] as num?)?.toInt(),
      subscription: json['subscription'] as Map<String, dynamic>?,
    );
  }
}

class BalanceInfo {
  final int balanceKopeks;
  final double balanceRub;
  final String currency;

  const BalanceInfo({
    required this.balanceKopeks,
    required this.balanceRub,
    required this.currency,
  });

  factory BalanceInfo.fromJson(Map<String, dynamic> json) {
    return BalanceInfo(
      balanceKopeks: (json['balance_kopeks'] as num?)?.toInt() ?? 0,
      balanceRub: (json['balance_rub'] as num?)?.toDouble() ?? 0.0,
      currency: json['currency'] as String? ?? 'RUB',
    );
  }
}

class TopupResult {
  final String status;
  final String? paymentUrl;
  final String? message;
  final int? amountKopeks;

  const TopupResult({
    required this.status,
    this.paymentUrl,
    this.message,
    this.amountKopeks,
  });

  bool get requiresPayment => status == 'payment_required';

  factory TopupResult.fromJson(Map<String, dynamic> json) {
    return TopupResult(
      status: json['status'] as String? ?? 'error',
      paymentUrl: json['payment_url'] as String?,
      message: json['message'] as String?,
      amountKopeks: (json['amount_kopeks'] as num?)?.toInt(),
    );
  }
}

class UpgradeCalcResult {
  final int amountKopeks;
  final double amountRub;

  const UpgradeCalcResult({
    required this.amountKopeks,
    required this.amountRub,
  });

  factory UpgradeCalcResult.fromJson(Map<String, dynamic> json) {
    return UpgradeCalcResult(
      amountKopeks: (json['amount_kopeks'] as num?)?.toInt() ?? 0,
      amountRub: (json['amount_rub'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tariff catalog models
// ─────────────────────────────────────────────────────────────────────────────

class TariffPeriod {
  final String id;       // "days:30"
  final int days;
  final int months;
  final String label;   // "1 месяц"
  final int priceKopeks;
  final int? originalPriceKopeks;
  final int discountPercent;

  const TariffPeriod({
    required this.id,
    required this.days,
    required this.months,
    required this.label,
    required this.priceKopeks,
    this.originalPriceKopeks,
    this.discountPercent = 0,
  });

  double get priceRub => priceKopeks / 100;
  double? get originalPriceRub =>
      originalPriceKopeks != null ? originalPriceKopeks! / 100 : null;
  double? get pricePerMonthRub =>
      months > 1 ? priceRub / months : null;

  factory TariffPeriod.fromJson(Map<String, dynamic> json) {
    final baseKopeks = (json['price_kopeks'] as num?)?.toInt() ?? 0;
    final origKopeks = (json['original_price_kopeks'] as num?)?.toInt();
    final discPct = (json['discount_percent'] as num?)?.toInt() ?? 0;
    return TariffPeriod(
      id: json['id'] as String? ?? '',
      days: (json['days'] as num?)?.toInt() ?? 30,
      months: (json['months'] as num?)?.toInt() ?? 1,
      label: json['label'] as String? ?? '',
      priceKopeks: baseKopeks,
      originalPriceKopeks: (origKopeks != null && origKopeks != baseKopeks)
          ? origKopeks
          : null,
      discountPercent: discPct,
    );
  }
}

class TariffInfo {
  final int id;
  final String name;
  final String? description;
  final int trafficLimitGb;   // 0 = unlimited
  final int deviceLimit;
  final int tierLevel;
  final List<TariffPeriod> periods;

  const TariffInfo({
    required this.id,
    required this.name,
    this.description,
    required this.trafficLimitGb,
    required this.deviceLimit,
    required this.tierLevel,
    required this.periods,
  });

  /// Cheapest period (lowest total price — usually 1 month).
  TariffPeriod? get cheapestPeriod => periods.isEmpty
      ? null
      : periods.reduce((a, b) => a.priceKopeks < b.priceKopeks ? a : b);

  /// Best-value period (highest discount %).
  TariffPeriod? get bestValuePeriod {
    if (periods.isEmpty) return null;
    final withDiscount = periods.where((p) => p.discountPercent > 0).toList();
    if (withDiscount.isEmpty) return null;
    return withDiscount
        .reduce((a, b) => a.discountPercent > b.discountPercent ? a : b);
  }

  String get trafficLabel =>
      trafficLimitGb == 0 ? '∞ ГБ' : '$trafficLimitGb ГБ';
  String get deviceLabel => '$deviceLimit устр.';

  factory TariffInfo.fromJson(Map<String, dynamic> json) {
    final rawPeriods = json['periods'] as List<dynamic>? ?? [];
    return TariffInfo(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      description: json['description'] as String?,
      trafficLimitGb: (json['traffic_limit_gb'] as num?)?.toInt() ?? 0,
      deviceLimit: (json['device_limit'] as num?)?.toInt() ?? 1,
      tierLevel: (json['tier_level'] as num?)?.toInt() ?? 1,
      periods: rawPeriods
          .whereType<Map<String, dynamic>>()
          .map(TariffPeriod.fromJson)
          .toList(),
    );
  }
}

/// Service for the mobile subscription API.
class SubscriptionApiService {
  SubscriptionApiService._();

  static String get _base => AppConfig.backendBaseUrl;

  static Map<String, String> _headers() {
    final auth = authStateNotifier.value;
    return {
      'Content-Type': 'application/json',
      if (auth.telegramId != null) 'X-Telegram-Id': auth.telegramId.toString(),
    };
  }

  /// Returns an HTTP client that routes through the local xray HTTP proxy
  /// (port 10808) when the VPN is active, so subscription API calls reach
  /// the backend even when the app package is excluded from the VPN tunnel.
  static http.Client _makeClient() {
    if (vpnConnectedNotifier.value) {
      return IOClient(
        HttpClient()..findProxy = (uri) => 'PROXY 127.0.0.1:10808',
      );
    }
    return http.Client();
  }

  static Future<http.Response> _get(Uri uri) async {
    final c = _makeClient();
    try {
      return await c
          .get(uri, headers: _headers())
          .timeout(const Duration(seconds: 15));
    } finally {
      c.close();
    }
  }

  static Future<http.Response> _post(Uri uri, String body,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final c = _makeClient();
    try {
      return await c
          .post(uri, headers: _headers(), body: body)
          .timeout(timeout);
    } finally {
      c.close();
    }
  }

  static Future<http.Response> _put(Uri uri, String body) async {
    final c = _makeClient();
    try {
      return await c
          .put(uri, headers: _headers(), body: body)
          .timeout(const Duration(seconds: 15));
    } finally {
      c.close();
    }
  }

  /// GET /mobile/v1/subscription/options
  static Future<SubscriptionOptions?> getOptions() async {
    try {
      final resp = await _get(
        Uri.parse('$_base/mobile/v1/subscription/options'),
      );
      if (resp.statusCode == 200) {
        return SubscriptionOptions.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>,
        );
      }
      debugPrint('SubscriptionApiService.getOptions: ${resp.statusCode}');
      return null;
    } on Exception catch (e) {
      debugPrint('SubscriptionApiService.getOptions error: $e');
      return null;
    }
  }

  /// POST /mobile/v1/subscription/calc
  static Future<CalcResult?> calcPrice({
    required String periodId,
    int? trafficValue,
    int? devices,
    List<String>? servers,
  }) async {
    try {
      final body = <String, dynamic>{'period_id': periodId};
      if (trafficValue != null) body['traffic_value'] = trafficValue;
      if (devices != null) body['devices'] = devices;
      if (servers != null) body['servers'] = servers;

      final resp = await _post(
        Uri.parse('$_base/mobile/v1/subscription/calc'),
        jsonEncode(body),
        timeout: const Duration(seconds: 15),
      );
      if (resp.statusCode == 200) {
        return CalcResult.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>,
        );
      }
      debugPrint('SubscriptionApiService.calcPrice: ${resp.statusCode} ${resp.body}');
      return null;
    } on Exception catch (e) {
      debugPrint('SubscriptionApiService.calcPrice error: $e');
      return null;
    }
  }

  /// POST /mobile/v1/subscription/buy
  static Future<BuyResult?> buySubscription({
    required String periodId,
    int? trafficValue,
    int? devices,
    List<String>? servers,
  }) async {
    try {
      final body = <String, dynamic>{'period_id': periodId};
      if (trafficValue != null) body['traffic_value'] = trafficValue;
      if (devices != null) body['devices'] = devices;
      if (servers != null) body['servers'] = servers;

      final resp = await _post(
        Uri.parse('$_base/mobile/v1/subscription/buy'),
        jsonEncode(body),
      );
      if (resp.statusCode == 200) {
        return BuyResult.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>,
        );
      }
      debugPrint('SubscriptionApiService.buySubscription: ${resp.statusCode} ${resp.body}');
      // Try to extract error detail
      try {
        final errBody = jsonDecode(resp.body) as Map<String, dynamic>;
        final detail = errBody['detail'] as String?;
        if (detail != null) {
          return BuyResult(status: 'error', message: detail);
        }
      } catch (_) {}
      return BuyResult(status: 'error', message: 'Ошибка покупки подписки');
    } on Exception catch (e) {
      debugPrint('SubscriptionApiService.buySubscription error: $e');
      return BuyResult(status: 'error', message: e.toString());
    }
  }

  /// POST /mobile/v1/subscription/upgrade
  static Future<BuyResult?> upgradeSubscription({
    String? periodId,
    int? trafficAdd,
    int? devicesAdd,
    List<String>? servers,
  }) async {
    try {
      final body = <String, dynamic>{};
      if (periodId != null) body['period_id'] = periodId;
      if (trafficAdd != null) body['traffic_add'] = trafficAdd;
      if (devicesAdd != null) body['devices_add'] = devicesAdd;
      if (servers != null) body['servers'] = servers;

      final resp = await _post(
        Uri.parse('$_base/mobile/v1/subscription/upgrade'),
        jsonEncode(body),
      );
      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body) as Map<String, dynamic>;
        return BuyResult(
          status: json['status'] as String? ?? 'error',
          message: json['message'] as String?,
          paymentUrl: json['payment_url'] as String?,
          amountKopeks: (json['amount_kopeks'] as num?)?.toInt(),
          subscription: json['subscription'] as Map<String, dynamic>?,
        );
      }
      debugPrint('SubscriptionApiService.upgradeSubscription: ${resp.statusCode} ${resp.body}');
      try {
        final errBody = jsonDecode(resp.body) as Map<String, dynamic>;
        final detail = errBody['detail'] as String?;
        if (detail != null) {
          return BuyResult(status: 'error', message: detail);
        }
      } catch (_) {}
      return BuyResult(status: 'error', message: 'Ошибка улучшения подписки');
    } on Exception catch (e) {
      debugPrint('SubscriptionApiService.upgradeSubscription error: $e');
      return BuyResult(status: 'error', message: e.toString());
    }
  }

  /// POST /mobile/v1/subscription/upgrade/calc
  static Future<UpgradeCalcResult?> calcUpgradePrice({
    String? periodId,
    int? trafficAdd,
    int? devicesAdd,
    List<String>? servers,
  }) async {
    try {
      final body = <String, dynamic>{};
      if (periodId != null) body['period_id'] = periodId;
      if (trafficAdd != null) body['traffic_add'] = trafficAdd;
      if (devicesAdd != null) body['devices_add'] = devicesAdd;
      if (servers != null) body['servers'] = servers;

      final resp = await _post(
        Uri.parse('$_base/mobile/v1/subscription/upgrade/calc'),
        jsonEncode(body),
        timeout: const Duration(seconds: 15),
      );
      if (resp.statusCode == 200) {
        return UpgradeCalcResult.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>,
        );
      }
      debugPrint('SubscriptionApiService.calcUpgradePrice: ${resp.statusCode} ${resp.body}');
      return null;
    } on Exception catch (e) {
      debugPrint('SubscriptionApiService.calcUpgradePrice error: $e');
      return null;
    }
  }

  /// GET /mobile/v1/balance
  static Future<BalanceInfo?> getBalance() async {
    try {
      final resp = await _get(Uri.parse('$_base/mobile/v1/balance'));
      if (resp.statusCode == 200) {
        return BalanceInfo.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>,
        );
      }
      debugPrint('SubscriptionApiService.getBalance: ${resp.statusCode}');
      return null;
    } on Exception catch (e) {
      debugPrint('SubscriptionApiService.getBalance error: $e');
      return null;
    }
  }

  /// POST /mobile/v1/balance/topup
  static Future<TopupResult?> topupBalance({required int amountKopeks}) async {
    try {
      final resp = await _post(
        Uri.parse('$_base/mobile/v1/balance/topup'),
        jsonEncode({'amount_kopeks': amountKopeks}),
      );
      if (resp.statusCode == 200) {
        return TopupResult.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>,
        );
      }
      debugPrint('SubscriptionApiService.topupBalance: ${resp.statusCode} ${resp.body}');
      try {
        final errBody = jsonDecode(resp.body) as Map<String, dynamic>;
        final detail = errBody['detail'] as String?;
        if (detail != null) return TopupResult(status: 'error', message: detail);
      } catch (_) {}
      return const TopupResult(status: 'error', message: 'Ошибка пополнения баланса');
    } on Exception catch (e) {
      debugPrint('SubscriptionApiService.topupBalance error: $e');
      return TopupResult(status: 'error', message: e.toString());
    }
  }

  /// GET /mobile/v1/tariffs
  static Future<List<TariffInfo>?> getTariffs() async {
    try {
      final resp = await _get(Uri.parse('$_base/mobile/v1/tariffs'));
      debugPrint('SubscriptionApiService.getTariffs: status=${resp.statusCode}');
      debugPrint('SubscriptionApiService.getTariffs: body=${resp.body}');
      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body) as Map<String, dynamic>;
        final raw = json['tariffs'] as List<dynamic>? ?? [];
        final result = raw
            .whereType<Map<String, dynamic>>()
            .map(TariffInfo.fromJson)
            .toList();
        debugPrint('SubscriptionApiService.getTariffs: parsed ${result.length} tariffs');
        return result;
      }
      return null;
    } on Exception catch (e) {
      debugPrint('SubscriptionApiService.getTariffs error: $e');
      return null;
    }
  }

  /// POST /mobile/v1/subscription/buy-tariff
  static Future<BuyResult?> buyTariff({
    required int tariffId,
    required int periodDays,
  }) async {
    try {
      final body = {'tariff_id': tariffId, 'period_days': periodDays};
      final resp = await _post(
        Uri.parse('$_base/mobile/v1/subscription/buy-tariff'),
        jsonEncode(body),
      );
      if (resp.statusCode == 200) {
        return BuyResult.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>,
        );
      }
      debugPrint('SubscriptionApiService.buyTariff: ${resp.statusCode} ${resp.body}');
      try {
        final err = jsonDecode(resp.body) as Map<String, dynamic>;
        // detail can be a string or a dict (insufficient_funds case)
        final detail = err['detail'];
        if (detail is String) return BuyResult(status: 'error', message: detail);
        if (detail is Map) {
          return BuyResult(
            status: 'error',
            message: detail['message'] as String? ?? 'Ошибка покупки тарифа',
          );
        }
      } catch (_) {}
      return BuyResult(status: 'error', message: 'Ошибка покупки тарифа');
    } on Exception catch (e) {
      debugPrint('SubscriptionApiService.buyTariff error: $e');
      return BuyResult(status: 'error', message: e.toString());
    }
  }

  /// POST /mobile/v1/subscription/change-tariff/calc
  /// Returns the prorated cost to switch to a different tariff.
  /// Returns 0 when the server considers the change free (downgrade).
  static Future<UpgradeCalcResult?> calcChangeTariffPrice({
    required int tariffId,
    required int periodDays,
  }) async {
    try {
      final body = {'tariff_id': tariffId, 'period_days': periodDays};
      final resp = await _post(
        Uri.parse('$_base/mobile/v1/subscription/change-tariff/calc'),
        jsonEncode(body),
        timeout: const Duration(seconds: 15),
      );
      if (resp.statusCode == 200) {
        return UpgradeCalcResult.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>,
        );
      }
      debugPrint(
          'SubscriptionApiService.calcChangeTariffPrice: ${resp.statusCode} ${resp.body}');
      return null;
    } on Exception catch (e) {
      debugPrint('SubscriptionApiService.calcChangeTariffPrice error: $e');
      return null;
    }
  }

  /// POST /mobile/v1/subscription/change-tariff
  /// Switches the active subscription to a different tariff with server-side
  /// proration. For downgrades the server typically returns status='success'
  /// with amount_kopeks=0.
  static Future<BuyResult?> changeTariff({
    required int tariffId,
    required int periodDays,
  }) async {
    try {
      final body = {'tariff_id': tariffId, 'period_days': periodDays};
      final resp = await _post(
        Uri.parse('$_base/mobile/v1/subscription/change-tariff'),
        jsonEncode(body),
      );
      if (resp.statusCode == 200) {
        return BuyResult.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>,
        );
      }
      debugPrint(
          'SubscriptionApiService.changeTariff: ${resp.statusCode} ${resp.body}');
      try {
        final err = jsonDecode(resp.body) as Map<String, dynamic>;
        final detail = err['detail'];
        if (detail is String) return BuyResult(status: 'error', message: detail);
        if (detail is Map) {
          return BuyResult(
            status: 'error',
            message: detail['message'] as String? ?? 'Ошибка смены тарифа',
          );
        }
      } catch (_) {}
      return const BuyResult(status: 'error', message: 'Ошибка смены тарифа');
    } on Exception catch (e) {
      debugPrint('SubscriptionApiService.changeTariff error: $e');
      return BuyResult(status: 'error', message: e.toString());
    }
  }

  /// PUT /mobile/v1/subscription/autopay
  static Future<bool?> setAutopay({required bool enabled}) async {
    try {
      final resp = await _put(
        Uri.parse('$_base/mobile/v1/subscription/autopay'),
        jsonEncode({'enabled': enabled}),
      );
      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body) as Map<String, dynamic>;
        return json['autopay_enabled'] as bool? ?? enabled;
      }
      debugPrint('SubscriptionApiService.setAutopay: ${resp.statusCode}');
      return null;
    } on Exception catch (e) {
      debugPrint('SubscriptionApiService.setAutopay error: $e');
      return null;
    }
  }
}