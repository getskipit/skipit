import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/l10n/l10n.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/state/settings_import.dart';
import 'package:skipit/ui/settings_import_dialog.dart';
import 'package:skipit/ui/theme.dart';
import 'package:skipit/ui/widgets.dart';

void main() {
  late SettingsImport preview;
  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('skipit-import-preview');
    try {
      final file = File('${dir.path}\\settings.json');
      await file.writeAsString(jsonEncode({
        'settings': {'mode': 'mixed'},
        'subscriptions': [
          {'name': 'Example VPN', 'url': 'https://panel.example/sub/PRIVATE-TOKEN'},
        ],
        'servers': [],
        'routing': [RoutingProfile(name: 'Рабочий профиль').toJson()],
        'apps': {'entries': []},
      }));
      preview = (await SettingsImport.read(file.path)).data!;
    } finally {
      await dir.delete(recursive: true);
    }
  });

  for (final language in Lang.values) {
    testWidgets('предпросмотр импорта и выбор разделов: ${language.name}', (tester) async {
      C.use(Palette.dark);
      lang = language;
      addTearDown(() => lang = Lang.ru);
      tester.view.physicalSize = const Size(1200, 750);
      tester.view.devicePixelRatio = 1.25;
      addTearDown(tester.view.reset);

      const shots = String.fromEnvironment('SKIPIT_SHOTS');
      if (shots.isNotEmpty) {
        final fonts = FontLoader('Segoe UI');
        for (final name in ['segoeui.ttf', 'segoeuib.ttf']) {
          final file = File('C:\\Windows\\Fonts\\$name');
          if (file.existsSync()) fonts.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
        }
        await fonts.load();
      }

      Set<SettingsImportSection>? selected;
      const frame = ValueKey('import-preview');
      await tester.pumpWidget(RepaintBoundary(
        key: frame,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          home: Builder(builder: (context) => Scaffold(body: Center(child: TextButton(
            onPressed: () async => selected = await showSettingsImportDialog(context, preview),
            child: const Text('Open'),
          )))),
        ),
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text(tr('Предпросмотр импорта')), findsOneWidget);
      expect(find.textContaining('Example VPN'), findsOneWidget);
      expect(find.textContaining('Рабочий профиль'), findsOneWidget);
      expect(find.textContaining('PRIVATE-TOKEN'), findsNothing);
      expect(tester.takeException(), isNull);
      if (shots.isNotEmpty) {
        await expectLater(find.byKey(frame), matchesGoldenFile(Uri.file('$shots\\import-${language.name}.png')));
      }

      for (final label in ['Подписки и серверы', 'Профили маршрутизации', 'Настройки программы']) {
        await tester.tap(find.text(tr(label)));
        await tester.pumpAndSettle();
      }
      final applyButton = find.widgetWithText(GradientButton, tr('Импортировать'));
      expect(tester.widget<GradientButton>(applyButton).onPressed, isNull);
      await tester.tap(find.text(tr('Профили маршрутизации')));
      await tester.pumpAndSettle();
      await tester.tap(applyButton);
      await tester.pumpAndSettle();
      expect(selected, {SettingsImportSection.routing});
    });
  }
}
