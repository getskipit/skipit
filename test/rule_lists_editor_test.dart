import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:skipit/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/routing_page.dart';
import 'package:skipit/ui/theme.dart';

/// Секция «Списки по ссылке» в редакторе профиля маршрутизации: добавление списка по адресу
/// с выбором действия, отказ от некорректного адреса, статус загрузки у строки.
void main() {
  late AppState state;
  late Directory tmp;

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
    tmp = await Directory.systemTemp.createTemp('skipit-rleditor');
    AppPaths.dataDir = tmp;
    state = AppState();
    state.routingProfiles.addAll([RoutingProfile.global(), ...RoutingProfile.templates()]);
    state.routingProfiles.add(RoutingProfile(name: 'Мой профиль'));
  });

  tearDown(() async => _cleanUp(state, tmp));

  Future<void> openEditor(WidgetTester tester) async {
    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(theme: buildTheme(), home: const Scaffold(body: RoutingPage())),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byIcon(Icons.edit_rounded).last);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Профиль маршрутизации'), findsOneWidget);
  }

  for (final language in [Lang.ru, Lang.en]) {
    testWidgets('редактор списков в минимальном окне: ' + language.name, (tester) async {
      lang = language;
      addTearDown(() => lang = Lang.ru);
      tester.view.physicalSize = const Size(1180, 701.25);
      tester.view.devicePixelRatio = 1.25;
      addTearDown(tester.view.reset);
      final profile = state.routingProfiles.last;
      profile.ruleLists.addAll([
        RuleListSource(url: 'https://rules.example/lists/domains.txt', count: 1250,
            updatedAt: DateTime(2026, 11, 1)),
        RuleListSource(url: 'https://rules.example/lists/addresses.txt', action: 'direct'),
      ]);
      await tester.pumpWidget(AppScope(state: state,
          child: RepaintBoundary(key: const ValueKey('editor-shot'),
              child: MaterialApp(theme: buildTheme(), home: const Scaffold(body: RoutingPage())))));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.ensureVisible(find.byIcon(Icons.edit_rounded).last);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byIcon(Icons.edit_rounded).last);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.ensureVisible(find.text(profile.ruleLists.last.url));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      const shots = String.fromEnvironment('SKIPIT_SHOTS');
      if (shots.isNotEmpty) {
        await expectLater(find.byKey(const ValueKey('editor-shot')),
            matchesGoldenFile(Uri.file('$shots/editor_' + language.name + '.png')));
      }
      await tester.tap(find.text(language == Lang.ru ? 'Отмена' : 'Cancel'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(profile.ruleLists.length, 2);
    });
  }

  testWidgets('список по ссылке добавляется с действием; некорректный адрес не принимается', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await openEditor(tester);

    // Некорректный адрес — предупреждение, строка не добавилась.
    await tester.ensureVisible(find.text('Добавить список'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Добавить список'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).last, 'not-a-url');
    await tester.tap(find.text('Добавить').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Некорректный адрес'), findsOneWidget);

    // Корректный адрес — строка появилась в секции с действием «напрямую».
    await tester.enterText(find.byType(TextField).last, 'https://rules.example/list.txt');
    await tester.tap(find.text('напрямую').last);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Добавить').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('https://rules.example/list.txt'), findsOneWidget);
    expect(find.text('ещё не загружен'), findsOneWidget);

    // Сохраняем профиль — список попал в модель.
    await tester.tap(find.text('Сохранить'));
    await tester.pump(const Duration(milliseconds: 500));
    final profile = state.routingProfiles.firstWhere((r) => r.name == 'Мой профиль');
    expect(profile.ruleLists.single.url, 'https://rules.example/list.txt');
    expect(profile.ruleLists.single.action, 'direct');
  });

  testWidgets('сохранение при подключении: списки докачиваются до переподключения', (tester) async {
    final rec = _RecordingState()
      ..routingProfiles.addAll([RoutingProfile.global(), ...RoutingProfile.templates()])
      ..routingProfiles.add(RoutingProfile(name: 'Мой профиль'));
    state = rec;
    final profile = rec.routingProfiles.firstWhere((r) => r.name == 'Мой профиль');
    rec.settings.selectedRoutingId = profile.id;

    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await openEditor(tester);

    await tester.tap(find.text('Сохранить'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    // Переподключение с новым списком — только после того, как он докачался.
    expect(rec.events, ['обновление:начало', 'обновление:конец', 'переподключение']);
  });
}

/// Подключённое состояние, записывающее порядок вызовов: медленное обновление списков
/// и переподключение. С ``unawaited`` вместо ``await`` переподключение обгоняло бы докачку.
class _RecordingState extends AppState {
  final events = <String>[];

  @override
  bool get isConnected => true;

  @override
  Future<void> updateRuleLists(RoutingProfile p, {bool force = false}) async {
    events.add('обновление:начало');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    events.add('обновление:конец');
  }

  @override
  Future<void> reconnect() async => events.add('переподключение');
}

/// Уборка после теста (отложенная запись state.json иначе срабатывала уже в следующем тесте).
Future<void> _cleanUp(AppState state, Directory tmp) async {
  await state.saveNow();
  state.dispose();
  for (var attempt = 1; attempt <= 10; attempt++) {
    try {
      await tmp.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }
}
