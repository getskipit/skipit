import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/shell.dart';
import 'package:skipit/ui/theme.dart';

/// Поиск по настройкам: по названию строки, по подписи и по ключевым словам.
void main() {
  testWidgets('поиск оставляет подходящие строки и сам раскрывает свёрнутые разделы', (tester) async {
    await tester.runAsync(AppPaths.init);
    C.use(Palette.dark);
    tester.view.physicalSize = const Size(1100, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState()..routingProfiles.add(RoutingProfile.global());
    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(theme: buildTheme(), home: const Shell()),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byIcon(Icons.tune_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));

    Future<void> search(String text) async {
      await tester.enterText(find.widgetWithText(TextField, 'Поиск по настройкам'), text);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // Частые разделы раскрыты, редкие свёрнуты: видны заголовок и что в нём лежит.
    expect(find.text('Тема').hitTestable(), findsOneWidget);
    expect(find.textContaining('SOCKS и HTTP'), findsOneWidget);
    expect(find.text('SOCKS-порт').hitTestable(), findsNothing);

    // По ключевому слову: в названии и подписи строки слова «бэкап» нет.
    await search('бэкап');
    expect(find.text('Перенос настроек').hitTestable(), findsOneWidget);
    expect(find.text('Тема'), findsNothing);
    expect(find.text('ПРОГРАММА'), findsNothing);

    // По названию; строки свёрнутого раздела находятся тоже.
    await search('порт');
    expect(find.text('SOCKS-порт'), findsOneWidget);
    expect(find.text('HTTP-порт'), findsOneWidget);
    expect(find.text('Тема'), findsNothing);

    // Несколько слов — должны найтись все.
    await search('пароль порт');
    expect(find.text('Пароль на локальные порты'), findsOneWidget);
    expect(find.text('Порт API статистики'), findsNothing);

    // По названию раздела — весь раздел.
    await search('программа');
    expect(find.text('Тема'), findsOneWidget);
    expect(find.text('Меньше анимаций'), findsOneWidget);

    await search('ъъъ');
    expect(find.textContaining('Ничего не найдено'), findsOneWidget);

    // Ушли в другой раздел и вернулись — поиск сброшен.
    await search('порт');
    await tester.tap(find.byIcon(Icons.bolt_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byIcon(Icons.tune_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Тема'), findsOneWidget);
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Поиск по настройкам')).controller!.text, isEmpty);

    await search('ъъъ');
    await tester.tap(find.byTooltip('Очистить'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('ПРОГРАММА'), findsOneWidget);
    expect(find.text('ЖУРНАЛ И ДАННЫЕ'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });
}
