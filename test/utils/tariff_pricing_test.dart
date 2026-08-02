import 'package:flutter_test/flutter_test.dart';

import 'package:dev_vpn/services/subscription_api_service.dart';
import 'package:dev_vpn/utils/tariff_pricing.dart';

TariffPeriod _period({
  required String id,
  required int days,
  required int months,
  String label = '',
  int priceKopeks = 0,
  int discountPercent = 0,
}) =>
    TariffPeriod(
      id: id,
      days: days,
      months: months,
      label: label,
      priceKopeks: priceKopeks,
      discountPercent: discountPercent,
    );

TariffInfo _tariff(List<TariffPeriod> periods, {int id = 1}) => TariffInfo(
      id: id,
      name: 'Test',
      trafficLimitGb: 0,
      deviceLimit: 1,
      tierLevel: 1,
      periods: periods,
    );

void main() {
  group('parsePeriodMonths', () {
    test('parses "N месяц(а/ев)" forms', () {
      expect(parsePeriodMonths('3 месяца'), 3);
      expect(parsePeriodMonths('1 месяц'), 1);
      expect(parsePeriodMonths('6 мес'), 6);
    });

    test('parses "год/лет" as 12x months', () {
      expect(parsePeriodMonths('1 год'), 12);
      expect(parsePeriodMonths('2 лет'), 24);
    });

    test('is case-insensitive', () {
      expect(parsePeriodMonths('3 МЕСЯЦА'), 3);
    });

    test('returns null when nothing matches', () {
      expect(parsePeriodMonths('навсегда'), isNull);
      expect(parsePeriodMonths(''), isNull);
    });
  });

  group('pluralDays', () {
    test('singular: 1, 21, 101', () {
      expect(pluralDays(1), 'день');
      expect(pluralDays(21), 'день');
      expect(pluralDays(101), 'день');
    });

    test('few: 2-4, 22-24', () {
      expect(pluralDays(2), 'дня');
      expect(pluralDays(3), 'дня');
      expect(pluralDays(4), 'дня');
      expect(pluralDays(22), 'дня');
    });

    test('many: 0, 5-20, 25', () {
      expect(pluralDays(0), 'дней');
      expect(pluralDays(5), 'дней');
      expect(pluralDays(11), 'дней');
      expect(pluralDays(19), 'дней');
      expect(pluralDays(25), 'дней');
    });

    test('11-14 are always "дней" even though they end in 1-4', () {
      expect(pluralDays(11), 'дней');
      expect(pluralDays(12), 'дней');
      expect(pluralDays(14), 'дней');
    });
  });

  group('periodDaysLabel', () {
    test('maps day ranges to the expected month/year label', () {
      expect(periodDaysLabel(30), '1 мес');
      expect(periodDaysLabel(31), '1 мес');
      expect(periodDaysLabel(60), '2 мес');
      expect(periodDaysLabel(90), '3 мес');
      expect(periodDaysLabel(180), '6 мес');
      expect(periodDaysLabel(365), '1 год');
    });

    test('falls back to a rounded month count beyond a year', () {
      expect(periodDaysLabel(400), '13 мес');
    });
  });

  group('periodForDays', () {
    test('returns the exact match when present', () {
      final p30 = _period(id: 'p30', days: 30, months: 1);
      final p90 = _period(id: 'p90', days: 90, months: 3);
      final tariff = _tariff([p30, p90]);
      expect(periodForDays(tariff, 90), same(p90));
    });

    test('falls back to the cheapest period when there is no exact match',
        () {
      final cheap = _period(id: 'cheap', days: 30, months: 1, priceKopeks: 100);
      final pricey = _period(id: 'pricey', days: 90, months: 3, priceKopeks: 900);
      final tariff = _tariff([pricey, cheap]);
      expect(periodForDays(tariff, 365), same(cheap));
    });

    test('returns null for a tariff with no periods', () {
      expect(periodForDays(_tariff(const []), 30), isNull);
    });
  });

  group('uniqueDays', () {
    test('dedupes and sorts across tariffs', () {
      final t1 = _tariff([
        _period(id: 'a', days: 90, months: 3),
        _period(id: 'b', days: 30, months: 1),
      ]);
      final t2 = _tariff([
        _period(id: 'c', days: 30, months: 1),
        _period(id: 'd', days: 365, months: 12),
      ], id: 2);
      expect(uniqueDays([t1, t2]), [30, 90, 365]);
    });

    test('empty for no tariffs', () {
      expect(uniqueDays(const []), isEmpty);
    });
  });

  group('bestDiscountPeriodId', () {
    test('picks the period with the highest discount', () {
      final opts = SubscriptionOptions(
        hasSubscription: false,
        periods: const [
          PeriodOption(id: 'a', label: '1 мес', basePriceKopeks: 100),
          PeriodOption(
              id: 'b',
              label: '3 мес',
              basePriceKopeks: 270,
              discountPercent: 10),
          PeriodOption(
              id: 'c',
              label: '1 год',
              basePriceKopeks: 900,
              discountPercent: 25),
        ],
        balanceKopeks: 0,
        balanceRub: 0,
        currency: 'RUB',
      );
      expect(bestDiscountPeriodId(opts), 'c');
    });

    test('returns null when no period has a discount', () {
      final opts = SubscriptionOptions(
        hasSubscription: false,
        periods: const [
          PeriodOption(id: 'a', label: '1 мес', basePriceKopeks: 100),
        ],
        balanceKopeks: 0,
        balanceRub: 0,
        currency: 'RUB',
      );
      expect(bestDiscountPeriodId(opts), isNull);
    });

    test('returns null for no periods at all', () {
      final opts = SubscriptionOptions(
        hasSubscription: false,
        periods: const [],
        balanceKopeks: 0,
        balanceRub: 0,
        currency: 'RUB',
      );
      expect(bestDiscountPeriodId(opts), isNull);
    });
  });
}
