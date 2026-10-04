import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/subscription.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/shell.dart';
import 'package:skipit/ui/theme.dart';

/// Закреплённые подписки меняются местами перетаскиванием заголовка; незакреплённые — нет.
void main() {
  setUpAll(AppPaths.init);

  Future<AppState> open(WidgetTester tester) async {
    C.use(Palette.dark);
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    state.routingProfiles.addAll([RoutingProfile.global(), ...RoutingProfile.templates()]);
    state.subscriptions.addAll([
      Subscription(url: 'https://a.example/sub', name: 'Alpha', pinned: true),
      Subscription(url: 'https://b.example/sub', name: 'Bravo'),
      Subscription(url: 'https://c.example/sub', name: 'Charlie', pinned: true),
      Subscription(url: 'https://d.example/sub', name: 'Delta', pinned: true),
    ]);
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const Shell())));
    await tester.pump(const Duration(milliseconds: 400));
    return state;
  }

  Future<void> drag(WidgetTester tester, String from, String to) async {
    final gesture = await tester.startGesture(tester.getCenter(find.text(from)), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    final target = tester.getCenter(find.text(to));
    // Несколько шагов: перетаскивание начинается, когда указатель прошёл порог.
    for (var i = 1; i <= 5; i++) {
      await gesture.moveTo(Offset.lerp(tester.getCenter(find.text(from).first), target, i / 5)!);
      await tester.pump(const Duration(milliseconds: 30));
    }
    await gesture.up();
    // Карточки доезжают на новые места — ждём конца движения.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  List<String> names(AppState state) => [for (final s in state.subscriptions) s.name];

  testWidgets('закреплённая подписка встаёт на место другой закреплённой', (tester) async {
    final state = await open(tester);
    await drag(tester, 'Alpha', 'Delta');
    expect(names(state), ['Bravo', 'Charlie', 'Delta', 'Alpha']);
    await drag(tester, 'Alpha', 'Charlie');
    expect(names(state), ['Bravo', 'Alpha', 'Charlie', 'Delta']);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('незакреплённую нельзя ни перетащить, ни сдвинуть', (tester) async {
    final state = await open(tester);
    await drag(tester, 'Bravo', 'Alpha');
    await drag(tester, 'Alpha', 'Bravo');
    expect(names(state), ['Alpha', 'Bravo', 'Charlie', 'Delta']);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('рука дрогнула при клике — подписка сворачивается, а не переносится', (tester) async {
    final state = await open(tester);
    final start = tester.getCenter(find.text('Alpha'));
    final gesture = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(start + const Offset(1, 6));
    await tester.pump(const Duration(milliseconds: 30));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.subscriptions.first.expanded, isFalse);
    expect(names(state), ['Alpha', 'Bravo', 'Charlie', 'Delta']);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('клик по заголовку закреплённой подписки по-прежнему сворачивает её', (tester) async {
    final state = await open(tester);
    expect(state.subscriptions.first.expanded, isTrue);
    await tester.tap(find.text('Alpha'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.subscriptions.first.expanded, isFalse);
    await tester.pump(const Duration(seconds: 9));
  });
}
