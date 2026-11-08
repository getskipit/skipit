import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/core/service_client.dart';
import 'package:skipit/core/updates.dart';
import 'package:skipit/models/subscription.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/settings_page.dart';
import 'package:skipit/ui/theme.dart';

void main() {
  late Directory folder;
  late AppLayout original;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('skipit-portable-');
    original = AppPaths.layout;
  });
  tearDown(() async {
    AppPaths.layout = original;
    await folder.delete(recursive: true);
  });
  AppLayout layout() => AppLayout('${folder.path}\\SkipIt.exe');
  void portable() {
    File('${folder.path}\\portable').writeAsStringSync('');
    AppPaths.layout = layout();
  }

  test('переносная копия сохраняет свои данные, не читая AppData', () async {
    portable();
    await AppPaths.init();
    expect(AppPaths.dataDir.path, '${folder.path}\\userdata');
    expect(AppPaths.geoDir.path, '${folder.path}\\userdata\\geo');
    final state = AppState();
    final sub = Subscription(url: 'https://panel.example/sub/SECRET', name: 'Example');
    state.subscriptions.add(sub);
    state.servers.add(LinkParser.parseText('trojan://PASSWORD@server.example:443#Example').servers.single);
    await state.saveNow();
    final saved = await File(AppPaths.stateFile).readAsString();
    expect(saved, isNot(contains('SECRET')));
    expect(saved, isNot(contains('PASSWORD')));
    final again = AppState();
    await again.loadForTest();
    expect(again.subscriptions.single.url, sub.url);
    expect(again.servers.single.address, 'server.example');
    expect(folder.listSync().whereType<Directory>().map((d) => d.path), [AppPaths.dataDir.path]);
    state.dispose();
    again.dispose();
  });

  test('имена, порт и служба переносной версии отделены от установленной и тестовой', () async {
    final installed = layout();
    expect(installed.dataDirectory(r'C:\Users\Example\AppData\Roaming').path,
        r'C:\Users\Example\AppData\Roaming\SkipIt');
    expect(installed.appName, 'SkipIt');
    portable();
    expect(AppPaths.appName, 'SkipIt Portable');
    expect(AppPaths.instancePort, isNot(installed.instancePort));
    expect(ServiceClient.name, 'SkipItPortable');
    expect(await ServiceClient.hello(serviceName: 'SkipIt'), isNull);
    File('${folder.path}\\dev-build').writeAsStringSync('');
    final dev = layout();
    expect(dev.isPortable, isFalse);
    expect(dev.appName, 'SkipIt Dev');
    expect(dev.instancePort, isNot(AppPaths.instancePort));
    expect(dev.dataDirectory(r'C:\Users\Example\AppData\Roaming').path,
        r'C:\Users\Example\AppData\Roaming\SkipIt Dev');
  });

  test('переносная версия не скачивает установщик даже при прямом вызове', () async {
    portable();
    final state = AppState()..appUpdate = Release('v1.1.6', 'getskipit/skipit');
    expect(await state.downloadAppUpdate(), isNull);
    expect(state.downloadingAppUpdate, isFalse);
    expect(state.appUpdate!.portableName, 'SkipIt-Portable-Windows-1.1.6.zip');
    expect(state.appUpdate!.portableUrl,
        'https://github.com/getskipit/skipit/releases/download/v1.1.6/SkipIt-Portable-Windows-1.1.6.zip');
    state.dispose();
  });

  testWidgets('переносное обновление предлагает ZIP и сохранение userdata', (tester) async {
    portable();
    C.use(Palette.dark);
    tester.view.physicalSize = const Size(1200, 750);
    tester.view.devicePixelRatio = 1.25;
    addTearDown(tester.view.reset);
    if (const String.fromEnvironment('SKIPIT_SHOTS').isNotEmpty) {
      for (final (family, file) in [('Segoe UI', 'segoeui.ttf'), ('Segoe UI', 'segoeuib.ttf')]) {
        final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(File('C:\\Windows\\Fonts\\$file').readAsBytesSync())));
        await loader.load();
      }
    }
    final state = AppState()..appUpdate = Release('v1.1.6', 'getskipit/skipit');
    await tester.pumpWidget(RepaintBoundary(key: const ValueKey('portable-shot'),
        child: AppScope(state: state, child: MaterialApp(theme: buildTheme(),
        home: Builder(builder: (context) => Scaffold(body: Center(
            child: TextButton(onPressed: () => installAppUpdate(context), child: const Text('Update')))))))));
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Папку userdata сохраните.'), findsOneWidget);
    expect(find.text('Открыть страницу релиза'), findsOneWidget);
    expect(find.text('Скачать и установить'), findsNothing);
    const shots = String.fromEnvironment('SKIPIT_SHOTS');
    if (shots.isNotEmpty) {
      await expectLater(find.byKey(const ValueKey('portable-shot')), matchesGoldenFile(Uri.file('$shots\\portable-update.png')));
    }
    state.openPage(AppState.settingsPage);
    await tester.pumpWidget(RepaintBoundary(key: const ValueKey('portable-shot'),
        child: AppScope(state: state, child: MaterialApp(key: const ValueKey('settings'),
            theme: buildTheme(), home: const Scaffold(body: SettingsPage())))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('О программе').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    if (shots.isNotEmpty) {
      await expectLater(find.byKey(const ValueKey('portable-shot')), matchesGoldenFile(Uri.file('$shots\\portable-settings.png')));
    }
    expect(find.textContaining('переносная версия, данные в userdata рядом с программой'), findsOneWidget);
    expect(find.text('Скачать ZIP'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
