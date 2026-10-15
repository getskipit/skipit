import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/subscription.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/shell.dart';
import 'package:skipit/ui/theme.dart';

/// Строки серверов не перестраиваются, пока у сервера ничего не поменялось, — но всё, что поменялось
/// (задержка, название, скрытие), видно сразу, и в спрятанном разделе «Серверы» — при переходе в него.
void main() {
  testWidgets('строка сервера показывает новые задержку, название и скрытие', (tester) async {
    await tester.runAsync(AppPaths.init);
    C.use(Palette.dark);
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState()..routingProfiles.add(RoutingProfile.global());
    final sub = Subscription(url: 'https://a.example/sub', name: 'Подписка');
    state.subscriptions.add(sub);
    final servers = LinkParser.parseText([
      for (final name in ['Alpha', 'Beta', 'Gamma']) 'trojan://pw@$name.example:443#$name',
    ].join('\n')).servers;
    for (final s in servers) {
      s.subscriptionId = sub.id;
    }
    state.servers.addAll(servers);
    state.settings.selectedServerId = servers.first.id;
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const Shell())));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Beta'), findsOneWidget);

    servers[1].delayMs = 123;
    state.changed();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('123 мс'), findsOneWidget);

    servers[2].name = 'Delta';
    state.changed();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Delta'), findsOneWidget);
    expect(find.text('Gamma'), findsNothing);

    // Спрятанный раздел «Серверы» узнаёт об изменениях, когда его открывают.
    servers[1].delayMs = 77;
    state.changed();
    state.openPage(1);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('77 мс'), findsOneWidget); // виден только открытый раздел — «Серверы», он до этого спал
    expect(find.text('123 мс'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });
}
