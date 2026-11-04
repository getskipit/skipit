import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/core/rule_list.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/routing_page.dart';
import 'package:skipit/ui/theme.dart';

class TestState extends AppState {
  @override
  void save() {}
}

void main() {
  setUpAll(AppPaths.init);
  test('copy keeps independent rules, DNS and cached lists without provider ownership', () async {
    final dir = await Directory.systemTemp.createTemp('skipit-duplicate-');
    final previous = AppPaths.dataDir;
    AppPaths.dataDir = dir;
    final state = TestState();
    try {
      final source = RuleListSource(url: 'https://rules.example/list', count: 1, updatedAt: DateTime(2026));
      final missing = RuleListSource(url: 'https://rules.example/missing', count: 3, updatedAt: DateTime(2026));
      final original = RoutingProfile(name: 'Profile', subscriptionId: 'provider', globalProxy: false,
          directSites: ['example.com'], dnsHosts: {'router.example': '203.0.113.1'}, ruleLists: [source, missing]);
      state.routingProfiles.addAll([RoutingProfile.global(), original]);
      state.settings.selectedRoutingId = original.id;
      final cache = File(RuleList.path(original.id, source.url));
      await cache.parent.create(recursive: true);
      await cache.writeAsString('domain:example.com');
      final copy = await state.duplicateRoutingProfile(original);
      expect(copy.id, isNot(original.id));
      expect(copy.subscriptionId, isNull);
      expect(copy.name, 'Копия: Profile');
      expect(state.settings.selectedRoutingId, original.id);
      expect(copy.globalProxy, false);
      expect(await File(RuleList.path(copy.id, source.url)).readAsString(), 'domain:example.com');
      expect(copy.ruleLists.first.updatedAt, source.updatedAt);
      expect(copy.ruleLists.last.updatedAt, isNull);
      expect(copy.ruleLists.last.count, 0);
      copy.directSites.add('other.example');
      copy.dnsHosts['router.example'] = '203.0.113.2';
      copy.ruleLists.first.action = 'block';
      expect(original.directSites, ['example.com']);
      expect(original.dnsHosts['router.example'], '203.0.113.1');
      expect(source.action, 'proxy');
      final second = await state.duplicateRoutingProfile(original);
      expect(second.name, 'Копия: Profile (2)');
    } finally {
      state.dispose();
      AppPaths.dataDir = previous;
      await dir.delete(recursive: true);
    }
  });
  testWidgets('profile duplication button creates an inactive copy', (tester) async {
    tester.view.physicalSize = const Size(944, 561);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    C.use(Palette.dark);
    final original = RoutingProfile(name: 'Profile', proxySites: ['example.com']);
    final state = TestState()..routingProfiles.addAll([RoutingProfile.global(), original]);
    state.settings.selectedRoutingId = original.id;
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const Scaffold(body: RoutingPage()))));
    await tester.pump();
    await tester.tap(find.byTooltip('Дублировать профиль'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Копия: Profile'), findsOneWidget);
    expect(state.settings.selectedRoutingId, original.id);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
