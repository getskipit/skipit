import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/shell.dart';
import 'package:skipit/ui/theme.dart';

/// Пометка уровня строки ядра красится так же, как её считают счётчики «Ошибки» и «Предупреждения».
void main() {
  setUpAll(() async {
    await AppPaths.init();
    final loader = FontLoader('Segoe UI');
    for (final file in ['segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf', 'seguibl.ttf']) {
      final f = File('${Platform.environment['WINDIR']}\\Fonts\\$file');
      if (f.existsSync()) loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
    await loader.load();
  });

  testWidgets('«[Error]» у строки-предупреждения — оранжевый, у настоящей ошибки — красный', (tester) async {
    C.use(Palette.dark);
    tester.view.physicalSize = const Size(1100, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    state.routingProfiles.add(RoutingProfile.global());
    state.log
      ..startSession('Germany', detail: 'Смешанный')
      ..add('xray', '[Error] [555] transport/internet: failed to resolve ip > app/dns: returning nil for '
          'domain missing.invalid > rcode: 3')
      ..add('xray', '[Error] [42] proxy/vless/outbound: failed to find an available destination > dial tcp: i/o timeout')
      ..add('xray', '[Info] [7] app/dispatcher: taking detour [proxy] for [tcp:example.com:443]');
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const Shell())));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byIcon(Icons.receipt_long_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Текущее подключение').first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // Цвет пометки уровня в строке с [text] (кусок сообщения).
    Color? tagColor(String text) {
      for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
        final spans = <TextSpan>[];
        rich.text.visitChildren((s) {
          if (s is TextSpan) spans.add(s);
          return true;
        });
        if (!spans.any((s) => s.text?.contains(text) ?? false)) continue;
        final tag = spans.where((s) => s.text == '[Error] ' || s.text == '[Info] ').firstOrNull;
        if (tag != null) return tag.style?.color;
      }
      return null;
    }

    expect(tagColor('missing.invalid'), C.warnText);
    expect(tagColor('i/o timeout'), C.red);
    expect(tagColor('taking detour'), C.green);

    const shots = String.fromEnvironment('SKIPIT_SHOTS');
    if (shots.isNotEmpty) {
      await expectLater(find.byType(MaterialApp), matchesGoldenFile(Uri.file('$shots\\log_levels.png')));
    }
  });
}
