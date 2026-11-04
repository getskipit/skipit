import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/ui/check_page.dart';
import 'package:skipit/ui/theme.dart';
import 'package:skipit/ui/widgets.dart';

void main() {
  setUpAll(() async {
    final loader = FontLoader('Segoe UI');
    for (final name in ['segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf']) {
      final file = File('${Platform.environment['WINDIR']}\\Fonts\\$name');
      if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
    final mono = FontLoader('Consolas');
    final consoleFont = File('${Platform.environment['WINDIR']}\\Fonts\\consola.ttf');
    if (consoleFont.existsSync()) mono.addFont(Future.value(ByteData.sublistView(consoleFont.readAsBytesSync())));
    await mono.load();
  });
  testWidgets('preview returns exactly the displayed report', (tester) async {
    tester.view.physicalSize = const Size(944, 561);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    C.use(Palette.dark);
    final pending = Completer<String>();
    String? result;
    await tester.pumpWidget(RepaintBoundary(child: MaterialApp(theme: buildTheme(), home: Scaffold(
      body: Builder(builder: (context) => TextButton(onPressed: () async {
        result = await showDialog<String>(context: context, builder: (_) => ReportPreviewDialog(report: pending.future));
      }, child: const Text('Open'))),
    ))));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.widget<GradientButton>(find.byType(GradientButton)).onPressed, isNull);
    const report = 'Пример отчёта\nsite.example\nПоследняя строка';
    pending.complete(report);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Пример отчёта'), findsOneWidget);
    expect(find.text('Последняя строка'), findsOneWidget);
    const shots = String.fromEnvironment('SKIPIT_SHOTS');
    if (shots.isNotEmpty) await expectLater(find.byType(RepaintBoundary).first,
        matchesGoldenFile(Uri.file('$shots/report-preview.png')));
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(result, report);
    expect(tester.takeException(), isNull);
  });
}
