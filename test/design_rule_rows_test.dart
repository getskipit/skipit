import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/routing_page.dart';
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
  test('compact setting survives serialization', () {
    final s = AppSettings()..compactRuleRows = true;
    expect(AppSettings.fromJson(s.toJson()).compactRuleRows, true);
    expect(AppSettings.fromJson({}).compactRuleRows, false);
  });
  testWidgets('routing editor displays actions and compact profiles', (tester) async {

    tester.view.physicalSize = const Size(944, 561);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    C.use(Palette.dark);
    final state = AppState()..settings.compactRuleRows = true;
    state.routingProfiles.addAll([RoutingProfile.global(), ...RoutingProfile.templates()]);
    await tester.pumpWidget(AppScope(state: state, child: RepaintBoundary(child: MaterialApp(theme: buildTheme(), home: const Scaffold(body: RoutingPage())))));
    await tester.pump(const Duration(milliseconds: 400));
    const shots = String.fromEnvironment('SKIPIT_SHOTS');
    if (shots.isNotEmpty) await expectLater(find.byType(RepaintBoundary).first, matchesGoldenFile(Uri.file('$shots/compact-routing.png')));
    await tester.tap(find.byTooltip('Изменить').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsOneWidget);
    if (shots.isNotEmpty) await expectLater(find.byType(RepaintBoundary).first, matchesGoldenFile(Uri.file('$shots/routing-editor.png')));
    expect(tester.takeException(), isNull);
  });
}
