import 'package:flutter/material.dart';

class AppColors {
  // ── Base Background (CURRENT PURPLE SYSTEM) ─────────────────
  static const background = Color(0xFF150326);
  static const backgroundDeep = Color(0xFF07010D);
  static const neutralBackground = Color(0xFF0F0F1A);

  // ── Primary Brand (Dark Purple Core) ─────────────────────────
  static const primary = Color(0xFF311459);
  static const primaryDeep = Color(0xFF230640);
  static const primaryAccent = Color(0xFF43255F);

  // ── Surfaces / Cards (Purple) ────────────────────────────────
  static const surface = Color(0xFF1B0833);
  static const surfaceSoft = Color(0xFF230E40);
  static const surfaceElevated = Color(0xFF2B0F46);

  // ── Text (Current) ───────────────────────────────────────────
  static const textMain = Color(0xFFF2F2F2);
  static const textSecondary = Color(0xFF8C8498);
  static const textMuted = Color(0xFF6C6573);

  // ── States ────────────────────────────────────────────────────
  static const success = Color(0xFF2ED573);
  static const warning = Color(0xFFFFA502);
  static const danger = Color(0xFFE74C3C);

  // ──────────────────────────────────────────────────────────────
  // NEW: GRAPHITE SYSTEM (НЕ ЗАМЕНЯЕТ, А ДОБАВЛЯЕТ)
  // ──────────────────────────────────────────────────────────────

  // Base Neutral
  static const graphiteBackground = Color(0xFF0F1115);
  static const graphiteSurface = Color(0xFF171A21);
  static const graphiteElevated = Color(0xFF1F2430);

  // Neutral Accent
  static const accentSmoky = Color(0xFF5E6C8A);
  static const accentPlatinum = Color(0xFFC9D1D9);

  // Neutral Text
  static const textNeutralMain = Color(0xFFE6E9EF);
  static const textNeutralSecondary = Color(0xFF9CA3AF);
  static const textNeutralMuted = Color(0xFF6B7280);

  // Optional subtle gradient (neutral)
  static const gradientGraphite = LinearGradient(
    colors: [
      Color(0xFF0F1115),
      Color(0xFF171A21),
    ],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  // ── Existing Gradients (keep for header) ─────────────────────
  static const gradientDark = LinearGradient(
    colors: [
      Color(0xFF150326),
      Color(0xFF230640),
      Color(0xFF311459),
    ],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static const gradientAccent = LinearGradient(
    colors: [
      Color(0xFF230640),
      Color(0xFF43255F),
    ],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}