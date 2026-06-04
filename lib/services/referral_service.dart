import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'auth_state.dart';

/// User-facing referral state, sourced from
/// `GET /cabinet/referral` (Bearer JWT, Cabinet API).
///
/// Numeric fields are stored both in kopeks (as the backend ships them) and
/// rubles (the convenience double) so UI can pick whichever it needs.
class ReferralInfo {
  final String referralCode;
  /// Public web link a friend opens to register with the code applied.
  final String referralLink;
  /// `t.me/<bot>?start=ref_<code>` — preferred share target on mobile.
  final String botReferralLink;
  final int totalReferrals;
  final int activeReferrals;
  final int totalEarningsKopeks;
  final double totalEarningsRubles;
  final int commissionPercent;
  final int availableBalanceKopeks;
  final double availableBalanceRubles;
  final int withdrawnKopeks;

  const ReferralInfo({
    required this.referralCode,
    required this.referralLink,
    required this.botReferralLink,
    required this.totalReferrals,
    required this.activeReferrals,
    required this.totalEarningsKopeks,
    required this.totalEarningsRubles,
    required this.commissionPercent,
    required this.availableBalanceKopeks,
    required this.availableBalanceRubles,
    required this.withdrawnKopeks,
  });

  factory ReferralInfo.fromJson(Map<String, dynamic> j) => ReferralInfo(
        referralCode: j['referral_code'] as String? ?? '',
        referralLink: j['referral_link'] as String? ?? '',
        botReferralLink: j['bot_referral_link'] as String? ?? '',
        totalReferrals: (j['total_referrals'] as num?)?.toInt() ?? 0,
        activeReferrals: (j['active_referrals'] as num?)?.toInt() ?? 0,
        totalEarningsKopeks: (j['total_earnings_kopeks'] as num?)?.toInt() ?? 0,
        totalEarningsRubles: (j['total_earnings_rubles'] as num?)?.toDouble() ?? 0.0,
        commissionPercent: (j['commission_percent'] as num?)?.toInt() ?? 0,
        availableBalanceKopeks: (j['available_balance_kopeks'] as num?)?.toInt() ?? 0,
        availableBalanceRubles: (j['available_balance_rubles'] as num?)?.toDouble() ?? 0.0,
        withdrawnKopeks: (j['withdrawn_kopeks'] as num?)?.toInt() ?? 0,
      );

  /// Preferred share text — keeps it short for messengers and inserts the
  /// canonical bot link so a friend lands directly in the bot with the code
  /// pre-applied.
  String get shareText {
    final link = botReferralLink.isNotEmpty ? botReferralLink : referralLink;
    return 'Подключайся к Ulya VPN по моему приглашению: $link';
  }
}

/// Terms of the referral programme — used to label the "earn N% from every
/// payment of your friends" CTA.
class ReferralTerms {
  final bool isEnabled;
  final int commissionPercent;
  final double minimumTopupRubles;
  final double firstTopupBonusRubles;
  final double inviterBonusRubles;
  final bool partnerSectionVisible;

  const ReferralTerms({
    required this.isEnabled,
    required this.commissionPercent,
    required this.minimumTopupRubles,
    required this.firstTopupBonusRubles,
    required this.inviterBonusRubles,
    required this.partnerSectionVisible,
  });

  factory ReferralTerms.fromJson(Map<String, dynamic> j) => ReferralTerms(
        isEnabled: j['is_enabled'] as bool? ?? false,
        commissionPercent: (j['commission_percent'] as num?)?.toInt() ?? 0,
        minimumTopupRubles: (j['minimum_topup_rubles'] as num?)?.toDouble() ?? 0.0,
        firstTopupBonusRubles: (j['first_topup_bonus_rubles'] as num?)?.toDouble() ?? 0.0,
        inviterBonusRubles: (j['inviter_bonus_rubles'] as num?)?.toDouble() ?? 0.0,
        partnerSectionVisible: j['partner_section_visible'] as bool? ?? false,
      );
}

/// Lightweight client for the Cabinet referral endpoints.
///
/// Auth model: all endpoints (except /terms) require Bearer JWT — the same
/// `cabinetAccessToken` issued by email login. Telegram-only users currently
/// don't have a JWT, so [getInfo] returns null for them and the UI falls back
/// to a "open in Telegram bot" CTA.
class ReferralService {
  ReferralService._();

  static String get _base => AppConfig.backendBaseUrl;

  static Map<String, String>? _bearerHeaders() {
    final token = authStateNotifier.value.cabinetAccessToken;
    if (token == null || token.isEmpty) return null;
    return {
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  /// GET /cabinet/referral — current user's referral statistics.
  /// Returns null on auth/network/parse failure; callers should hide the
  /// referral surface in that case rather than show an error.
  static Future<ReferralInfo?> getInfo() async {
    final headers = _bearerHeaders();
    if (headers == null) return null;
    try {
      final resp = await http
          .get(Uri.parse('$_base/cabinet/referral'), headers: headers)
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return ReferralInfo.fromJson(json);
    } on Exception {
      return null;
    }
  }

  /// GET /cabinet/referral/terms — unauth endpoint. Used to surface the
  /// commission %/bonus even before the user has a JWT (e.g. on the marketing
  /// hero of the invite card).
  static Future<ReferralTerms?> getTerms() async {
    try {
      final resp = await http
          .get(Uri.parse('$_base/cabinet/referral/terms'),
              headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return ReferralTerms.fromJson(json);
    } on Exception {
      return null;
    }
  }
}
