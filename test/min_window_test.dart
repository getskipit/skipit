import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/log_store.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/core/util.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';
import 'package:skipit/models/subscription.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/shell.dart';
import 'package:skipit/ui/theme.dart';

/// Окно наименьшего размера (windows/runner/flutter_window.cpp: kMinWidth × kMinHeight): на каждой
/// странице ничего не вылезает за края, а заголовок страницы остаётся в одну строку.
void main() {
  // Те же числа, что в оболочке окна; клиентская область чуть меньше окна (рамка и заголовок).
  const minClient = Size(960 - 16, 600 - 39);

  setUpAll(() async {
    await AppPaths.init();
    final loader = FontLoader('Segoe UI');
    for (final file in ['segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf', 'seguibl.ttf']) {
      final f = File('${Platform.environment['WINDIR']}\\Fonts\\$file');
      if (f.existsSync()) loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
    await loader.load();
  });

  for (final collapsed in [false, true]) {
    testWidgets('наименьшее окно, меню ${collapsed ? 'свёрнуто' : 'развёрнуто'}', (tester) async {
      C.use(Palette.dark);
      tester.view.physicalSize = minClient;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final state = AppState()..settings.sidebarCollapsed = collapsed;
      state.routingProfiles.addAll([RoutingProfile.global(), ...RoutingProfile.templates()]);
      final sub = Subscription(url: 'https://panel.example/sub', name: 'SkipIt VPN')
        ..total = 650 * 1024 * 1024 * 1024
        ..download = 228 * 1024 * 1024 * 1024
        ..expire = DateTime.now().add(const Duration(days: 12))
        ..announce = 'Перед подключением обновите список. Для мобильного интернета — сервера 🇷🇺 RU';
      state.subscriptions.add(sub);
      final parsed = LinkParser.parseText([
        'vless://b831381d-6324-4d53-ad4f-8cda48b30811@1.2.3.4:443?type=tcp&security=reality&pbk=x&sni=a.com#%F0%9F%87%A9%F0%9F%87%AAGermany',
        'trojan://pw@t.com:443#Russia%20-%201%20%5B%D0%A1%D0%BE%D1%82%D0%BE%D0%B2%D0%B0%D1%8F%20%D1%81%D0%B2%D1%8F%D0%B7%D1%8C%5D',
      ].join('\n'));
      for (final s in parsed.servers) {
        s.subscriptionId = sub.id;
      }
      state.servers.addAll(parsed.servers);
      state.settings.selectedServerId = parsed.servers.first.id;
      state.log
        ..startSession(parsed.servers.first.name, detail: 'Смешанный')
        ..add('app', 'Ошибка подключения: порт занят')
        ..endSession();

      await tester.pumpWidget(AppScope(
        state: state,
        child: MaterialApp(theme: buildTheme(), home: const RepaintBoundary(child: Shell())),
      ));
      await tester.pump(const Duration(milliseconds: 400));

      // Заголовок страницы в одну строку: при кегле 28 это меньше 50 точек высоты.
      void titleOnOneLine(String title) {
        final box = tester.getSize(find.text(title).last);
        expect(box.height, lessThan(50), reason: 'заголовок «$title» не поместился в строку');
      }

      // Картинки страниц для просмотра глазами: flutter test --update-goldens --dart-define=SKIPIT_SHOTS=<папка>.
      const shots = String.fromEnvironment('SKIPIT_SHOTS');
      Future<void> shot(String name) async {
        if (shots.isEmpty) return;
        await expectLater(find.byType(RepaintBoundary).first,
            matchesGoldenFile(Uri.file('$shots\\${collapsed ? 'collapsed' : 'expanded'}_$name.png')));
      }

      await shot('home');
      for (final (icon, title) in [
        (Icons.alt_route_rounded, 'Маршрутизация'),
        (Icons.receipt_long_rounded, 'Логи'),
        (Icons.tune_rounded, 'Настройки'),
      ]) {
        await tester.tap(find.byIcon(icon).first);
        await tester.pump(const Duration(milliseconds: 400));
        titleOnOneLine(title);
        await shot(title);
      }
    });
  }

  testWidgets('наименьшее окно, главная при подключении: счётчики VPN и «напрямую»', (tester) async {
    C.use(Palette.dark);
    tester.view.physicalSize = minClient;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState()
      ..settings.mode = ConnectionMode.mixed
      ..status = ConnStatus.connected
      ..connectedAt = DateTime.now().subtract(const Duration(hours: 3, minutes: 12));
    state.routingProfiles.addAll([RoutingProfile.global(), ...RoutingProfile.templates()]);
    state.stats
      ..upSpeed = 1023 * 1024
      ..downSpeed = 118 * 1024 * 1024
      ..vpnUp = 745 * 1024 * 1024
      ..directUp = 1012 * 1024
      ..vpnDown = 990 * 1024 * 1024 * 1024
      ..directDown = 812 * 1024 * 1024;

    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(theme: buildTheme(), home: const RepaintBoundary(child: Shell())),
    ));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('VPN'), findsNWidgets(2));
    expect(find.text('Напрямую'), findsNWidgets(2));
    expect(find.text(formatBytes(state.stats.directDown)), findsOneWidget);

    // Страна выхода появляется под временем, когда проверка связи её узнала.
    expect(find.text('ЗАЩИЩЕНО'), findsOneWidget);
    expect(find.text('Финляндия'), findsNothing);
    state
      ..exitCountry = 'fi'
      ..notifyListeners();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Финляндия'), findsOneWidget);

    const shots = String.fromEnvironment('SKIPIT_SHOTS');
    Future<void> shot(String name) async {
      if (shots.isEmpty) return;
      await expectLater(find.byType(RepaintBoundary).first, matchesGoldenFile(Uri.file('$shots\\$name.png')));
    }

    await shot('connected_home');

    // Сервер перестал отвечать: вместо «Защищено» — «Нет связи» и карточка с кнопкой.
    state
      ..linkFailsForTest = 2
      ..notifyListeners();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('НЕТ СВЯЗИ'), findsOneWidget);
    expect(find.text('ЗАЩИЩЕНО'), findsNothing);
    expect(find.text('VPN подключён, но связи нет'), findsOneWidget);
    expect(find.text('Переподключиться'), findsOneWidget);
    await shot('connected_home_no_link');

    state
      ..linkFailsForTest = 0
      ..notifyListeners();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('VPN подключён, но связи нет'), findsNothing);
  });

  testWidgets('наименьшее окно, вкладка «Соединения»: счёт за весь отрезок и фильтр по пути', (tester) async {
    C.use(Palette.dark);
    tester.view.physicalSize = minClient;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState();
    state.routingProfiles.addAll([RoutingProfile.global(), ...RoutingProfile.templates()]);
    state.log.startSession('Finland', detail: 'Смешанный · Xray');
    const total = LogBuffer.maxConnections + 12345;
    for (var i = 0; i < total; i++) {
      final route = i % 50 == 0 ? ConnRoute.block : (i % 7 == 0 ? ConnRoute.direct : ConnRoute.proxy);
      state.log.addConnection(ConnEntry(
          network: 'tcp', host: 'rr$i---sn.googlevideo.com', port: 443, inbound: 'http', outbound: route.name, route: route));
    }

    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(theme: buildTheme(), home: const RepaintBoundary(child: Shell())),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byIcon(Icons.receipt_long_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));
    // Пять обращений к одному сайту — в списке одна строка со счётчиком.
    for (final out in ['proxy', 'proxy-2', 'proxy', 'proxy-2', 'proxy']) {
      state.log.addConnection(ConnEntry(
          network: 'tcp', host: 'same.example', port: 443, inbound: 'http', outbound: out, route: ConnRoute.proxy));
    }
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Соединения  ${total + 5}'));
    await tester.pump(const Duration(milliseconds: 400));

    // По умолчанию — «Последняя минута»: числа на кнопках считаются по списку, пометки про 2000 нет.
    expect(find.textContaining('в списке — последние'), findsNothing);
    expect(find.textContaining('same.example:443 → через VPN'), findsOneWidget);
    expect(find.text('×5'), findsOneWidget);
    expect(find.textContaining('(proxy-2) · вход: HTTP-прокси'), findsNothing);
    // Клик по самой строке ничего не раскрывает — только по счётчику.
    await tester.tap(find.textContaining('same.example:443'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('(proxy-2) · вход: HTTP-прокси'), findsNothing);
    await tester.tap(find.text('×5'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('(proxy-2) · вход: HTTP-прокси'), findsNWidgets(2));
    if (const String.fromEnvironment('SKIPIT_SHOTS').isNotEmpty) {
      await expectLater(find.byType(RepaintBoundary).first,
          matchesGoldenFile(Uri.file('${const String.fromEnvironment('SKIPIT_SHOTS')}\\connections_recent.png')));
    }

    // «Всё подключение»: числа — за весь отрезок.
    await tester.tap(find.text('Последняя минута'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('в списке — последние ${LogBuffer.maxConnections}'), findsOneWidget);
    const shots = String.fromEnvironment('SKIPIT_SHOTS');
    if (shots.isNotEmpty) {
      await expectLater(find.byType(RepaintBoundary).first, matchesGoldenFile(Uri.file('$shots\\connections.png')));
    }

    // Фильтр «Напрямую»: в списке остаются только такие соединения.
    await tester.tap(find.textContaining('Напрямую  '));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('через VPN'), findsNothing);
    expect(find.textContaining('напрямую'), findsWidgets);
    state.log.endSession();
  });
}
