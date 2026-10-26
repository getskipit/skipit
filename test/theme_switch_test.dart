import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/l10n/l10n.dart';
import 'package:skipit/main.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/theme.dart';

/// Смена темы перекрашивает окно, не пересоздавая его: открытый раздел и состояние виджетов сохраняются.
void main() {
  // Настоящий ввод-вывод — вне testWidgets: внутри него время поддельное, и чтение диска не завершилось бы.
  setUpAll(AppPaths.init);

  testWidgets('смена темы перекрашивает окно на месте', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState()..settings.theme = AppTheme.dark;
    state.routingProfiles.add(RoutingProfile.global());
    await tester.pumpWidget(SkipItApp(state: state));
    await tester.pump(const Duration(milliseconds: 300));
    Color background() => tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor!;
    expect(background(), Palette.dark.bg);
    // Встроенные подписи Flutter — на русском (подсказка кнопки закрытия уведомления и т. п.).
    expect(MaterialLocalizations.of(tester.element(find.byType(Scaffold).first)).closeButtonTooltip, 'Закрыть');

    // Открываем «Настройки» и переключаем тему — раздел должен остаться открытым.
    await tester.tap(find.byIcon(Icons.tune_rounded).first);
    await tester.pump(const Duration(milliseconds: 300));
    state.settings.theme = AppTheme.light;
    state.openPage(state.pageIndex);
    await tester.pump();
    // Цвет текста из темы Flutter меняется сразу вместе с фоном, а не догоняет его: иначе на середине
    // перехода названия строк — белые на уже светлом фоне.
    await tester.pump(const Duration(milliseconds: 50));
    Color textColor() => Theme.of(tester.element(find.byType(Scaffold).first)).textTheme.bodyMedium!.color!;
    expect(textColor(), Palette.light.text);
    await tester.pump(const Duration(milliseconds: 400));
    expect(background(), Palette.light.bg);
    expect(state.pageIndex, AppState.settingsPage);
    expect(tester.takeException(), isNull);

    state.settings.theme = AppTheme.dark;
    state.openPage(state.pageIndex);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(textColor(), Palette.dark.text);
    await tester.pump(const Duration(milliseconds: 400));
    expect(background(), Palette.dark.bg);
    C.use(Palette.dark);
  });

  testWidgets('смена языка: снимок прежнего окна плавно тает, с «Меньше анимаций» — сразу', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => lang = Lang.ru);

    final state = AppState()..settings.language = 'ru';
    state.routingProfiles.add(RoutingProfile.global());
    await tester.pumpWidget(SkipItApp(state: state));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byIcon(Icons.tune_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Настройки'), findsWidgets);

    double shotOpacity() => tester
        .widget<FadeTransition>(find.ancestor(of: find.byKey(const ValueKey('lang-shot')), matching: find.byType(FadeTransition)).first)
        .opacity
        .value;

    state.settings.language = 'en';
    state.openPage(state.pageIndex);
    await tester.pump();
    expect(find.byKey(const ValueKey('lang-shot')), findsOneWidget);
    expect(find.text('Settings'), findsWidgets);
    await tester.pump(const Duration(milliseconds: 130));
    expect(shotOpacity(), inExclusiveRange(0.0, 1.0));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('lang-shot')), findsNothing);

    state.settings
      ..reduceMotion = true
      ..language = 'ru';
    state.openPage(state.pageIndex);
    await tester.pump();
    expect(find.byKey(const ValueKey('lang-shot')), findsNothing);
    expect(find.text('Настройки'), findsWidgets);
    expect(tester.takeException(), isNull);
    timeDilation = 1;
  });
}