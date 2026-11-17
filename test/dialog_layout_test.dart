import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/check_page.dart';
import 'package:skipit/ui/qr_ui.dart';
import 'package:skipit/ui/theme.dart';
import 'package:skipit/ui/widgets.dart';

void main() {
  setUpAll(() async {
    await AppPaths.init();
    final font = FontLoader('Segoe UI');
    font.addFont(Future.value(ByteData.sublistView(await File('C:/Windows/Fonts/segoeui.ttf').readAsBytes())));
    await font.load();
  });
  Finder surface() => find.descendant(of: find.byType(Dialog), matching: find.byType(Material)).first;
  for (final palette in [Palette.dark, Palette.light]) {
    testWidgets('QR fits minimum window in ' + palette.brightness.name, (tester) async {
      tester.view.physicalSize = const Size(944, 561);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      C.use(palette);
      final state = AppState();
      await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(),
        home: Scaffold(body: Builder(builder: (context) => TextButton(
          onPressed: () => showQrDialog(context, title: 'Пример VPN', text: 'https://panel.example/sub/demo', subscription: true),
          child: const Text('Open'),
        ))))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final bounds = tester.getRect(surface());
      expect(bounds.top, greaterThanOrEqualTo(0));
      expect(bounds.bottom, lessThanOrEqualTo(561));
      final notice = find.textContaining('В коде — ссылка подписки');
      expect(notice.hitTestable(), findsOneWidget);
      expect(tester.getRect(notice).bottom, lessThan(tester.getRect(find.text('Закрыть')).top));
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
    });
  }
  testWidgets('long destructive confirmation has bounded width and a distinct action', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    C.use(Palette.dark);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(
      body: Builder(builder: (context) => TextButton(onPressed: () => confirm(context, 'Удалить все данные?',
        'Подписки, серверы, профили, правила программ и настройки будут удалены без возможности вернуть. '
        'Чтобы сохранить их, сначала нажмите «Экспорт» выше, в разделе «Данные».', danger: true),
        child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(tester.getSize(surface()).width, lessThanOrEqualTo(608));
    final button = find.byType(GradientButton);
    final decoration = tester.widget<AnimatedContainer>(
      find.descendant(of: button, matching: find.byType(AnimatedContainer)).first).decoration! as BoxDecoration;
    expect(decoration.color, C.red);
    expect(tester.widget<Text>(find.text('Удалить')).style!.color, Colors.white);
    expect(tester.takeException(), isNull);
  });
  testWidgets('report error stays compact and can be dismissed', (tester) async {
    tester.view.physicalSize = const Size(944, 561);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    C.use(Palette.dark);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: Builder(
      builder: (context) => TextButton(onPressed: () => showDialog<void>(context: context,
        builder: (_) => ReportPreviewDialog(report: Future.error('Ошибка чтения журнала'))),
        child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(tester.getSize(surface()).height, lessThan(300));
    expect(find.text('Сохранить'), findsNothing);
    await tester.tap(find.text('Закрыть'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}