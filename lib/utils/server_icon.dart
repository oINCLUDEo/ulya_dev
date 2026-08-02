import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../main.dart' show DS;
import '../models/server_node.dart';

/// Renders the right-hand icon for a server tile:
///   * auto-routed nodes  → indigo-tinted gradient with a lightning bolt
///   * known country code → CountryFlag widget
///   * unknown / empty CC → same auto-fallback bolt (avoids the white square
///                          CountryFlag draws for invalid ISO codes)
///
/// Centralised so home/servers/picker UIs all stay in sync. `width` and
/// `height` control the visual footprint; `radius` matches the surrounding
/// row's corner style.
Widget buildServerIcon(
  ServerNode? node, {
  double width = 36,
  double height = 26,
  double radius = 6,
}) {
  final isAuto = node?.protocol == 'auto';
  final cc = (node?.countryCode ?? '').trim();
  // Only treat ASCII letter pairs as a real ISO 3166-1 alpha-2 code. Anything
  // else (empty, "??", "EU", random punctuation from upstream) gets the auto
  // fallback so we never expose CountryFlag's blank placeholder.
  final hasValidCc = RegExp(r'^[A-Za-z]{2}$').hasMatch(cc);

  if (isAuto || !hasValidCc) {
    return Container(
      width: width, height: height,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1E1B4B), Color(0xFF1A1760)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: DS.indigoLight.withValues(alpha: 0.40)),
      ),
      child: Icon(PhosphorIconsFill.lightning,
          size: height * 0.62, color: DS.indigoLight),
    );
  }
  return CountryFlag.fromCountryCode(
    cc.toUpperCase(),
    theme: ImageTheme(
      width: width,
      height: height,
      shape: RoundedRectangle(radius + 2),
    ),
  );
}

/// Flag-only variant — handy when you need a flag for a country code without
/// having a `ServerNode` instance (e.g. group headers in the server picker).
/// Falls back to the indigo bolt placeholder for invalid codes, just like
/// [buildServerIcon].
Widget buildCountryFlagIcon(
  String countryCode, {
  double width = 22,
  double height = 16,
  double radius = 3,
}) {
  final cc = countryCode.trim();
  final hasValidCc = RegExp(r'^[A-Za-z]{2}$').hasMatch(cc);
  if (!hasValidCc) {
    return Container(
      width: width, height: height,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1E1B4B), Color(0xFF1A1760)],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: DS.indigoLight.withValues(alpha: 0.40)),
      ),
      child: Icon(PhosphorIconsFill.lightning,
          size: height * 0.62, color: DS.indigoLight),
    );
  }
  return CountryFlag.fromCountryCode(
    cc.toUpperCase(),
    theme: ImageTheme(
      width: width, height: height,
      shape: RoundedRectangle(radius + 2),
    ),
  );
}

/// A (icon, color) tag describing what a server is specialised for, guessed
/// from Remnawave's free-text `description` category label (e.g. "Белые
/// списки: YouTube, Telegram"). Purely a client-side heuristic — Remnawave
/// has no structured per-service tagging, so this just keyword-matches the
/// admin's category text. Returns an empty list for anything unrecognised
/// (most regular servers have no badges at all, which is fine).
List<(PhosphorIconData, Color)> purposeBadgesForDescription(String? description) {
  final d = (description ?? '').toLowerCase();
  if (d.isEmpty) return const [];

  final badges = <(PhosphorIconData, Color)>[];
  void add(bool cond, PhosphorIconData icon, Color color) {
    if (cond) badges.add((icon, color));
  }

  add(d.contains('youtube'), PhosphorIconsFill.youtubeLogo, const Color(0xFFFF4444));
  add(d.contains('telegram') || d.contains('телеграм'),
      PhosphorIconsFill.telegramLogo, const Color(0xFF29A9EB));
  add(d.contains('instagram') || d.contains('инстаграм'),
      PhosphorIconsFill.instagramLogo, const Color(0xFFE1306C));
  add(d.contains('whatsapp') || d.contains('вотсап') || d.contains('ватсап'),
      PhosphorIconsFill.whatsappLogo, const Color(0xFF25D366));
  add(d.contains('discord') || d.contains('дискорд'),
      PhosphorIconsFill.discordLogo, const Color(0xFF5865F2));
  add(d.contains('tiktok') || d.contains('тикток'),
      PhosphorIconsFill.tiktokLogo, const Color(0xFFEE1D52));
  add(d.contains('spotify') || d.contains('спотифай'),
      PhosphorIconsFill.spotifyLogo, const Color(0xFF1DB954));
  add(d.contains('steam') || d.contains('стим') && !d.contains('систем'),
      PhosphorIconsFill.steamLogo, const Color(0xFF66C0F4));
  add(d.contains('игр') || d.contains('game') || d.contains('гейм'),
      PhosphorIconsFill.gameController, const Color(0xFFFF6B3D));
  // Deliberately avoids the bare "ии" substring — it's the genitive/plural
  // ending of countless unrelated Russian nouns ("версии", "функции", …).
  add(d.contains('chatgpt') || d.contains('нейросет') ||
          d.contains('искусственн') || d.contains(' gpt') ||
          d.contains('openai') || d.contains('claude') || d.contains('gemini'),
      PhosphorIconsFill.robot, const Color(0xFF9D8FFF));

  return badges;
}

/// Compact row of small tinted icons for [purposeBadgesForDescription].
/// Returns a zero-size widget when there's nothing to show, so call sites
/// can splice it in unconditionally.
Widget buildPurposeBadges(String? description, {double size = 14, double gap = 5}) {
  final badges = purposeBadgesForDescription(description);
  if (badges.isEmpty) return const SizedBox.shrink();
  return Row(mainAxisSize: MainAxisSize.min, children: [
    for (int i = 0; i < badges.length; i++) ...[
      if (i > 0) SizedBox(width: gap),
      Icon(badges[i].$1, size: size, color: badges[i].$2),
    ],
  ]);
}

/// Localised country name for a known ISO 3166-1 alpha-2 code. Falls back to
/// the upper-cased code itself for anything we don't recognise — that keeps
/// the UI from looking broken while still being obviously a placeholder.
String countryNameForCode(String cc) {
  switch (cc.toUpperCase()) {
    case 'RU': return 'Россия';
    case 'BY': return 'Беларусь';
    case 'KZ': return 'Казахстан';
    case 'UA': return 'Украина';
    case 'AM': return 'Армения';
    case 'GE': return 'Грузия';
    case 'AZ': return 'Азербайджан';
    case 'KG': return 'Кыргызстан';
    case 'UZ': return 'Узбекистан';
    case 'TR': return 'Турция';
    case 'CY': return 'Кипр';
    case 'DE': return 'Германия';
    case 'NL': return 'Нидерланды';
    case 'FR': return 'Франция';
    case 'GB':
    case 'UK': return 'Великобритания';
    case 'IT': return 'Италия';
    case 'ES': return 'Испания';
    case 'PT': return 'Португалия';
    case 'PL': return 'Польша';
    case 'CZ': return 'Чехия';
    case 'SK': return 'Словакия';
    case 'AT': return 'Австрия';
    case 'CH': return 'Швейцария';
    case 'BE': return 'Бельгия';
    case 'SE': return 'Швеция';
    case 'NO': return 'Норвегия';
    case 'FI': return 'Финляндия';
    case 'DK': return 'Дания';
    case 'IE': return 'Ирландия';
    case 'RO': return 'Румыния';
    case 'BG': return 'Болгария';
    case 'HU': return 'Венгрия';
    case 'GR': return 'Греция';
    case 'EE': return 'Эстония';
    case 'LV': return 'Латвия';
    case 'LT': return 'Литва';
    case 'MD': return 'Молдова';
    case 'RS': return 'Сербия';
    case 'HR': return 'Хорватия';
    case 'SI': return 'Словения';
    case 'MK': return 'Северная Македония';
    case 'AL': return 'Албания';
    case 'BA': return 'Босния и Герцеговина';
    case 'XK': return 'Косово';
    case 'IS': return 'Исландия';
    case 'MT': return 'Мальта';
    case 'LU': return 'Люксембург';
    case 'US': return 'США';
    case 'CA': return 'Канада';
    case 'MX': return 'Мексика';
    case 'BR': return 'Бразилия';
    case 'AR': return 'Аргентина';
    case 'CL': return 'Чили';
    case 'JP': return 'Япония';
    case 'KR': return 'Южная Корея';
    case 'CN': return 'Китай';
    case 'HK': return 'Гонконг';
    case 'TW': return 'Тайвань';
    case 'SG': return 'Сингапур';
    case 'IN': return 'Индия';
    case 'ID': return 'Индонезия';
    case 'TH': return 'Таиланд';
    case 'VN': return 'Вьетнам';
    case 'PH': return 'Филиппины';
    case 'MY': return 'Малайзия';
    case 'AE': return 'ОАЭ';
    case 'SA': return 'Саудовская Аравия';
    case 'IL': return 'Израиль';
    case 'AU': return 'Австралия';
    case 'NZ': return 'Новая Зеландия';
    case 'ZA': return 'ЮАР';
    case 'EG': return 'Египет';
    default:   return cc.toUpperCase();
  }
}
