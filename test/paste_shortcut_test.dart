import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/shell.dart';
import 'package:skipit/ui/theme.dart';

/// Ctrl+V в окне добавляет ссылку из буфера обмена — в любом разделе и после любых кликов.
void main() {
  setUpAll(AppPaths.init);

  Future<AppState> open(WidgetTester tester) async {
    C.use(Palette.dark);
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': 'trojan://pw@t.example:443#Pasted'};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final state = AppState();
    state.routingProfiles.addAll([RoutingProfile.global(), ...RoutingProfile.templates()]);
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const Shell())));
    await tester.pump(const Duration(milliseconds: 400));
    return state;
  }

  Future<void> paste(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('сразу после запуска', (tester) async {
    final state = await open(tester);
    await paste(tester);
    expect(state.servers.map((s) => s.name), ['Pasted']);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('два сообщения подряд не остаются на экране одно поверх другого', (tester) async {
    final state = await open(tester);
    state
      ..toast('Подписка «A» обновлена — серверов: 1')
      ..toast('Добавлено: подписка «A»');
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('обновлена — серверов'), findsNothing);
    expect(find.text('Добавлено: подписка «A»'), findsOneWidget);
    // Третье сообщение после того, как второе уже показано, плавно его сменяет.
    state.toast('Журнал скопирован');
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Добавлено: подписка «A»'), findsNothing);
    expect(find.text('Журнал скопирован'), findsOneWidget);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('после клика по пустому месту окна и по плитке', (tester) async {
    final state = await open(tester);
    await tester.tapAt(const Offset(600, 780));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Отдача'));
    await tester.pump(const Duration(milliseconds: 100));
    await paste(tester);
    expect(state.servers.map((s) => s.name), ['Pasted']);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('после похода в журнал и обратно', (tester) async {
    final state = await open(tester);
    state.log.startSession('Сервер');
    state.log.add('app', 'Подключено');
    await tester.tap(find.byIcon(Icons.receipt_long_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Текущее подключение'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.textContaining('Подключено').last);
    await tester.pump(const Duration(milliseconds: 100));
    // В журнале (и в любом разделе, кроме главной) Ctrl+V ничего не добавляет.
    await paste(tester);
    expect(state.servers, isEmpty);
    await tester.tap(find.byIcon(Icons.tune_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));
    await paste(tester);
    expect(state.servers, isEmpty);
    await tester.tap(find.byIcon(Icons.bolt_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));
    await paste(tester);
    expect(state.servers.map((s) => s.name), ['Pasted']);
    state.log.endSession();
    await tester.pump(const Duration(seconds: 9));
  });
}
