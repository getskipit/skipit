import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/l10n/l10n.dart';
import 'package:skipit/models/subscription.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/servers_panel.dart';
import 'package:skipit/ui/subscription_settings_dialog.dart';
import 'package:skipit/ui/theme.dart';

void main() {
  test('свой интервал сохраняется после метаданных и экспорта; можно вернуть провайдера', () {
    final sub = Subscription(url: 'https://panel.example/sub', updateIntervalHours: 12)
      ..lastUpdated = DateTime.now().subtract(const Duration(hours: 2))
      ..updateIntervalOverrideHours = 1;
    sub.applyMeta({'profile-update-interval': '24'});
    expect(sub.updateIntervalHours, 24);
    expect(sub.effectiveUpdateIntervalHours, 1);
    expect(sub.isDue, isTrue);
    final restored = Subscription.fromJson(sub.toJson());
    expect(restored.effectiveUpdateIntervalHours, 1);
    restored.updateIntervalOverrideHours = null;
    expect(restored.effectiveUpdateIntervalHours, 24);
    expect(restored.isDue, isFalse);
  });

  test('выключенное обновление не включается заголовком провайдера', () {
    final sub = Subscription(url: 'https://panel.example/sub', updateIntervalOverrideHours: 0);
    sub.applyMeta({'profile-update-interval': '1'});
    expect(sub.effectiveUpdateIntervalHours, 0);
    expect(sub.isDue, isFalse);
  });

  test('старые данные без своего интервала продолжают принимать значение провайдера', () {
    final sub = Subscription.fromJson({'url': 'https://panel.example/sub', 'updateIntervalHours': 12});
    sub.applyMeta({'profile-update-interval': '6'});
    expect(sub.effectiveUpdateIntervalHours, 6);
    expect(sub.updateIntervalOverrideHours, isNull);
  });

  group('общее окно', () {
    late Directory dir;
    late AppState state;
    setUpAll(() async {
      await AppPaths.init();
      for (final (name, paths) in [
        ('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']),
        ('MaterialIcons', ['D:/tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']),
      ]) {
        final loader = FontLoader(name);
        for (final path in paths) {
          final file = File(path);
          if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
        }
        await loader.load();
      }
    });
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('skipit-bulk-sub');
      AppPaths.dataDir = dir;
      state = AppState();
      state.subscriptions.addAll([
        Subscription(id: 'a', url: 'https://a.example/sub', name: 'Первая подписка'),
        Subscription(id: 'b', url: 'https://b.example/sub', name: 'Вторая подписка'),
        Subscription(id: 'c', url: 'https://c.example/sub', name: 'Третья подписка', hidden: true),
      ]);
    });
    tearDown(() async {
      lang = Lang.ru;
      await state.saveNow();
      state.dispose();
      if (!dir.absolute.path.startsWith(Directory.systemTemp.absolute.path + Platform.pathSeparator + 'skipit-')) {
      throw StateError('Unexpected temporary directory');
    }
    for (var attempt = 0; ; attempt++) {
      try { await dir.delete(recursive: true); break; }
      on FileSystemException {
        if (attempt >= 9) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    });

    Future<void> open(WidgetTester tester, {bool minimum = false}) async {
      tester.view.physicalSize = minimum ? const Size(1180, 701.25) : const Size(1400, 1000);
      tester.view.devicePixelRatio = minimum ? 1.25 : 1;
      addTearDown(tester.view.reset);
      C.use(Palette.dark);
      await tester.pumpWidget(AppScope(state: state,
        child: RepaintBoundary(key: const ValueKey('bulk-shot'), child: MaterialApp(theme: buildTheme(),
          home: const Scaffold(body: Padding(padding: EdgeInsets.all(24), child: ServersPanel(manage: true))))),
      ));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip(lang == Lang.ru ? 'Ещё' : 'More').first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text(tr('Настройки подписок')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SubscriptionSettingsDialog), findsOneWidget);
    }

    testWidgets('применяется только к выбранным подпискам, включая скрытые', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('subscription-b')));
      await tester.enterText(find.byKey(const ValueKey('subscription-interval')), '3');
      await tester.tap(find.text('Применить'));
      await tester.runAsync(state.saveNow);
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.subscriptions.map((s) => s.updateIntervalOverrideHours), [3, null, 3]);
      expect(state.subscriptions.last.hidden, isTrue);
      expect(find.text('Автообновление — 3 ч.'), findsNWidgets(2));
    });

    testWidgets('отмена ничего не меняет', (tester) async {
      await open(tester);
      await tester.enterText(find.byKey(const ValueKey('subscription-interval')), '0');
      await tester.tap(find.text('Отмена'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.subscriptions.every((s) => s.updateIntervalOverrideHours == null), isTrue);
    });

    testWidgets('пустое значение не сохраняется; без выбранных подписок применение выключено', (tester) async {
      await open(tester);
      await tester.enterText(find.byKey(const ValueKey('subscription-interval')), '');
      await tester.tap(find.text('Применить'));
      await tester.runAsync(state.saveNow);
      await tester.pump();
      expect(find.text('Укажите целое число часов: 0 — выключить'), findsOneWidget);
      await tester.tap(find.text('Снять выбор'));
      await tester.pump();
      await tester.tap(find.text('Применить'));
      await tester.runAsync(state.saveNow);
      await tester.pump();
      expect(find.byType(SubscriptionSettingsDialog), findsOneWidget);
      expect(state.subscriptions.every((s) => s.updateIntervalOverrideHours == null), isTrue);
      await tester.tap(find.text('Отмена'));
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('можно вернуть интервалы провайдеров', (tester) async {
      for (final sub in state.subscriptions) { sub.updateIntervalOverrideHours = 0; }
      await open(tester);
      await tester.tap(find.text('Провайдера'));
      await tester.pump();
      await tester.tap(find.text('Применить'));
      await tester.runAsync(state.saveNow);
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.subscriptions.every((s) => s.effectiveUpdateIntervalHours == 12), isTrue);
    });

    testWidgets('содержимое и высота интервала меняются плавно, введённое число сохраняется', (tester) async {
      await open(tester);
      final panel = find.byKey(const ValueKey('subscription-interval-panel'));
      final field = find.byKey(const ValueKey('subscription-interval'));
      await tester.enterText(field, '7');
      final before = tester.getSize(panel).height;
      await tester.tap(find.text('Провайдера'));
      await tester.pump();
      expect(tester.getSize(panel).height, closeTo(before, 0.1));
      final heights = [before];
      for (var i = 0; i < 7; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        heights.add(tester.getSize(panel).height);
      }
      final after = heights.last;
      expect(after, lessThan(before));
      expect(heights.any((h) => h > after + 1 && h < before - 1), isTrue);
      for (var i = 1; i < heights.length; i++) {
        expect(heights[i], lessThanOrEqualTo(heights[i - 1] + 0.1));
        expect((heights[i] - heights[i - 1]).abs(), lessThan((before - after) * 0.6));
      }
      await tester.tap(find.text('Свой'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 280));
      expect(tester.getSize(panel).height, closeTo(before, 0.1));
      expect(tester.widget<TextField>(field).controller!.text, '7');
      await tester.tap(find.text('Отмена'));
      await tester.pump(const Duration(milliseconds: 400));
    });

    for (final language in [Lang.ru, Lang.en]) {
      testWidgets('минимальное окно: ${language.name}', (tester) async {
        lang = language;
        await open(tester, minimum: true);
        expect(tester.takeException(), isNull);
        final hint = find.text(tr('0 — отключить автообновление'));
        final card = find.ancestor(of: hint, matching: find.byType(Container)).first;
        final scroll = find.ancestor(of: card, matching: find.byType(Scrollable)).first;
        expect(tester.getRect(card).bottom, lessThanOrEqualTo(tester.getRect(scroll).bottom + 1));
        const shots = String.fromEnvironment('SKIPIT_SHOTS');
        if (shots.isNotEmpty) {
          await expectLater(find.byKey(const ValueKey('bulk-shot')),
              matchesGoldenFile(Uri.file('$shots/subscriptions-${language.name}.png')));
        }
        await tester.tap(find.text(tr('Отмена')));
        await tester.pump(const Duration(milliseconds: 400));
      });
    }
  });
}
