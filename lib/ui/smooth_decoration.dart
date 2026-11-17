import 'package:flutter/material.dart';

/// Рисует край заливки и рамки с одинаковым сглаживанием в физических пикселях.
/// Содержимое виджета рисуется отдельно: текст и значки не фильтруются.
const _edgePixels = 0.65;

double get _pixelRatio => WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;

Paint _edgePaint(Paint paint, double ratio, [double pixels = _edgePixels]) => Paint.from(paint)
  ..isAntiAlias = true
  ..maskFilter = MaskFilter.blur(BlurStyle.normal, pixels / ratio);

class SmoothBoxDecoration extends BoxDecoration {
  const SmoothBoxDecoration({
    super.color, super.image, super.border, super.borderRadius, super.boxShadow,
    super.gradient, super.backgroundBlendMode, super.shape,
  });

  factory SmoothBoxDecoration.from(BoxDecoration value) => SmoothBoxDecoration(
    color: value.color, image: value.image, border: value.border, borderRadius: value.borderRadius,
    boxShadow: value.boxShadow, gradient: value.gradient, backgroundBlendMode: value.backgroundBlendMode, shape: value.shape,
  );

  @override
  BoxDecoration? lerpFrom(Decoration? a, double t) => a == null || a is BoxDecoration
      ? SmoothBoxDecoration.from(BoxDecoration.lerp(a as BoxDecoration?, this, t)!)
      : super.lerpFrom(a, t);

  @override
  BoxDecoration? lerpTo(Decoration? b, double t) => b == null || b is BoxDecoration
      ? SmoothBoxDecoration.from(BoxDecoration.lerp(this, b as BoxDecoration?, t)!)
      : super.lerpTo(b, t);

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) {
    final outline = border;
    if ((shape == BoxShape.rectangle && (borderRadius == null || borderRadius == BorderRadius.zero)) ||
        image != null || (outline != null && (outline is! Border || !outline.isUniform))) {
      return super.createBoxPainter(onChanged);
    }
    return _SmoothBoxPainter(this, outline is Border ? outline.top : null, onChanged);
  }
}

class _SmoothBoxPainter extends BoxPainter {
  _SmoothBoxPainter(this.decoration, this.side, VoidCallback? onChanged)
      : shadows = BoxDecoration(
          borderRadius: decoration.borderRadius, boxShadow: decoration.boxShadow, shape: decoration.shape,
        ).createBoxPainter(onChanged),
        super(onChanged);
  final SmoothBoxDecoration decoration;
  final BorderSide? side;
  final BoxPainter shadows;

  void _draw(Canvas canvas, Rect rect, TextDirection? direction, Paint paint, {double inflation = 0}) {
    if (decoration.shape == BoxShape.circle) {
      final diameter = rect.shortestSide;
      canvas.drawOval(Rect.fromCenter(center: rect.center, width: diameter, height: diameter).inflate(inflation), paint);
    } else {
      canvas.drawRRect(decoration.borderRadius!.resolve(direction).toRRect(rect).inflate(inflation), paint);
    }
  }

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    shadows.paint(canvas, offset, configuration);
    final rect = offset & configuration.size!;
    final ratio = configuration.devicePixelRatio ?? 1;
    final direction = configuration.textDirection;
    if (decoration.color != null || decoration.gradient != null) {
      final paint = Paint()..color = decoration.color ?? Colors.white;
      if (decoration.gradient != null) paint.shader = decoration.gradient!.createShader(rect, textDirection: direction);
      if (decoration.backgroundBlendMode != null) paint.blendMode = decoration.backgroundBlendMode!;
      _draw(canvas, rect, direction, _edgePaint(paint, ratio));
    }
    final outline = side;
    if (outline != null && outline.style != BorderStyle.none && outline.width > 0) {
      _draw(canvas, rect, direction, _edgePaint(outline.toPaint(), ratio), inflation: outline.strokeOffset / 2);
    }
  }

  @override
  void dispose() { shadows.dispose(); super.dispose(); }
}

/// Такой же контур для Material-диалогов, кнопок и других ShapeDecoration.
class SmoothRoundedRectangleBorder extends RoundedRectangleBorder {
  const SmoothRoundedRectangleBorder({super.side, super.borderRadius, this.edgeSigma = _edgePixels});
  final double edgeSigma;

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width == 0) return;
    canvas.drawRRect(
      borderRadius.resolve(textDirection).toRRect(rect).inflate(side.strokeOffset / 2),
      _edgePaint(side.toPaint(), _pixelRatio, edgeSigma),
    );
  }

  @override
  void paintInterior(Canvas canvas, Rect rect, Paint paint, {TextDirection? textDirection}) {
    canvas.drawRRect(borderRadius.resolve(textDirection).toRRect(rect), _edgePaint(paint, _pixelRatio, edgeSigma));
  }

  @override
  SmoothRoundedRectangleBorder copyWith({BorderSide? side, BorderRadiusGeometry? borderRadius}) =>
      SmoothRoundedRectangleBorder(side: side ?? this.side, borderRadius: borderRadius ?? this.borderRadius, edgeSigma: edgeSigma);

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is RoundedRectangleBorder) return SmoothRoundedRectangleBorder(
      side: BorderSide.lerp(a.side, side, t),
      borderRadius: BorderRadiusGeometry.lerp(a.borderRadius, borderRadius, t)!,
      edgeSigma: a is SmoothRoundedRectangleBorder ? a.edgeSigma + (edgeSigma - a.edgeSigma) * t : edgeSigma,
    );
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is RoundedRectangleBorder) return SmoothRoundedRectangleBorder(
      side: BorderSide.lerp(side, b.side, t),
      borderRadius: BorderRadiusGeometry.lerp(borderRadius, b.borderRadius, t)!,
      edgeSigma: b is SmoothRoundedRectangleBorder ? edgeSigma + (b.edgeSigma - edgeSigma) * t : edgeSigma,
    );
    return super.lerpTo(b, t);
  }

  @override
  bool operator ==(Object other) => other is SmoothRoundedRectangleBorder &&
      other.side == side && other.borderRadius == borderRadius && other.edgeSigma == edgeSigma;
  @override
  int get hashCode => Object.hash(side, borderRadius, edgeSigma);
}

/// Сохраняет стандартное построение разрыва рамки под плавающей подписью поля.
class SmoothOutlineInputBorder extends OutlineInputBorder {
  SmoothOutlineInputBorder({
    BorderSide borderSide = const BorderSide(), super.borderRadius, super.gapPadding,
  }) : super(borderSide: _SmoothBorderSide(borderSide));

  @override
  bool get preferPaintInterior => true;

  @override
  void paintInterior(Canvas canvas, Rect rect, Paint paint, {TextDirection? textDirection}) {
    canvas.drawRRect(borderRadius.toRRect(rect), _edgePaint(paint, _pixelRatio));
  }

  @override
  SmoothOutlineInputBorder copyWith({BorderSide? borderSide, BorderRadius? borderRadius, double? gapPadding}) =>
      SmoothOutlineInputBorder(borderSide: borderSide ?? this.borderSide,
          borderRadius: borderRadius ?? this.borderRadius, gapPadding: gapPadding ?? this.gapPadding);

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) => _wrap(super.lerpFrom(a, t));
  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) => _wrap(super.lerpTo(b, t));

  ShapeBorder? _wrap(ShapeBorder? value) => value is OutlineInputBorder
      ? SmoothOutlineInputBorder(borderSide: value.borderSide, borderRadius: value.borderRadius, gapPadding: value.gapPadding)
      : value;
}

class _SmoothBorderSide extends BorderSide {
  _SmoothBorderSide(BorderSide side) : super(color: side.color, width: side.width, style: side.style, strokeAlign: side.strokeAlign);
  @override
  Paint toPaint() {
    return _edgePaint(super.toPaint(), _pixelRatio);
  }
}