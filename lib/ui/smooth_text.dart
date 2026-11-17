import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Двойная детализация только букв: размер в раскладке остаётся прежним.
/// Уменьшение фильтруется отдельно от панелей, значков и остальных элементов.
class SmoothText extends StatelessWidget {
  const SmoothText(this.data, {super.key, this.style, this.textAlign, this.maxLines, this.overflow});

  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) => _TextSampling(
    child: Text(data, style: style, textAlign: textAlign, maxLines: maxLines, overflow: overflow,
      textScaler: _SamplingScaler(MediaQuery.textScalerOf(context))),
  );
}

class _SamplingScaler extends TextScaler {
  const _SamplingScaler(this.parent);
  final TextScaler parent;

  @override
  double scale(double fontSize) => parent.scale(fontSize) * 2;
  @override
  double get textScaleFactor => parent.scale(14) / 7;
}

class _TextSampling extends SingleChildRenderObjectWidget {
  const _TextSampling({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTextSampling();
}

class _RenderTextSampling extends RenderTransform {
  _RenderTextSampling() : super(
    transform: Matrix4.diagonal3Values(0.5, 0.5, 1),
    filterQuality: FilterQuality.medium,
  );

  @override
  void performLayout() {
    if (child == null) { size = constraints.smallest; return; }
    child!.layout(constraints * 2, parentUsesSize: true);
    size = constraints.constrain(child!.size / 2);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain((child?.getDryLayout(constraints * 2) ?? Size.zero) / 2);

  @override
  double computeMinIntrinsicWidth(double height) => (child?.getMinIntrinsicWidth(height * 2) ?? 0) / 2;
  @override
  double computeMaxIntrinsicWidth(double height) => (child?.getMaxIntrinsicWidth(height * 2) ?? 0) / 2;
  @override
  double computeMinIntrinsicHeight(double width) => (child?.getMinIntrinsicHeight(width * 2) ?? 0) / 2;
  @override
  double computeMaxIntrinsicHeight(double width) => (child?.getMaxIntrinsicHeight(width * 2) ?? 0) / 2;

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    final distance = child?.getDistanceToActualBaseline(baseline);
    return distance == null ? null : distance / 2;
  }

  @override
  double? computeDryBaseline(BoxConstraints constraints, TextBaseline baseline) {
    final distance = child?.getDryBaseline(constraints * 2, baseline);
    return distance == null ? null : distance / 2;
  }
}
