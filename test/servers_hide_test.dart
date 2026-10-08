import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/server.dart';
import 'package:skipit/models/subscription.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/shell.dart';
import 'package:skipit/ui/theme.dart';

/// Раздел «Серверы»: скрытие подписок и серверов с главной, счётчик и порядок серверов.
void main() {
  testWidgets('скрытое пропадает с главной и из порядка трея, а в «Серверах» остаётся', (tester) async {
    await tester.runAsync(AppPaths.init);
    C.use(Palette.dark);
    tester.view.physicalSize = const Size(1300, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState()..routingProfiles.add(RoutingProfile.global());
    final work = Subscription(url: 'https://a.example/sub', name: 'Рабочая');
    final spare = Subscription(url: 'https://b.example/sub', name: 'Запасная');
    state.subscriptions.addAll([work, spare]);
    List<ServerProfile> add(Subscription sub, List<String> names) {
      final parsed = LinkParser.parseText([
        for (final name in names) 'trojan://pw@$name.example:443#$name',
      ].join('\n')).servers;
      for (final s in parsed) {
        s.subscriptionId = sub.id;
      }
      state.servers.addAll(parsed);
      return parsed;
    }

    final [berlin, amsterdam, cairo] = add(work, ['Berlin', 'Amsterdam', 'Cairo']);
    add(spare, ['Oslo']);
    state.settings.selectedServerId = berlin.id;

    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(theme: buildTheme(), home: const Shell()),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    Future<void> open(String section) async {
      await tester.tap(find.text(section).first);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    }

    expect(find.text('Запасная'), findsOneWidget);
    expect(find.text('Oslo'), findsOneWidget);

    // Скрытая подписка: на главной и в порядке трея её нет, обновляться она продолжает как обычно.
    state.setSubscriptionHidden(spare, true);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Запасная'), findsNothing);
    expect(find.text('Oslo'), findsNothing);
    expect(state.serversInListOrder.map((s) => s.name), ['Berlin', 'Amsterdam', 'Cairo']);

    // Скрытый сервер: то же самое, а если он был выбран — выбор переходит на первый видимый.
    state.setServerHidden(berlin, true);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Berlin'), findsNothing);
    expect(state.selectedServer, amsterdam);
    expect(state.isShown(berlin), isFalse);

    // В разделе «Серверы» скрытое видно, помечено, и есть счётчик.
    await open('Серверы');
    expect(find.text('Запасная'), findsOneWidget);
    expect(find.text('Berlin'), findsOneWidget);
    expect(find.text('скрыта'), findsOneWidget);
    expect(find.text('скрыт'), findsOneWidget);
    expect(find.textContaining('Подписок: 2 (скрыто 1)  ·  серверов: 4 (скрыто 2)'), findsOneWidget);

    // Порядок серверов: по названию и по задержке (непроверенные и недоступные — в конце).
    double y(String name) => tester.getTopLeft(find.text(name).last).dy;
    expect(y('Berlin') < y('Amsterdam') && y('Amsterdam') < y('Cairo'), isTrue);
    state.settings.serverSort = 'name';
    state.changed();
    await tester.pump(const Duration(milliseconds: 400));
    expect(y('Amsterdam') < y('Berlin') && y('Berlin') < y('Cairo'), isTrue);
    berlin.delayMs = -1;
    amsterdam.delayMs = 120;
    cairo.delayMs = 45;
    state.settings.serverSort = 'delay';
    state.changed();
    await tester.pump(const Duration(milliseconds: 400));
    expect(y('Cairo') < y('Amsterdam') && y('Amsterdam') < y('Berlin'), isTrue);

    // Вернули — снова на главной.
    state.setSubscriptionHidden(spare, false);
    await open('Главная');
    expect(find.text('Запасная'), findsOneWidget);
    await tester.pump(const Duration(seconds: 9));
  });

  test('признак «скрыт» сохраняется вместе с подпиской и сервером', () {
    final sub = Subscription(url: 'https://a.example/sub', name: 'A')..hidden = true;
    expect(Subscription.fromJson(sub.toJson()).hidden, isTrue);
    final server = LinkParser.parseLink('trojan://pw@a.example:443#A')!..hidden = true;
    expect(ServerProfile.fromJson(server.toJson()).hidden, isTrue);
    expect(ServerProfile.fromJson(<String, dynamic>{'name': 'A'}).hidden, isFalse);
  });
}
