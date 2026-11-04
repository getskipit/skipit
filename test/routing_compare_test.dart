import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/routing_page.dart';
import 'package:skipit/ui/routing_compare.dart';
import 'package:skipit/ui/theme.dart';

void main() {
  setUpAll(() async {
    await AppPaths.init();
    final loader = FontLoader('Segoe UI');
    for (final name in ['segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf']) {
      final f = File('${Platform.environment['WINDIR']}\\Fonts\\$name');
      if (f.existsSync()) loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
    await loader.load();
  });
  test('compares saved rules and conceals URL secrets', () {
    final a = RoutingProfile(name: 'A', directSites: ['example.com'], ruleLists: [
      RuleListSource(url: 'https://rules.example/secret-a', action: 'direct'),
    ]);
    final b = RoutingProfile(name: 'B', proxySites: ['example.com'], ruleLists: [
      RuleListSource(url: 'https://rules.example/secret-b', action: 'direct'),
    ]);
    expect(compareRoutingProfiles(a, a), isEmpty);
    final diffs = compareRoutingProfiles(a, b);
    expect(diffs.where((d) => d.title.contains('сайты')), hasLength(2));
    final source = diffs.singleWhere((d) => d.title.contains('Списки по ссылке'));
    expect(source.left.single, isNot(contains('secret-a')));
    expect(source.right.single, isNot(contains('secret-b')));
  });
  testWidgets('compare dialog is accessible at minimum window size', (tester) async {
    tester.view.physicalSize = const Size(944, 561);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    C.use(Palette.dark);
    final state = AppState();
    state.routingProfiles.addAll([RoutingProfile.global(), ...RoutingProfile.templates()]);
    await tester.pumpWidget(AppScope(state: state, child: RepaintBoundary(child:
        MaterialApp(theme: buildTheme(), home: const Scaffold(body: RoutingPage())))));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Сравнить профили'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Сравнение профилей'), findsOneWidget);
    expect(find.text('Закрыть'), findsOneWidget);
    expect(tester.takeException(), isNull);
    const shots = String.fromEnvironment('SKIPIT_SHOTS');
    if (shots.isNotEmpty) await expectLater(find.byType(RepaintBoundary).first,
        matchesGoldenFile(Uri.file('$shots/routing-compare.png')));
    await tester.tap(find.text('Закрыть'));
    await tester.pumpAndSettle();
  });
}
