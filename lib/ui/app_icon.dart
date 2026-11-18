import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'theme.dart';
import '../l10n/l10n.dart';

/// Вид значка SkipIt (Настройки → Внешний вид → «Значок»): окно, трей и значок в меню. Кнопку на панели задач Windows 11 рисует по exe — её не поменять.
/// Классический — картинка из ресурсов exe; остальные программа рисует сама той же формы.
enum IconStyle {
  classic('Классический'),
  accent('Цвет акцента'),
  light('Светлый'),
  bright('Яркий'),
  mono('Монохромный');

  const IconStyle(this._label);
  final String _label;
  String get label => tr(_label);
}

/// Значок SkipIt той же формы, что рисует tools/make_icon.ps1: скруглённый квадрат и знак ▶▶,
/// у второго треугольника выемка под кончик первого.
class SkipItIconPainter extends CustomPainter {
  SkipItIconPainter(this.style, this.accent);
  final IconStyle style;
  final Accent accent;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final a = style == IconStyle.classic ? Accent.orange : accent;
    final dark = style != IconStyle.light && style != IconStyle.bright;

    // Фон: скруглённый квадрат с едва заметной рамкой.
    final m = s * 0.04;
    final box = Rect.fromLTWH(m, m, s - 2 * m, s - 2 * m);
    final back = RRect.fromRectAndRadius(box, Radius.circular(s * 0.24));
    final fill = Paint()..isAntiAlias = true;
    if (style == IconStyle.bright) {
      fill.shader = LinearGradient(colors: [a.light, a.main], begin: Alignment.topLeft, end: Alignment.bottomRight)
          .createShader(box);
    } else {
      fill.color = dark ? const Color(0xFF0C0C0E) : Colors.white;
    }
    canvas.drawRRect(back, fill);
    if (style != IconStyle.bright) {
      canvas.drawRRect(
          back,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = s * 0.012
            ..color = dark ? const Color(0xFF2C2C32) : const Color(0xFFE1E1E6));
    }

    // Знак.
    final w = s * 0.50, h = w * 0.72, r = h * 0.12;
    final x0 = (s - w) / 2 + s * 0.02, y0 = (s - h) / 2 + s * 0.01;
    final white = style == IconStyle.bright || style == IconStyle.mono;
    final shader = white
        ? null
        : LinearGradient(colors: [a.light, a.main])
            .createShader(Rect.fromPoints(Offset(x0, y0), Offset(x0 + w, y0 + h)));
    Paint mark(PaintingStyle paintStyle) => Paint()
      ..isAntiAlias = true
      ..style = paintStyle
      ..strokeWidth = r * 2
      ..strokeJoin = StrokeJoin.round
      ..color = Colors.white
      ..shader = shader;
    void triangle(double x) {
      final path = Path()
        ..moveTo(x + r, y0 + r)
        ..lineTo(x + w / 2 - r, y0 + h / 2)
        ..lineTo(x + r, y0 + h - r)
        ..close();
      canvas
        ..drawPath(path, mark(PaintingStyle.fill))
        ..drawPath(path, mark(PaintingStyle.stroke));
    }

    // Второй треугольник — на своём слое, с вырезанным кругом под кончик первого.
    canvas.saveLayer(Offset.zero & size, Paint());
    triangle(x0 + w / 2);
    canvas.drawCircle(Offset(x0 + w / 2, y0 + h / 2), w * 0.065, Paint()..blendMode = BlendMode.clear);
    canvas.restore();
    triangle(x0);
  }

  @override
  bool shouldRepaint(SkipItIconPainter old) => old.style != style || old.accent != accent;
}

/// Размеры картинок для значка окна и трея: Windows берёт ближайшую под свой масштаб экрана.
/// 256 — для крупного значка в уведомлении над треем (≈105 точек при 125 %): уменьшать чётче, чем растягивать.
const iconSizes = [16, 20, 24, 32, 40, 48, 64, 96, 256];

/// Картинки значка [style] всех размеров [iconSizes] — пиксели RGBA без предумножения альфы.
Future<List<({int size, Uint8List rgba})>> renderIcon(IconStyle style, Accent accent) async {
  final images = <({int size, Uint8List rgba})>[];
  for (final size in iconSizes) {
    final recorder = ui.PictureRecorder();
    SkipItIconPainter(style, accent).paint(Canvas(recorder), Size.square(size.toDouble()));
    final image = await recorder.endRecording().toImage(size, size);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    image.dispose();
    if (data != null) images.add((size: size, rgba: data.buffer.asUint8List()));
  }
  return images;
}
