import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/kill_switch.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/app_icon.dart';
import 'package:skipit/ui/settings_page.dart';
import 'package:skipit/ui/shell.dart';
import 'package:skipit/ui/theme.dart';
import 'package:skipit/ui/widgets.dart';

/// Настройки, до которых общий тест окна не доходит: свёрнутый раздел «Сеть» с выпадающим
/// списком и выключатель Kill Switch. Проверяется, что они переключаются без ошибок отрисовки.
void main() {
  setUpAll(() async {
    await AppPaths.init();
    final loader = FontLoader('Segoe UI');
    for (final file in ['segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf', 'seguibl.ttf']) {
      final f = File('${Platform.environment['WINDIR']}\\Fonts\\$file');
      if (f.existsSync()) loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
    await loader.load();
  });

  testWidgets('выпадающий список и Kill Switch в настройках', (tester) async {
    C.use(Palette.dark);
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState();
    state.routingProfiles.add(RoutingProfile.global());
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const Shell())));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byIcon(Icons.tune_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Подключение'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    final scroll = find.descendant(of: find.byType(SettingsPage), matching: find.byType(Scrollable)).first;


    // Kill Switch: выключен, включается и выключается кликом; VPN не подключён, фильтры не ставятся.
    await tester.scrollUntilVisible(find.text('Kill Switch'), 200, scrollable: scroll);
    expect(state.settings.killSwitch, isFalse);
    await Scrollable.ensureVisible(tester.element(find.text('Kill Switch')), alignment: 0.4);
    await tester.pump(const Duration(milliseconds: 300));
    // Выключатель этой строки — ближайший к её названию по вертикали.
    Offset toggle() {
      final y = tester.getCenter(find.text('Kill Switch')).dy;
      final all = [for (final e in find.byType(AppSwitch).evaluate()) tester.getCenter(find.byWidget(e.widget))];
      all.sort((a, b) => (a.dy - y).abs().compareTo((b.dy - y).abs()));
      return all.first;
    }

    await tester.tapAt(toggle());
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(state.settings.killSwitch, isTrue);
    expect(KillSwitch.active, isFalse);
    await tester.tapAt(toggle());
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.settings.killSwitch, isFalse);

    // Блокировка рекламы: выключатель той же строкой; VPN не подключён — переподключения нет.
    await tester.scrollUntilVisible(find.text('Блокировать рекламу и трекеры'), 200, scrollable: scroll);
    await Scrollable.ensureVisible(tester.element(find.text('Блокировать рекламу и трекеры')), alignment: 0.4);
    await tester.pump(const Duration(milliseconds: 300));
    final adY = tester.getCenter(find.text('Блокировать рекламу и трекеры')).dy;
    final switches = [for (final e in find.byType(AppSwitch).evaluate()) tester.getCenter(find.byWidget(e.widget))]
      ..sort((a, b) => (a.dy - adY).abs().compareTo((b.dy - adY).abs()));
    await tester.tapAt(switches.first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.settings.adBlock, isTrue);
    expect(state.isConnected, isFalse);

    // «Для опытных» открывается без ошибок; уровень логов меняется через выпадающий список.
    Future<void> show(Finder f) async {
      await tester.scrollUntilVisible(f, 200, scrollable: scroll);
      await Scrollable.ensureVisible(tester.element(f), alignment: 0.4);
      await tester.pump(const Duration(milliseconds: 300));
    }

    await tester.tap(find.byTooltip('Все настройки'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Для опытных'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.takeException(), isNull);
    }
    expect(find.text('СЕТЬ'), findsOneWidget);
    // При первом заходе — предупреждение; «Понятно» его убирает навсегда.
    expect(find.text('Понятно'), findsOneWidget);
    await tester.tap(find.text('Понятно'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.takeException(), isNull);
    }
    expect(state.settings.advancedHintSeen, isTrue);
    expect(AppSettings.fromJson(state.settings.toJson()).advancedHintSeen, isTrue);
    expect(find.text('Понятно').hitTestable(), findsNothing);
    await show(find.text('Уровень логов'));
    await tester.tap(find.byType(AppDropdown<String>).first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('debug').last);
    // Смена значения — анимация: старое гаснет, новое проявляется, ширина кнопки меняется.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
    }
    expect(state.settings.logLevel, 'debug');
    expect(
        find.descendant(of: find.byType(AppDropdown<String>).first, matching: find.text('debug')), findsOneWidget);

    // Адрес проверки: готовый из списка, затем «Свой адрес» — появляется поле, неверный адрес не сохраняется.
    await tester.tap(find.byTooltip('Все настройки'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Подписки и серверы'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    final urlBox = find.ancestor(of: find.text('Google'), matching: find.byType(AppDropdown<String>));
    await show(urlBox);
    await tester.tap(urlBox);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Cloudflare').last);
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.settings.testUrl, 'https://cp.cloudflare.com/generate_204');
    expect(state.settings.testUrlOwn, isFalse);

    final ownBox = find.ancestor(of: find.text('Cloudflare'), matching: find.byType(AppDropdown<String>));
    await tester.tap(ownBox);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Свой адрес').last);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.takeException(), isNull);
    }
    expect(state.settings.testUrlOwn, isTrue);
    final field = find.descendant(
        of: find.ancestor(of: find.text('Свой адрес проверки'), matching: find.byType(Row)).first,
        matching: find.byType(TextFormField));
    await show(field);
    expect(find.descendant(of: field, matching: find.text('https://cp.cloudflare.com/generate_204')), findsOneWidget);
    await tester.enterText(field, 'not a url');
    await tester.pump();
    expect(state.settings.testUrl, 'https://cp.cloudflare.com/generate_204');
    await tester.enterText(field, 'https://check.example/ok');
    await tester.pump();
    expect(state.settings.testUrl, 'https://check.example/ok');
    await tester.pump(const Duration(milliseconds: 500));
  });

  test('внешний вид: тема, акцент, скругление, значок, карточка и пункты меню сохраняются', () {
    final s = AppSettings()
      ..theme = AppTheme.black
      ..accent = 'blue'
      ..corners = 1.6
      ..iconStyle = 'bright'
      ..subDetailed = true
      ..menuHidden = {'2', '4'};
    final back = AppSettings.fromJson(s.toJson());
    expect((back.theme, back.accent, back.corners, back.iconStyle, back.subDetailed),
        (AppTheme.black, 'blue', 1.6, 'bright', true));
    expect(back.menuHidden, {'2', '4'});
    // Главную и Настройки спрятать нельзя; странное скругление не принимается.
    final odd = AppSettings.fromJson({'menuHidden': ['0', '5', '3'], 'corners': 7});
    expect(odd.menuHidden, {'3'});
    expect(odd.corners, 1.0);

    // Палитра с акцентом и скруглением — один объект на сочетание; оранжевый и 1 — сама тема.
    expect(identical(Palette.dark.styled(Accent.orange, 1), Palette.dark), isTrue);
    final blue = Palette.black.styled(Accent.blue, 1.6);
    expect(identical(blue, Palette.black.styled(Accent.blue, 1.6)), isTrue);
    C.use(blue);
    expect((C.orange, C.r(10), C.warn), (Accent.blue.main, 16.0, const Color(0xFFFF5F1A)));
    C.use(Palette.dark);
  });

  testWidgets('значок рисуется всех размеров и в меню прячутся выбранные разделы', (tester) async {
    final images = await tester.runAsync(() => renderIcon(IconStyle.bright, Accent.green));
    expect(images!.map((i) => i.size), iconSizes);
    for (final i in images) {
      expect(i.rgba.length, i.size * i.size * 4);
    }
    // Угол прозрачный, середина — непрозрачная.
    final big = images.last;
    expect(big.rgba[3], 0);
    expect(big.rgba[(big.size * big.size ~/ 2 + big.size ~/ 2) * 4 + 3], 255);

    C.use(Palette.dark);
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState()..settings.menuHidden = {'2', '3'};
    state.routingProfiles.add(RoutingProfile.global());
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const Shell())));
    await tester.pump(const Duration(milliseconds: 400));
    // «Маршрутизация» на главной есть и плиткой — в меню её нет, поэтому одна.
    expect(find.text('Маршрутизация'), findsOneWidget);
    expect(find.text('Проверка'), findsNothing);
    await tester.tap(find.text('Логи'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.pageIndex, 4);
    state.settings.menuHidden = {};
    state.changed();
    // Пункт выезжает плавно.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(find.text('Проверка'), findsOneWidget);
  });

  testWidgets('смена вида настроек оставляет открытой ту же группу', (tester) async {
    C.use(Palette.dark);
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    state.routingProfiles.add(RoutingProfile.global());
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const Shell())));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byIcon(Icons.tune_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Внешний вид'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Цвет акцента'), findsOneWidget);
    // Выбор вида — внизу страницы: сначала прокручиваем к нему.
    await tester.ensureVisible(find.text('Списком').first);
    await tester.pump();
    await tester.tap(find.text('Списком').first);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(state.settings.settingsList, isTrue);
    expect(find.text('Цвет акцента').hitTestable(), findsOneWidget);
    await tester.ensureVisible(find.text('Плитки').first);
    await tester.pump();
    await tester.tap(find.text('Плитки').first);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(state.settings.settingsList, isFalse);
    expect(find.text('Цвет акцента').hitTestable(), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
  });

  test('адрес проверки, вписанный раньше вручную, открывается как «Свой адрес»', () {
    expect(AppSettings.fromJson({'testUrl': 'https://check.example/ok'}).testUrlOwn, isTrue);
    expect(AppSettings.fromJson({'testUrl': 'https://cp.cloudflare.com/generate_204'}).testUrlOwn, isFalse);
    expect(AppSettings.fromJson({}).testUrlOwn, isFalse);
  });
}
