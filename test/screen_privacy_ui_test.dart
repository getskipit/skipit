import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/models/server.dart';
import 'package:skipit/models/subscription.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/shell.dart';
import 'package:skipit/ui/servers_panel.dart';
import 'package:skipit/ui/theme.dart';
import 'package:skipit/ui/widgets.dart';

void main() {
  setUpAll(() async {
    await AppPaths.init();
    final loader = FontLoader('Segoe UI');
    for (final name in ['segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf']) {
      final file = File('${Platform.environment['WINDIR']}\\Fonts\\$name');
      if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
    final icons = FontLoader('MaterialIcons');
    final materialFont = File('D:/tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (materialFont.existsSync()) icons.addFont(Future.value(ByteData.sublistView(materialFont.readAsBytesSync())));
    await icons.load();
  });
  testWidgets('subscription error masks IP and URLs while screen hiding is on', (tester) async {
    tester.view.physicalSize = const Size(944, 561);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    C.use(Palette.dark);
    final state = AppState()..screenPrivacy = true;
    final sub = Subscription(url: 'https://subscription.example/list', name: 'Provider',
        error: 'Ошибка 203.0.113.7 https://status.example/problem');
    state.subscriptions.add(sub);
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(),
        home: const Scaffold(body: ServersPanel(manage: true)))));
    await tester.pump();
    expect(find.textContaining('203.0.113.7'), findsNothing);
    expect(find.textContaining('https://status.example/problem'), findsNothing);
    expect(sub.error, 'Ошибка 203.0.113.7 https://status.example/problem');
    state.toggleScreenPrivacy();
    await tester.pump();
    expect(find.textContaining('203.0.113.7'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
  testWidgets('address hiding is controlled in Appearance', (tester) async {
    tester.view.physicalSize = const Size(944, 561);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    C.use(Palette.dark);
    final state = AppState();
    state.routingProfiles.add(RoutingProfile.global());
    await tester.pumpWidget(AppScope(state: state, child: RepaintBoundary(child:
        MaterialApp(theme: buildTheme(), home: const Shell()))));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byIcon(Icons.tune_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Внешний вид').first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    final title = find.text('Скрыть IP и ссылки');
    await tester.ensureVisible(title);
    await tester.pump(const Duration(milliseconds: 400));
    final row = find.ancestor(of: title, matching: find.byType(Row)).first;
    final toggle = find.descendant(of: row, matching: find.byType(AppSwitch));
    expect(toggle, findsOneWidget);
    const shots = String.fromEnvironment('SKIPIT_SHOTS');
    if (shots.isNotEmpty) await expectLater(find.byType(RepaintBoundary).first,
        matchesGoldenFile(Uri.file('$shots/privacy-appearance.png')));
    await tester.tap(toggle);
    await tester.pump();
    expect(state.screenPrivacy, isTrue);
    await tester.tap(toggle);
    await tester.pump();
    expect(state.screenPrivacy, isFalse);
    expect(tester.takeException(), isNull);
  });
  testWidgets('custom check URL stays hidden in settings', (tester) async {
    tester.view.physicalSize = const Size(944, 561);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    C.use(Palette.dark);
    final state = AppState()..screenPrivacy = true;
    state.settings.testUrlOwn = true;
    state.settings.testUrl = 'https://checks.example/private';
    state.routingProfiles.add(RoutingProfile.global());
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const Shell())));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byIcon(Icons.tune_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Подписки и серверы').first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    final field = find.byWidgetPredicate((w) => w is TextFormField && w.initialValue == 'https://checks.example/private');
    await tester.ensureVisible(field);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<TextField>(find.descendant(of: field, matching: find.byType(TextField))).obscureText, isTrue);
    expect(state.settings.testUrl, 'https://checks.example/private');
    expect(tester.takeException(), isNull);
  });
  for (final top in [false, true]) {
    testWidgets('toggle hides IP and links with ${top ? 'top' : 'side'} menu', (tester) async {
      tester.view.physicalSize = const Size(944, 561);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      C.use(Palette.dark);
      final state = AppState()..settings.navTop = top;
      state.routingProfiles.add(RoutingProfile.global());
      final sub = Subscription(url: 'https://panel.example/my-token', name: 'Provider');
      sub.announce = 'Message https://announce.example/secret 203.0.113.11';
      final server = ServerProfile(name: 'Germany 203.0.113.12', protocol: 'vless',
          address: '203.0.113.12', port: 443, link: 'vless://example@203.0.113.12:443',
          outbound: const {}, subscriptionId: sub.id);
      state.subscriptions.add(sub);
      state.servers.add(server);
      state.settings.selectedServerId = server.id;
      state.log.startSession('Germany 203.0.113.12');
      state.log.add('xray', 'connecting 203.0.113.14 to https://log.example/token');
      await tester.pumpWidget(AppScope(state: state, child: RepaintBoundary(child:
          MaterialApp(theme: buildTheme(), home: const Shell()))));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('203.0.113.12', findRichText: true), findsWidgets);
      state.toggleScreenPrivacy();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.screenPrivacy, isTrue);
      expect(find.textContaining('203.0.113.12', findRichText: true), findsNothing);
      expect(find.textContaining('203.0.113.11', findRichText: true), findsNothing);
      expect(find.textContaining('https://announce.example/secret', findRichText: true), findsNothing);
      expect(find.textContaining('Germany', findRichText: true), findsWidgets);
      const shots = String.fromEnvironment('SKIPIT_SHOTS');
      if (shots.isNotEmpty) await expectLater(find.byType(RepaintBoundary).first,
          matchesGoldenFile(Uri.file('$shots/privacy-${top ? 'top' : 'side'}.png')));
      await tester.tap(find.byIcon(Icons.receipt_long_rounded).first);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Текущее подключение'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('203.0.113.14', findRichText: true), findsNothing);
      expect(find.textContaining('https://log.example/token', findRichText: true), findsNothing);
      state.toggleScreenPrivacy();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.screenPrivacy, isFalse);
      expect(find.textContaining('203.0.113.14', findRichText: true), findsWidgets);
      expect(server.address, '203.0.113.12');
      expect(sub.url, 'https://panel.example/my-token');
      state.log.endSession();
    });
  }
}
