import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/core/site_check.dart';
import 'package:skipit/core/dns_check.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/subscription.dart';
import 'package:skipit/ui/servers_panel.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/check_page.dart';
import 'package:skipit/ui/qr_ui.dart';
import 'package:skipit/ui/routing_page.dart';
import 'package:skipit/ui/theme.dart';
import 'package:skipit/ui/screen_privacy.dart';

void main() {
  setUpAll(() async {
    await AppPaths.init();
    for (final (family, names) in [('Segoe UI', ['segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf']), ('Consolas', ['consola.ttf'])]) {
      final loader = FontLoader(family);
      for (final name in names) {
        final file = File('${Platform.environment['WINDIR']}\\Fonts\\$name');
        if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
      }
      await loader.load();
    final icons = FontLoader('MaterialIcons');
    final materialFont = File('D:/tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (materialFont.existsSync()) icons.addFont(Future.value(ByteData.sublistView(materialFont.readAsBytesSync())));
    await icons.load();
    }
  });
  testWidgets('editing masks only addresses and preserves text across toggles', (tester) async {
    final state = AppState();
    final controller = ScreenPrivacyController(text: 'Provider https://panel.example/token 203.0.113.5',
        hidden: () => state.screenPrivacy);
    addTearDown(controller.dispose);
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(home: Scaffold(body:
      Builder(builder: (context) {
        AppScope.of(context);
        return Column(children: [TextField(controller: controller), TextButton(
          onPressed: state.toggleScreenPrivacy, child: const Text('Toggle'),
        )]);
      }),
    ))));
    String rendered() => tester.state<EditableTextState>(find.byType(EditableText)).renderEditable.text!.toPlainText();
    expect(rendered(), contains('203.0.113.5'));
    await tester.tap(find.text('Toggle'));
    await tester.pump();
    expect(rendered(), contains('Provider'));
    expect(rendered(), isNot(contains('203.0.113.5')));
    expect(rendered(), isNot(contains('panel.example')));
    expect(controller.text, 'Provider https://panel.example/token 203.0.113.5');
    await tester.tap(find.text('Toggle'));
    await tester.pump();
    expect(rendered(), contains('203.0.113.5'));
  });
  testWidgets('profile editor hides IP, DNS and list links', (tester) async {
    tester.view.physicalSize = const Size(944, 561);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    C.use(Palette.dark);
    final state = AppState()..screenPrivacy = true;
    state.routingProfiles.addAll([
      RoutingProfile.global(),
      RoutingProfile(name: 'Profile', proxyIp: ['203.0.113.25'],
          remoteDnsType: 'DoU', remoteDnsIp: '203.0.113.26',
          ruleLists: [RuleListSource(url: 'https://rules.example/private')]),
      RoutingProfile(name: 'Second'),
    ]);
    await tester.pumpWidget(AppScope(state: state, child: RepaintBoundary(child:
        MaterialApp(theme: buildTheme(), home: const Scaffold(body: RoutingPage())))));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('Изменить').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('https://rules.example/private', findRichText: true), findsNothing);
    final fields = tester.widgetList<TextField>(find.byType(TextField));
    final controller = fields.where((f) => f.controller?.text == '203.0.113.26').single.controller! as ScreenPrivacyController;
    final shown = controller.buildTextSpan(context: tester.element(find.byType(TextField).first), withComposing: false).toPlainText();
    expect(shown, isNot(contains('203.0.113.26')));
    expect(controller.text, '203.0.113.26');
    const shots = String.fromEnvironment('SKIPIT_SHOTS');
    if (shots.isNotEmpty) await expectLater(find.byType(RepaintBoundary).first,
        matchesGoldenFile(Uri.file('$shots/privacy-routing.png')));
    expect(tester.takeException(), isNull);
  });
  testWidgets('report preview masks output without changing saved data', (tester) async {
    tester.view.physicalSize = const Size(944, 561);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState()..screenPrivacy = true;
    const report = 'Provider 203.0.113.30\nhttps://report.example/token';
    await tester.pumpWidget(AppScope(state: state, child: RepaintBoundary(child: MaterialApp(
      theme: buildTheme(), home: Scaffold(body: ReportPreviewDialog(report: Future.value(report))),
    ))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Provider'), findsOneWidget);
    expect(find.textContaining('203.0.113.30'), findsNothing);
    expect(find.textContaining('https://report.example/token'), findsNothing);
    expect(find.textContaining('[…]'), findsWidgets);
    expect(find.textContaining('в файле сохранятся исходные данные'), findsOneWidget);
    const shots = String.fromEnvironment('SKIPIT_SHOTS');
    if (shots.isNotEmpty) await expectLater(find.byType(RepaintBoundary).first,
        matchesGoldenFile(Uri.file('$shots/privacy-report.png')));
    expect(tester.takeException(), isNull);
  });
  testWidgets('subscription editor hides links and retains the original value', (tester) async {
    tester.view.physicalSize = const Size(944, 561);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState()..screenPrivacy = true;
    final sub = Subscription(name: 'Provider', url: 'https://panel.example/private');
    state.subscriptions.add(sub);
    state.routingProfiles.add(RoutingProfile.global());
    await tester.pumpWidget(AppScope(state: state, child: RepaintBoundary(child:
      MaterialApp(theme: buildTheme(), home: const Scaffold(body: ServersPanel(manage: true))))));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('Ещё').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Изменить').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final fields = tester.widgetList<TextField>(find.byType(TextField));
    final controller = fields.where((f) => f.controller?.text == sub.url).single.controller! as ScreenPrivacyController;
    final shown = controller.buildTextSpan(context: tester.element(find.byType(TextField).first), withComposing: false).toPlainText();
    expect(shown, isNot(contains('panel.example')));
    expect(controller.text, sub.url);
    expect(find.text('Provider'), findsWidgets);
    const shots = String.fromEnvironment('SKIPIT_SHOTS');
    if (shots.isNotEmpty) await expectLater(find.byType(RepaintBoundary).first,
        matchesGoldenFile(Uri.file('$shots/privacy-subscription.png')));
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(sub.url, 'https://panel.example/private');
  });
  testWidgets('site and DNS results hide IPs and links', (tester) async {
    tester.view.physicalSize = const Size(944, 561);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState()..screenPrivacy = true;
    state.siteReports = [SiteReport('site.example', shown: 'https://site.example/private')
      ..done = true ..firstMs = 20 ..address = '203.0.113.36' ..addressMs = 10];
    state.dnsProbes = [DnsProbe(address: 'https://dns.example/secret', domains: 0)
      ..done = true ..firstMs = 20];
    await tester.pumpWidget(AppScope(state: state, child: RepaintBoundary(child:
      MaterialApp(theme: buildTheme(), home: const Scaffold(body: CheckPage())))));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('https://site.example/private', findRichText: true), findsNothing);
    expect(find.textContaining('203.0.113.36', findRichText: true), findsNothing);
    expect(find.textContaining('[…]', findRichText: true), findsWidgets);
    await tester.drag(find.byType(ListView).first, const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(find.text('Как отвечают DNS-серверы'), findsOneWidget);
    expect(find.textContaining('https://dns.example/secret', findRichText: true), findsNothing);
    expect(find.textContaining('[…]', findRichText: true), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  testWidgets('QR containing links cannot be shown in privacy mode', (tester) async {
    final state = AppState()..screenPrivacy = true;
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(home: Scaffold(
      body: Builder(builder: (context) => TextButton(onPressed: () => showQrDialog(context,
          title: 'Sensitive QR', text: 'https://example.com/secret'), child: const Text('Open QR'))),
    ))));
    await tester.tap(find.text('Open QR'));
    await tester.pump();
    expect(find.text('Sensitive QR'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
