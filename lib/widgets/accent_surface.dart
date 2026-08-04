import 'package:flutter/material.dart';

import '../main.dart' show DS;

/// Accent-tinted surfaces — the "tier 1" layer of our visual hierarchy.
///
/// The app deliberately uses three levels of surface, and the level carries
/// meaning: it tells the user what to look at first. Keeping that discipline
/// is what makes a screen read as designed rather than merely decorated —
/// if everything is tinted, nothing stands out.
///
///   **Tier 1** — [AccentCard]: accent gradient + accent border. Reserved for
///   the single most important surface on a screen (subscription status, the
///   connection card, a referral offer). One per screen. Two at most, and
///   only when they genuinely compete for attention.
///
///   **Tier 2** — flat `DS.surface1` + `DS.border`. Supporting content:
///   server rows, settings rows, list items, anything nested *inside* a
///   tier-1 card.
///
///   **Tier 3** — no fill. Dividers, page background, spacing.
///
/// The formula below was extracted from the two surfaces that already looked
/// right (the subscription status card and the home-screen referral card),
/// which had each grown their own copy of it.
class AccentCard extends StatelessWidget {
  /// Brand or semantic colour this surface is keyed to — `DS.violet` for
  /// brand moments, `DS.emerald`/`DS.rose`/`DS.amber` for status.
  final Color accent;

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// Renders the neutral tier-2 treatment instead (flat surface, grey
  /// border) while keeping the same geometry — for states where a card
  /// exists but has nothing worth accenting, e.g. "no subscription".
  final bool muted;

  const AccentCard({
    super.key,
    required this.accent,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = 18,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: muted ? null : DS.accentGradient(accent),
        color: muted ? DS.surface1 : null,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: muted ? DS.border : DS.accentBorderColor(accent),
          width: 0.5,
        ),
      ),
      child: child,
    );
  }
}

/// The tinted rounded square an icon sits in on a tier-1 surface.
class AccentIconBox extends StatelessWidget {
  final Color accent;
  final Widget icon;
  final double size;

  const AccentIconBox({
    super.key,
    required this.accent,
    required this.icon,
    this.size = 36,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(color: accent.withValues(alpha: 0.4)),
      ),
      child: Center(child: icon),
    );
  }
}

/// Small accent dot + uppercase tracked label — the status line at the top of
/// a tier-1 card ("АКТИВНА · 12 дней", "ИСТЕКЛА 3 марта").
class AccentStatusLabel extends StatelessWidget {
  final Color accent;
  final String label;

  /// Optional replacement for the plain dot — lets the caller pass an
  /// animated one without this widget having to know about it.
  final Widget? dot;

  const AccentStatusLabel({
    super.key,
    required this.accent,
    required this.label,
    this.dot,
  });

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      dot ??
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          label,
          style: TextStyle(
            color: accent,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
      ),
    ]);
  }
}
