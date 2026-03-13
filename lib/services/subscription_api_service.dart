import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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

  const SubscriptionOptions({
    required this.hasSubscription,
    required this.periods,
    required this.balanceKopeks,
    required this.balanceRub,
    required this.currency,
    this.currentSubscription,
  });

  factory SubscriptionOptions.fromJson(Map<String, dynamic> json) {
    final ctx = json['context'] as Map<String, dynamic>? ?? {};
    final periodsRaw = ctx['periods'] as List<dynamic>? ?? [];
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

  /// GET /mobile/v1/subscription/options
  static Future<SubscriptionOptions?> getOptions() async {
    try {
      final resp = await http
          .get(
        Uri.parse('$_base/mobile/v1/subscription/options'),
        headers: _headers(),
      )
          .timeout(const Duration(seconds: 15));
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

      final resp = await http
          .post(
        Uri.parse('$_base/mobile/v1/subscription/calc'),
        headers: _headers(),
        body: jsonEncode(body),
      )
          .timeout(const Duration(seconds: 15));
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

      final resp = await http
          .post(
        Uri.parse('$_base/mobile/v1/subscription/buy'),
        headers: _headers(),
        body: jsonEncode(body),
      )
          .timeout(const Duration(seconds: 20));
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

      final resp = await http
          .post(
        Uri.parse('$_base/mobile/v1/subscription/upgrade'),
        headers: _headers(),
        body: jsonEncode(body),
      )
          .timeout(const Duration(seconds: 20));
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

  /// GET /mobile/v1/balance
  static Future<BalanceInfo?> getBalance() async {
    try {
      final resp = await http
          .get(
        Uri.parse('$_base/mobile/v1/balance'),
        headers: _headers(),
      )
          .timeout(const Duration(seconds: 15));
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
      final resp = await http
          .post(
        Uri.parse('$_base/mobile/v1/balance/topup'),
        headers: _headers(),
        body: jsonEncode({'amount_kopeks': amountKopeks}),
      )
          .timeout(const Duration(seconds: 20));
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

  /// PUT /mobile/v1/subscription/autopay
  static Future<bool?> setAutopay({required bool enabled}) async {
    try {
      final resp = await http
          .put(
        Uri.parse('$_base/mobile/v1/subscription/autopay'),
        headers: _headers(),
        body: jsonEncode({'enabled': enabled}),
      )
          .timeout(const Duration(seconds: 15));
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
