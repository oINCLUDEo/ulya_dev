import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:qr_flutter/qr_flutter.dart';

import '../services/referral_service.dart';

/// Decode a bundled asset into a [ui.Image] (null on any failure — the card
/// then falls back to a vector glyph so rendering never breaks).
Future<ui.Image?> _loadAssetImage(String path) async {
  try {
    final data = await rootBundle.load(path);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    return frame.image;
  } catch (_) {
    return null;
  }
}

/// Renders a shareable referral invite card as a PNG (1080×1350, 4:5 — the
/// sweet spot for messengers and stories).
///
/// Visual language mirrors the app: deep #0A0A0F background, violet/cyan
/// aurora glows, a white glass QR card and the referral code in a gold pill.
/// Everything is drawn directly on a [Canvas] — no widget tree, no
/// BuildContext, safe to call from anywhere.
///
/// The vertical layout is driven by a running `y` cursor so blocks always
/// stack with real gaps and never overlap (the previous fixed-offset version
/// collided the footer with the code pill).
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

  // VPN app icon used as the brand mark (replaces the old lightning bolt).
  final brandIcon = await _loadAssetImage('assets/image/app_icon.png');

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
  glow(const Offset(950, 360), 420, cyan, 0.22);
  glow(const Offset(540, 1290), 520, violet, 0.30);
  glow(const Offset(120, 1080), 300, gold, 0.10);

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

  // Vertical cursor — every block advances it, so nothing overlaps.
  var y = 64.0;

  // ── Brand pill ─────────────────────────────────────────────────────────────
  final brand = tp(
    'ULYA VPN',
    const TextStyle(
      color: textPrimary,
      fontSize: 34,
      fontWeight: FontWeight.w800,
      letterSpacing: 6,
    ),
  );
  const pillH = 84.0;
  const iconSize = 50.0;
  const iconGap = 18.0;
  // pill width = side padding + icon + gap + wordmark + side padding
  final pillW = 52 + iconSize + iconGap + brand.width + 52;
  final pillLeft = (w - pillW) / 2;
  final pillRect = RRect.fromRectAndRadius(
    Rect.fromLTWH(pillLeft, y, pillW, pillH),
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
  // VPN app icon (rounded) to the left of the wordmark.
  final iconRect = Rect.fromLTWH(
      pillLeft + 52, y + (pillH - iconSize) / 2, iconSize, iconSize);
  if (brandIcon != null) {
    final rrect =
        RRect.fromRectAndRadius(iconRect, const Radius.circular(12));
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawImageRect(
      brandIcon,
      Rect.fromLTWH(0, 0, brandIcon.width.toDouble(), brandIcon.height.toDouble()),
      iconRect,
      Paint()..filterQuality = FilterQuality.high,
    );
    canvas.restore();
  } else {
    // Fallback: a small shield glyph in brand violet.
    final sx = iconRect.left, sy = iconRect.top, sw = iconSize;
    final shield = Path()
      ..moveTo(sx + sw / 2, sy)
      ..lineTo(sx + sw, sy + sw * 0.18)
      ..lineTo(sx + sw, sy + sw * 0.55)
      ..quadraticBezierTo(sx + sw, sy + sw * 0.9, sx + sw / 2, sy + sw)
      ..quadraticBezierTo(sx, sy + sw * 0.9, sx, sy + sw * 0.55)
      ..lineTo(sx, sy + sw * 0.18)
      ..close();
    canvas.drawPath(shield, Paint()..color = violet);
  }
  brand.paint(
      canvas,
      Offset(pillLeft + 52 + iconSize + iconGap,
          y + (pillH - brand.height) / 2));
  y += pillH + 48;

  // ── Headline ───────────────────────────────────────────────────────────────
  final headline = tp(
    'Дарю интернет\nбез границ',
    const TextStyle(
      color: textPrimary,
      fontSize: 84,
      fontWeight: FontWeight.w800,
      height: 1.12,
      letterSpacing: -1.5,
    ),
  );
  drawCentered(headline, y);
  y += headline.height + 22;

  final sub = tp(
    'Подключайся по моему коду —\nполучишь бонус при регистрации',
    const TextStyle(
      color: textSecondary,
      fontSize: 35,
      fontWeight: FontWeight.w500,
      height: 1.4,
    ),
  );
  drawCentered(sub, y);
  y += sub.height + 44;

  // ── QR glass card ──────────────────────────────────────────────────────────
  const cardW = 420.0;
  const cardH = 420.0;
  final cardX = (w - cardW) / 2;
  final cardRect = RRect.fromRectAndRadius(
    Rect.fromLTWH(cardX, y, cardW, cardH),
    const Radius.circular(40),
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
  const qrSize = 344.0;
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
  canvas.translate((w - qrSize) / 2, y + (cardH - qrSize) / 2);
  qr.paint(canvas, const Size(qrSize, qrSize));
  canvas.restore();
  y += cardH + 40;

  // ── Referral code pill (label + code stacked inside) ────────────────────────
  const codeH = 142.0;
  final code = tp(
    info.referralCode.toUpperCase(),
    const TextStyle(
      color: textPrimary,
      fontSize: 52,
      fontWeight: FontWeight.w800,
      letterSpacing: 9,
      fontFeatures: [ui.FontFeature.tabularFigures()],
    ),
  );
  final label = tp(
    'ТВОЙ КОД',
    TextStyle(
      color: gold.withValues(alpha: 0.95),
      fontSize: 25,
      fontWeight: FontWeight.w700,
      letterSpacing: 5,
    ),
  );
  final codeW = math.max(code.width, label.width) + 150;
  final codeRect = RRect.fromRectAndRadius(
    Rect.fromLTWH((w - codeW) / 2, y, codeW, codeH),
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
  drawCentered(label, y + 26);
  drawCentered(code, y + 26 + label.height + 6);
  y += codeH + 30;

  // ── Footer ─────────────────────────────────────────────────────────────────
  final footer = tp(
    'Сканируй камерой — установка за минуту',
    const TextStyle(color: textSecondary, fontSize: 29, fontWeight: FontWeight.w500),
  );
  drawCentered(footer, y);

  // ── Encode ─────────────────────────────────────────────────────────────────
  final picture = recorder.endRecording();
  final image = await picture.toImage(w.toInt(), h.toInt());
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return byteData?.buffer.asUint8List();
}
