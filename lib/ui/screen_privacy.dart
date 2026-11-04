import 'package:flutter/material.dart';
import '../core/screen_privacy.dart';
import '../state/app_scope.dart';

bool screenPrivacyOf(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<AppScope>()?.state.screenPrivacy ?? false;

String screenTextOf(BuildContext context, String text) =>
    context.dependOnInheritedWidgetOfExactType<AppScope>()?.state.screenText(text) ?? text;

/// Показывает замаскированный текст, сохраняя исходное значение и позиции курсора.
class ScreenPrivacyController extends TextEditingController {
  ScreenPrivacyController({required super.text, required this.hidden});
  final bool Function() hidden;

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    if (!hidden()) return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    return TextSpan(style: style, text: hideScreenAddresses(text, preserveLength: true));
  }
}
