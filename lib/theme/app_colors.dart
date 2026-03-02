import 'package:flutter/material.dart';

class AppColors {
  // ── Base Background ─────────────────
  static const background = Color(0xFF150326);
  static const backgroundDeep = Color(0xFF07010D);

  // ── Primary Brand (Dark Purple Core) ─
  static const primary = Color(0xFF311459);
  static const primaryDeep = Color(0xFF230640);
  static const primaryAccent = Color(0xFF43255F); // холодный акцент

  // ── Surfaces / Cards ────────────────
  static const surface = Color(0xFF1B0833);
  static const surfaceSoft = Color(0xFF230E40);
  static const surfaceElevated = Color(0xFF2B0F46);

  // ── Text ────────────────────────────
  static const textMain = Color(0xFFF2F2F2);
  static const textSecondary = Color(0xFF8C8498);
  static const textMuted = Color(0xFF6C6573);

  // ── States ──────────────────────────
  static const success = Color(0xFF2ED573);
  static const warning = Color(0xFFFFA502);
  static const danger = Color(0xFFE74C3C);

  // ── Premium subtle gradient (dark) ──
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