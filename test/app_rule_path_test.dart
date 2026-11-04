import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/app_rule_path.dart';
import 'package:skipit/models/app_rules.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/apps_page.dart';
import 'package:skipit/ui/theme.dart';
import 'package:skipit/ui/widgets.dart';

void main() {
  setUpAll(() async {
    final loader = FontLoader('Segoe UI');
    for (final name in ['segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf']) {
      final f = File('${Platform.environment['WINDIR']}\\Fonts\\$name');
      if (f.existsSync()) loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
    await loader.load();
  });
  test('checks files and folders but ignores process names', () async {
    final temp = await Directory.systemTemp.createTemp('skipit_rule_test_');
    try {
      final file = File('${temp.path}/example.exe');
      final dir = Directory('${temp.path}/folder');
      final fileRule = AppEntry(match: file.path.replaceAll('\\', '/'), label: 'File');
      final dirRule = AppEntry(match: '${dir.path.replaceAll('\\', '/')}/', label: 'Folder');
      expect(await appRulePathExists(AppEntry(match: 'example', label: 'Name')), isNull);
      expect(await appRulePathExists(fileRule), false);
      expect(await appRulePathExists(dirRule), false);
      await file.writeAsString('test');
      await dir.create();
      expect(await appRulePathExists(fileRule), true);
      expect(await appRulePathExists(dirRule), true);
      await file.delete();
      expect(await appRulePathExists(fileRule), false);
    } finally { await temp.delete(recursive: true); }
  });
  testWidgets('missing path warning can be checked again', (tester) async {
    tester.view.physicalSize = const Size(944, 561);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    C.use(Palette.dark);
    final temp = await tester.runAsync(() => Directory.systemTemp.createTemp('skipit_rule_ui_'));
    final folder = Directory('${temp!.path}/folder');
    final state = AppState();
    state.appRules.entries.add(AppEntry(match: '${folder.path.replaceAll('\\', '/')}/', label: 'Example'));
    await tester.pumpWidget(AppScope(state: state, child: RepaintBoundary(child:
      MaterialApp(theme: buildTheme(), home: const Scaffold(body: AppsPage())))));
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 200)); });
    await tester.pump();
    final warning = find.byTooltip('Папка не найдена или недоступна. Нажмите, чтобы проверить снова.');
    expect(warning, findsOneWidget);
    await tester.tap(find.text('Проверить пути'));
    await tester.pump();
    expect(find.byType(Spinner), findsOneWidget);
    const shots = String.fromEnvironment('SKIPIT_SHOTS');
    if (shots.isNotEmpty) await expectLater(find.byType(RepaintBoundary).first,
        matchesGoldenFile(Uri.file('$shots/app-rule-checking.png')));
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 100)); });
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.byType(Spinner), findsNothing);
    if (shots.isNotEmpty) await expectLater(find.byType(RepaintBoundary).first,
        matchesGoldenFile(Uri.file('$shots/app-rule-missing.png')));
    await tester.runAsync(() => folder.create());
    await tester.tap(warning);
    await tester.pump();
    await tester.runAsync(() async { await Future<void>.delayed(const Duration(milliseconds: 100)); });
    await tester.pump();
    expect(warning, findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => temp.delete(recursive: true));
  });
}
