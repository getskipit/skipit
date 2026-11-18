import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';
import 'package:skipit/models/subscription.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/settings_page.dart';
import 'package:skipit/ui/shell.dart';
import 'package:skipit/ui/theme.dart';
import 'package:skipit/ui/widgets.dart';

/// Отрисовывает всё окно на каждой странице и в обоих состояниях меню —
/// ловит ошибки вёрстки, которые в релизной сборке видны лишь как пустые области.
void main() {
  setUpAll(() async {
    await AppPaths.init();
    // Настоящий шрифт Windows вместо тестового (в нём каждая буква — широкий квадрат).
    final loader = FontLoader('Segoe UI');
    for (final file in ['segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf', 'seguibl.ttf']) {
      final f = File('${Platform.environment['WINDIR']}\\Fonts\\$file');
      if (f.existsSync()) loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
    await loader.load();
  });

  testWidgets('раздел монтируется при первом открытии и сохраняет свой элемент', (tester) async {
    C.use(Palette.dark);
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState()..routingProfiles.add(RoutingProfile.global());
    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(theme: buildTheme(), home: const Shell()),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    final settings = find.byType(SettingsPage, skipOffstage: false);
    expect(settings, findsNothing);

    state.openPage(AppState.settingsPage);
    await tester.pump();
    final mounted = tester.element(settings);
    state.openPage(0);
    await tester.pump();
    expect(tester.element(settings), same(mounted));
    state.openPage(AppState.settingsPage);
    await tester.pump();
    expect(tester.element(settings), same(mounted));
  });

  testWidgets('таймер подключения обновляет цифры без перестроения главной', (tester) async {
    C.use(Palette.dark);
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState()
      ..status = ConnStatus.connected
      ..connectedAt = DateTime.now().subtract(const Duration(hours: 2));
    state.routingProfiles.add(RoutingProfile.global());
    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(theme: buildTheme(), home: const Shell()),
    ));
    await tester.pump(const Duration(milliseconds: 400));

    final clock = find.textContaining(RegExp(r'^2:\d{2}:\d{2}$'));
    final text = tester.widget<Text>(clock);
    final connect = tester.widget<ConnectButton>(find.byType(ConnectButton));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<Text>(clock), isNot(same(text)));
    expect(tester.widget<ConnectButton>(find.byType(ConnectButton)), same(connect));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final palette in [Palette.dark, Palette.light])
  for (final collapsed in [false, true]) {
    for (final mode in ConnectionMode.values) {
      testWidgets('окно: ${palette.brightness.name}, меню ${collapsed ? 'свёрнуто' : 'развёрнуто'}, режим ${mode.name}', (tester) async {
        C.use(palette);
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final state = AppState()
          ..settings.sidebarCollapsed = collapsed
          ..settings.mode = mode;
        state.routingProfiles.addAll([RoutingProfile.global(), ...RoutingProfile.templates()]);
        // Подписка с трафиком, сроком, объявлением и серверами с флагами + сервер, добавленный вручную.
        final sub = Subscription(url: 'https://panel.example/sub', name: 'SkipIt VPN')
          ..total = 650 * 1024 * 1024 * 1024
          ..download = 228 * 1024 * 1024 * 1024
          ..expire = DateTime.now().add(const Duration(days: 12))
          ..supportUrl = 'https://t.me/support'
          ..announce = 'Перед подключением обновите список. Для мобильного интернета — сервера 🇷🇺 RU';
        state.subscriptions.add(sub);
        final parsed = LinkParser.parseText([
          'vless://b831381d-6324-4d53-ad4f-8cda48b30811@1.2.3.4:443?type=tcp&security=reality&pbk=x&sni=a.com#%F0%9F%87%A9%F0%9F%87%AAGermany',
          'vless://b831381d-6324-4d53-ad4f-8cda48b30811@1.2.3.5:443?type=xhttp&security=tls&sni=a.com#%F0%9F%87%B7%F0%9F%87%BA%20Russia%20-%201%20%5B%D0%A1%D0%BE%D1%82%D0%BE%D0%B2%D0%B0%D1%8F%20%D1%81%D0%B2%D1%8F%D0%B7%D1%8C%5D',
          'trojan://pw@t.com:443#NoFlag',
        ].join('\n'));
        for (final s in parsed.servers) {
          s.subscriptionId = sub.id;
          s.delayMs = 120;
        }
        state.servers.addAll(parsed.servers);
        state.servers.addAll(LinkParser.parseText('[{"remarks":"🇫🇮 Finland JSON","outbounds":[{"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"f.com","port":443,"users":[{"id":"x"}]}]},"streamSettings":{"network":"raw","security":"reality"}}]}]').servers);
        state.settings.selectedServerId = parsed.servers.first.id;
        // Журнал: прошлое подключение с ошибкой и текущий отрезок без подключения.
        state.log
          ..startSession(parsed.servers.first.name, detail: 'Смешанный')
          ..add('xray', '[Warning] proxy/http: failed to read response from ipv6.msftconnecttest.com > unexpected EOF')
          ..add('app', 'Ошибка подключения: порт занят')
          ..endSession()
          ..add('subscription', '«SkipIt VPN» обновлена автоматически');
        await tester.pumpWidget(AppScope(
          state: state,
          child: MaterialApp(theme: buildTheme(), home: const Shell()),
        ));
        await tester.pump(const Duration(milliseconds: 400));
        // Подписи пунктов меню в свёрнутом виде не удаляются, а прячутся анимацией.
        expect(find.text('Главная'), findsOneWidget);

        // Меню подписки («…» в заголовке группы) открывается, в нём нет «Выбрать самый быстрый»,
        // выбор пункта закрывает меню и выполняет действие.
        await tester.tap(find.byIcon(Icons.more_horiz_rounded).last);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Удалить подписку'), findsOneWidget);
        expect(find.text('Закрепить вверху'), findsOneWidget);
        expect(find.text('Выбрать самый быстрый'), findsNothing);
        await tester.tap(find.text('Скопировать ссылку'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Удалить подписку'), findsNothing);

        // Поиск: по названию сервера; по протоколу не ищет; крестик очищает поле.
        await tester.enterText(find.byType(TextField).first, 'vless');
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.textContaining('ничего не найдено'), findsOneWidget);
        await tester.enterText(find.byType(TextField).first, 'germ');
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('NoFlag'), findsNothing);
        await tester.tap(find.byIcon(Icons.close_rounded).first);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('NoFlag'), findsOneWidget);

        // Меню сервера: проверка задержки и просмотр JSON, без «Скопировать ссылку» и «Переименовать».
        await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Проверить задержку (пинг)'), findsOneWidget);
        expect(find.text('Переименовать'), findsNothing);
        await tester.tap(find.text('Показать JSON'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.textContaining('"outbounds"'), findsOneWidget);
        await tester.tap(find.text('Закрыть'));
        await tester.pump(const Duration(milliseconds: 400));

        // Пройти по всем разделам меню.
        for (final icon in [
          Icons.alt_route_rounded,
          Icons.receipt_long_rounded,
          Icons.tune_rounded,
          Icons.bolt_rounded,
        ]) {
          await tester.tap(find.byIcon(icon).first);
          await tester.pump(const Duration(milliseconds: 400));
        }
      });
    }
  }
}
