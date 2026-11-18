import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
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
  const shots = String.fromEnvironment('SKIPIT_SHOTS');

  setUpAll(() async {
    await AppPaths.init();
    if (shots.isEmpty) return;
    final fonts = Directory('${Platform.environment['WINDIR']}\\Fonts');
    final segoe = FontLoader('Segoe UI');
    for (final name in ['segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf']) {
      final file = File('${fonts.path}\\$name');
      if (file.existsSync()) segoe.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await segoe.load();
  });

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

  test('в цветных темах второстепенный текст контрастен на фоне и карточках', () {
    for (final theme in [AppTheme.midnight, AppTheme.forest, AppTheme.plum, AppTheme.cocoa, AppTheme.mint, AppTheme.lavender]) {
      final palette = Palette.presets[theme]!;
      final text = palette.muted.computeLuminance() + 0.05;
      for (final color in [palette.bg, palette.surface, palette.surface2]) {
        final background = color.computeLuminance() + 0.05;
        expect(text > background ? text / background : background / text, greaterThanOrEqualTo(4.5), reason: theme.name);
      }
    }
  });

  test('удалённая тема SkipIt загружается как тёмная с сохранённым акцентом', () {
    final settings = AppSettings.fromJson({'theme': 'skipit', 'accent': 'blue'});
    expect(settings.theme, AppTheme.dark);
    expect(settings.accent, 'blue');
  });

  testWidgets('цветная тема выбирается в настройках и сохраняется', (tester) async {
    tester.view.physicalSize = const Size(944, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => C.use(Palette.dark));
    addTearDown(() => lang = Lang.ru);

    final state = AppState()
      ..settings.language = 'ru'
      ..settings.accent = 'blue';
    state.routingProfiles.add(RoutingProfile.global());
    await tester.pumpWidget(RepaintBoundary(child: SkipItApp(state: state)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.tune_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Внешний вид'));
    await tester.pumpAndSettle();

    final mint = find.byKey(const ValueKey(AppTheme.mint)).hitTestable();
    expect(mint, findsOneWidget);
    await tester.tap(mint);
    await tester.pumpAndSettle();

    expect(state.settings.theme, AppTheme.mint);
    expect(AppSettings.fromJson(state.settings.toJson()).theme, AppTheme.mint);
    expect(C.palette.bg, Palette.presets[AppTheme.mint]!.bg);
    expect(C.palette.brightness, Brightness.light);
    expect(C.palette.accent, Accent.blue);
    expect(tester.takeException(), isNull);

    if (shots.isNotEmpty) {
      await expectLater(find.byType(RepaintBoundary).first,
          matchesGoldenFile(Uri.file('$shots\\appearance-themes.png')));
    }
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