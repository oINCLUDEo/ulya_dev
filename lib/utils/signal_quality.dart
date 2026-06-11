import 'package:flutter/material.dart';

import '../main.dart' show DS;

/// Quality bucket — how many bars to light up + which accent colour.
///
/// Shared by the home connection-card indicator (`_SignalBars`) and the
/// servers-list quality badge (`_QualityBars`). Both screens MUST resolve
/// the same number of bars for the same RTT, otherwise the user sees their
/// selected server reading 3 bars on one screen and 2 on another.
class SignalQuality {
  final int activeBars; // 0..4
  final Color color;
  const SignalQuality(this.activeBars, this.color);
}

/// Maps a TCP RTT (or the `null` "never measured" sentinel and the `-1`
/// "probe failed" sentinel) into a [SignalQuality].
///
/// Buckets (ms):
///   <80   → 4 bars emerald  (отлично)
///   <180  → 3 bars emerald  (хорошо)
///   <320  → 2 bars amber    (слабо)
///   ≥320  → 1 bar  rose     (очень слабо)
///   -1    → 1 bar  rose     (нет связи)
///   null  → 0 bars textMuted (нет данных)
///
/// Loading/in-flight markers (-2) and "is this an auto-routed host" are
/// out of scope — callers decide how to render those visually.
SignalQuality signalQualityFromPing(int? ping) {
  if (ping == null) return const SignalQuality(0, DS.textMuted);
  if (ping < 0)    return const SignalQuality(1, DS.rose);
  if (ping < 80)   return const SignalQuality(4, DS.emerald);
  if (ping < 180)  return const SignalQuality(3, DS.emerald);
  if (ping < 320)  return const SignalQuality(2, DS.amber);
  return            const SignalQuality(1, DS.rose);
}
