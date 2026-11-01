import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/shell.dart';
import 'package:skipit/ui/theme.dart';

void main() {
  late Directory dir;
  late AppState state;
  setUpAll(AppPaths.init);
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('skipit-mouse-back');
    AppPaths.dataDir = dir;
    state = AppState()..routingProfiles.add(RoutingProfile.global());
  });
  tearDown(() async {
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

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(state: state,
        child: MaterialApp(theme: buildTheme(), home: const Shell())));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> click(WidgetTester tester, {int buttons = kBackMouseButton}) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: buttons);
    await mouse.down(const Offset(750, 600));
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('боковая кнопка возвращает из настроек к плиткам, передняя не возвращает', (tester) async {
    await open(tester);
    await tester.tap(find.byIcon(Icons.tune_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Внешний вид'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Тема').hitTestable(), findsOneWidget);
    await click(tester, buttons: kForwardMouseButton);
    expect(find.text('Тема').hitTestable(), findsOneWidget);
    await click(tester);
    expect(find.text('Тема'), findsNothing);
    expect(find.text('Для опытных'), findsOneWidget);
    await click(tester);
    expect(state.pageIndex, AppState.settingsPage);
  });

  testWidgets('в истории сначала возвращается к журналам, затем к плиткам', (tester) async {
    state.log.startSession('Исторический сервер');
    state.log.add('app', 'Строка истории');
    state.log.endSession();
    await open(tester);
    await tester.tap(find.byIcon(Icons.receipt_long_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('История'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Исторический сервер').last);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byTooltip('Ко всем журналам'), findsOneWidget);
    await click(tester);
    expect(find.byTooltip('Ко всем журналам'), findsNothing);
    expect(find.text('Очистить историю'), findsOneWidget);
    await click(tester);
    expect(find.text('Очистить историю'), findsNothing);
    expect(find.text('Текущее подключение'), findsOneWidget);
  });

  testWidgets('боковая кнопка у диалога не закрывает группу под ним', (tester) async {
    await open(tester);
    await tester.tap(find.byIcon(Icons.tune_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Внешний вид'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    final context = tester.element(find.byType(Shell));
    showDialog<void>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Диалог'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть'))],
    ));
    await tester.pump(const Duration(milliseconds: 400));
    await click(tester);
    if (find.text('Диалог').evaluate().isNotEmpty) {
      await tester.tap(find.text('Закрыть'));
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(find.text('Тема').hitTestable(), findsOneWidget);
  });
}
