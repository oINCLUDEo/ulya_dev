import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/referral_service.dart';

/// Renders a shareable referral invite card as a PNG (1080×1350, 4:5 — the
/// sweet spot for messengers and stories).
///
/// Visual language mirrors the app: deep #0A0A0F background, violet/cyan
/// aurora glows, glass card with the QR code and the referral code in a
/// monospace pill. Everything is drawn directly on a [Canvas] — no widget
/// tree, no BuildContext, safe to call from anywhere.
Future<Uint8List?> renderReferralCardPng(ReferralInfo info) async {
  const w = 1080.0;
  const h = 1350.0;

  const bg = Color(0xFF0A0A0F);
  const violet = Color(0xFF7C6BFF);
  const cyan = Color(0xFF22D3EE);
  const gold = Color(0xFFD4A84B);
  const textPrimary = Colors.white;
  const textSecondary = Color(0xFFA8A8B8);

  final link = info.botReferralLink.isNotEmpty
      ? info.botReferralLink
      : info.referralLink;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));

  // ── Background ─────────────────────────────────────────────────────────────
  canvas.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = bg);

  void glow(Offset center, double radius, Color color, double alpha) {
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = ui.Gradient.radial(center, radius, [
          color.withValues(alpha: alpha),
          color.withValues(alpha: 0),
        ]),
    );
  }

  glow(const Offset(170, 180), 480, violet, 0.45);
  glow(const Offset(950, 380), 420, cyan, 0.22);
  glow(const Offset(540, 1280), 520, violet, 0.30);
  glow(const Offset(120, 1100), 300, gold, 0.10);

  // Sprinkle of tiny stars.
  final rnd = math.Random(7);
  for (var i = 0; i < 46; i++) {
    final x = rnd.nextDouble() * w;
    final y = rnd.nextDouble() * h;
    final r = 1.0 + rnd.nextDouble() * 1.8;
    canvas.drawCircle(
      Offset(x, y),
      r,
      Paint()..color = Colors.white.withValues(alpha: 0.05 + rnd.nextDouble() * 0.12),
    );
  }

  // Thin rounded frame.
  canvas.drawRRect(
    RRect.fromRectAndRadius(
        const Rect.fromLTWH(28, 28, w - 56, h - 56), const Radius.circular(48)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.10),
  );

  // ── Text helpers ───────────────────────────────────────────────────────────
  TextPainter tp(String text, TextStyle style,
      {TextAlign align = TextAlign.center, double maxWidth = w - 160}) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: align,
      textDirection: TextDirection.ltr,
      maxLines: 3,
    )..layout(maxWidth: maxWidth);
    return painter;
  }

  void drawCentered(TextPainter painter, double y) =>
      painter.paint(canvas, Offset((w - painter.width) / 2, y));

  // ── Brand pill ─────────────────────────────────────────────────────────────
  const pillY = 96.0;
  final brand = tp(
    'ULYA VPN',
    const TextStyle(
      color: textPrimary,
      fontSize: 34,
      fontWeight: FontWeight.w800,
      letterSpacing: 6,
    ),
  );
  final pillW = brand.width + 150;
  final pillRect = RRect.fromRectAndRadius(
    Rect.fromLTWH((w - pillW) / 2, pillY, pillW, 84),
    const Radius.circular(42),
  );
  canvas.drawRRect(pillRect, Paint()..color = violet.withValues(alpha: 0.16));
  canvas.drawRRect(
    pillRect,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = violet.withValues(alpha: 0.55),
  );
  // Lightning bolt to the left of the wordmark.
  final boltX = (w - pillW) / 2 + 52;
  const boltY = pillY + 18.0;
  final bolt = Path()
    ..moveTo(boltX + 14, boltY)
    ..lineTo(boltX, boltY + 27)
    ..lineTo(boltX + 11, boltY + 27)
    ..lineTo(boltX + 8, boltY + 48)
    ..lineTo(boltX + 24, boltY + 20)
    ..lineTo(boltX + 13, boltY + 20)
    ..close();
  canvas.drawPath(bolt, Paint()..color = gold);
  brand.paint(
      canvas, Offset((w - pillW) / 2 + 92, pillY + (84 - brand.height) / 2));

  // ── Headline ───────────────────────────────────────────────────────────────
  final headline = tp(
    'Дарю интернет\nбез границ',
    const TextStyle(
      color: textPrimary,
      fontSize: 88,
      fontWeight: FontWeight.w800,
      height: 1.12,
      letterSpacing: -1.5,
    ),
  );
  drawCentered(headline, 248);

  final sub = tp(
    'Подключайся по моему коду —\nполучишь бонус при регистрации',
    const TextStyle(
      color: textSecondary,
      fontSize: 38,
      fontWeight: FontWeight.w500,
      height: 1.4,
    ),
  );
  drawCentered(sub, 478);

  // ── QR glass card ──────────────────────────────────────────────────────────
  const cardW = 520.0;
  const cardH = 520.0;
  const cardY = 632.0;
  final cardRect = RRect.fromRectAndRadius(
    Rect.fromLTWH((w - cardW) / 2, cardY, cardW, cardH),
    const Radius.circular(44),
  );
  // Soft violet halo behind the card.
  canvas.drawRRect(
    cardRect.inflate(18),
    Paint()
      ..color = violet.withValues(alpha: 0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 42),
  );
  canvas.drawRRect(cardRect, Paint()..color = Colors.white);

  // QR code (dark modules on white for maximum scanner contrast).
  const qrSize = 416.0;
  final qr = QrPainter(
    data: link,
    version: QrVersions.auto,
    gapless: true,
    eyeStyle: const QrEyeStyle(
      eyeShape: QrEyeShape.circle,
      color: Color(0xFF14101F),
    ),
    dataModuleStyle: const QrDataModuleStyle(
      dataModuleShape: QrDataModuleShape.circle,
      color: Color(0xFF14101F),
    ),
  );
  canvas.save();
  canvas.translate((w - qrSize) / 2, cardY + (cardH - qrSize) / 2);
  qr.paint(canvas, const Size(qrSize, qrSize));
  canvas.restore();

  // ── Referral code pill ─────────────────────────────────────────────────────
  const codeY = cardY + cardH + 56;
  final code = tp(
    info.referralCode.toUpperCase(),
    const TextStyle(
      color: textPrimary,
      fontSize: 56,
      fontWeight: FontWeight.w800,
      letterSpacing: 10,
      fontFeatures: [ui.FontFeature.tabularFigures()],
    ),
  );
  final label = tp(
    'ТВОЙ КОД',
    TextStyle(
      color: gold.withValues(alpha: 0.95),
      fontSize: 26,
      fontWeight: FontWeight.w700,
      letterSpacing: 5,
    ),
  );
  final codeW = math.max(code.width, label.width) + 140;
  final codeRect = RRect.fromRectAndRadius(
    Rect.fromLTWH((w - codeW) / 2, codeY, codeW, 150),
    const Radius.circular(34),
  );
  canvas.drawRRect(codeRect, Paint()..color = Colors.white.withValues(alpha: 0.06));
  canvas.drawRRect(
    codeRect,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = gold.withValues(alpha: 0.45),
  );
  drawCentered(label, codeY + 26);
  drawCentered(code, codeY + 62);

  // ── Footer ─────────────────────────────────────────────────────────────────
  final footer = tp(
    'Сканируй камерой — установка за минуту',
    const TextStyle(color: textSecondary, fontSize: 32, fontWeight: FontWeight.w500),
  );
  drawCentered(footer, h - 130);

  // ── Encode ─────────────────────────────────────────────────────────────────
  final picture = recorder.endRecording();
  final image = await picture.toImage(w.toInt(), h.toInt());
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return byteData?.buffer.asUint8List();
}
