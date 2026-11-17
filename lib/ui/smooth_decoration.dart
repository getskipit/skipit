import 'package:flutter/material.dart';

/// Сглаживает только тонкую рамку, сохраняя резкость содержимого и исходную геометрию.
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
    if (shape != BoxShape.rectangle || borderRadius == null || outline is! Border ||
        !outline.isUniform || outline.top.style == BorderStyle.none || outline.top.width == 0) {
      return super.createBoxPainter(onChanged);
    }
    return _SmoothBoxPainter(this, outline.top, onChanged);
  }
}

class _SmoothBoxPainter extends BoxPainter {
  _SmoothBoxPainter(this.decoration, this.side, VoidCallback? onChanged)
      : background = BoxDecoration(
          color: decoration.color, image: decoration.image, borderRadius: decoration.borderRadius,
          boxShadow: decoration.boxShadow, gradient: decoration.gradient,
          backgroundBlendMode: decoration.backgroundBlendMode, shape: decoration.shape,
        ).createBoxPainter(onChanged),
        super(onChanged);
  final SmoothBoxDecoration decoration;
  final BorderSide side;
  final BoxPainter background;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    background.paint(canvas, offset, configuration);
    final rect = offset & configuration.size!;
    final sigma = 0.5 / (configuration.devicePixelRatio ?? 1);
    canvas.drawRRect(
      decoration.borderRadius!.resolve(configuration.textDirection).toRRect(rect).inflate(side.strokeOffset / 2),
      side.toPaint()..isAntiAlias = true..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma),
    );
  }

  @override
  void dispose() { background.dispose(); super.dispose(); }
}

/// Такой же контур для Material-диалогов, кнопок и других ShapeDecoration.
class SmoothRoundedRectangleBorder extends RoundedRectangleBorder {
  const SmoothRoundedRectangleBorder({super.side, super.borderRadius, this.edgeSigma = 0.5});
  final double edgeSigma;

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width == 0) return;
    canvas.drawRRect(
      borderRadius.resolve(textDirection).toRRect(rect).inflate(side.strokeOffset / 2),
      side.toPaint()..isAntiAlias = true..maskFilter = MaskFilter.blur(BlurStyle.normal, edgeSigma),
    );
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
    final ratio = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    return super.toPaint()..isAntiAlias = true..maskFilter = MaskFilter.blur(BlurStyle.normal, 0.5 / ratio);
  }
}