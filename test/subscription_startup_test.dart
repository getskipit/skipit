import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/models/subscription.dart';
import 'package:skipit/state/app_state.dart';

void main() {
  late Directory dir;
  late HttpServer server;
  late AppState state;
  late Subscription sub;
  late int requests;

  setUp(() async {
    await AppPaths.init();
    dir = await Directory.systemTemp.createTemp('skipit-startup-sub');
    AppPaths.dataDir = dir;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    state = AppState()..settings.preferJson = false;
    sub = Subscription(url: 'http://127.0.0.1:${server.port}/sub');
    state.subscriptions.add(sub);
    requests = 0;
  });

  tearDown(() async {
    await server.close(force: true);
    await state.saveNow();
    state.dispose();
    for (var i = 0; i < 10; i++) {
      try { await dir.delete(recursive: true); break; }
      on FileSystemException { await Future<void>.delayed(const Duration(milliseconds: 100)); }
    }
  });

  void listen({bool alwaysFail = false}) {
    server.listen((request) async {
      requests++;
      if (requests == 1 || alwaysFail) {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.destroy();
      } else {
        request.response.write('trojan://password@server.example:443#Recovered');
        await request.response.close();
      }
    });
  }

  Future<void> waitForFailure() async {
    final until = DateTime.now().add(const Duration(seconds: 2));
    while (sub.error == null && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(sub.error, isNotNull);
  }

  test('сетевой сбой при запуске повторяется и снимает ошибку подписки', () async {
    listen();
    final update = state.updateSubscriptionsOnStart();
    await waitForFailure();
    expect(requests, 1);
    await update;
    expect(requests, 2);
    expect(sub.error, isNull);
    expect(state.serversOf(sub.id).single.name, 'Recovered');
    expect(state.log.lines.any((line) => line.text.contains('повторяю обновление')), isTrue);
  });

  test('постоянный сетевой сбой повторяется только один раз', () async {
    listen(alwaysFail: true);
    await state.updateSubscriptionsOnStart();
    expect(requests, 2);
    expect(sub.error, isNotNull);
  });

  test('отказ сервера не вызывает быстрый повтор', () async {
    server.listen((request) {
      requests++;
      request.response..statusCode = 403..close();
    });
    await state.updateSubscriptionsOnStart();
    expect(requests, 1);
    expect(sub.error, contains('403'));
  });

  test('обычное ручное обновление не получает повтор при запуске', () async {
    listen(alwaysFail: true);
    await state.updateAllSubscriptions();
    expect(requests, 1);
    expect(sub.error, isNotNull);
  });

  test('удалённая во время ожидания подписка не обновляется заново', () async {
    listen();
    final update = state.updateSubscriptionsOnStart();
    await waitForFailure();
    state.subscriptions.clear();
    await update;
    expect(requests, 1);
    expect(state.servers, isEmpty);
  });

  test('успешное ручное обновление отменяет ожидающий повтор', () async {
    listen();
    final update = state.updateSubscriptionsOnStart();
    await waitForFailure();
    await state.updateSubscription(sub, silent: true);
    expect(sub.error, isNull);
    await update;
    expect(requests, 2);
  });
}
