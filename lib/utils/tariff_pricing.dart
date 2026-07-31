import '../services/subscription_api_service.dart'
    show PeriodOption, SubscriptionOptions, TariffInfo, TariffPeriod;

/// Pure pricing/period helpers used by the premium/tariff UI.
///
/// Split out of `PremiumPage` (which is otherwise all widget code) so this
/// logic — parsing, labelling, period lookup — can be unit-tested without
/// pumping a widget tree. `PremiumPage` keeps thin private wrappers around
/// these functions so none of its call sites had to change.

/// Parses a period label into a month count.
/// Examples: "3 месяца" → 3, "1 год" → 12, "6 мес" → 6
int? parsePeriodMonths(String label) {
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

/// Pluralises "день / дня / дней" for [n].
String pluralDays(int n) {
  final abs = n.abs() % 100;
  final last = abs % 10;
  if (abs >= 11 && abs <= 19) return 'дней';
  if (last == 1) return 'день';
  if (last >= 2 && last <= 4) return 'дня';
  return 'дней';
}

/// Human-readable label for a period length in days.
String periodDaysLabel(int days) {
  if (days <= 31) return '1 мес';
  if (days <= 62) return '2 мес';
  if (days <= 93) return '3 мес';
  if (days <= 124) return '4 мес';
  if (days <= 186) return '6 мес';
  if (days <= 366) return '1 год';
  return '${(days / 30).round()} мес';
}

/// Finds the period in [tariff] whose `days` match [days].
/// Falls back to the cheapest period (or the first) when there's no exact
/// match.
TariffPeriod? periodForDays(TariffInfo tariff, int days) {
  if (tariff.periods.isEmpty) return null;
  try {
    return tariff.periods.firstWhere((p) => p.days == days);
  } catch (_) {
    return tariff.cheapestPeriod ?? tariff.periods.first;
  }
}

/// All unique period-day values across a list of tariffs, sorted ascending.
List<int> uniqueDays(List<TariffInfo> tariffs) {
  return tariffs.expand((t) => t.periods.map((p) => p.days)).toSet().toList()
    ..sort();
}

/// The id of the period across [opts] with the highest discount percentage,
/// or null if none has a discount.
String? bestDiscountPeriodId(SubscriptionOptions opts) {
  PeriodOption? best;
  for (final p in opts.periods) {
    if (p.discountPercent > 0 &&
        (best == null || p.discountPercent > best.discountPercent)) {
      best = p;
    }
  }
  return best?.id;
}
