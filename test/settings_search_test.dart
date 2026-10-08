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
  testWidgets('поиск оставляет подходящие строки и сам раскрывает «Дополнительно»', (tester) async {
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
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
    }

    expect(find.text('Тема'), findsOneWidget);
    expect(find.text('Перенос настроек'), findsOneWidget);

    // По ключевому слову: в названии и подписи строки слова «бэкап» нет.
    await search('бэкап');
    expect(find.text('Перенос настроек'), findsOneWidget);
    expect(find.text('Тема'), findsNothing);
    expect(find.text('ОФОРМЛЕНИЕ'), findsNothing);

    // По названию; строки свёрнутого раздела «Дополнительно» находятся тоже.
    await search('порт');
    expect(find.text('SOCKS-порт'), findsOneWidget);
    expect(find.text('HTTP-порт'), findsOneWidget);
    expect(find.text('Тема'), findsNothing);

    // Несколько слов — должны найтись все.
    await search('пароль порт');
    expect(find.text('Пароль на локальные порты'), findsOneWidget);
    expect(find.text('Порт API статистики'), findsNothing);

    // По названию раздела — весь раздел.
    await search('оформление');
    expect(find.text('Тема'), findsOneWidget);
    expect(find.text('Меньше анимаций'), findsOneWidget);

    await search('ъъъ');
    expect(find.textContaining('Ничего не найдено'), findsOneWidget);

    await tester.tap(find.byTooltip('Очистить'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Тема'), findsOneWidget);
    expect(find.text('Перенос настроек'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });
}
