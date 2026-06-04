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
