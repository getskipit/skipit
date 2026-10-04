import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/ping.dart';
import 'package:skipit/models/server.dart';

/// Проверка задержки по TCP с привязкой к адресу сетевой карты (так она идёт мимо адаптера VPN).
void main() {
  late ServerSocket listener;
  late ServerProfile server;

  setUp(() async {
    listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    listener.listen((s) => s.destroy());
    server = ServerProfile(
        name: 'local', protocol: 'vless', address: '127.0.0.1', port: listener.port, link: '', outbound: const {});
  });

  tearDown(() => listener.close());

  // Адрес из диапазона для документации: на этом компьютере такого нет, привязаться к нему нельзя.
  final missing = InternetAddress('192.0.2.1');

  test('без привязки и с привязкой к существующему адресу сервер отвечает', () async {
    expect(await Pinger.tcp(server), greaterThanOrEqualTo(0));
    expect(await Pinger.tcp(server, sources: [InternetAddress.loopbackIPv4]), greaterThanOrEqualTo(0));
  });

  test('из нескольких адресов берётся тот, через который сервер ответил', () async {
    expect(await Pinger.tcp(server, sources: [missing, InternetAddress.loopbackIPv4]), greaterThanOrEqualTo(0));
  });

  test('ни через один адрес не вышло — сервер недоступен', () async {
    expect(await Pinger.tcp(server, sources: [missing]), -1);
  });

  test('остановка обрывает соединение с сервером, который не отвечает', () async {
    // Адрес из диапазона для документации: пакеты туда уходят в никуда, ответа не будет.
    final silent = ServerProfile(
        name: 'silent', protocol: 'vless', address: '192.0.2.55', port: 443, link: '', outbound: const {});
    // Если на этом компьютере сейчас подключён VPN с адаптером, на рукопожатие отвечает сам адаптер —
    // молчащего сервера не получится, проверять нечего.
    if (await Pinger.tcp(silent) >= 0) return;
    final cancel = PingCancel();
    final sw = Stopwatch()..start();
    final result = Pinger.tcp(silent, cancel: cancel);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await cancel.cancel();
    expect(await result, -1);
    expect(sw.elapsedMilliseconds, lessThan(2000), reason: 'без обрыва ждали бы все 4 секунды');
  });

  test('адаптер VPN в список сетевых карт не попадает', () async {
    final all = await NetworkInterface.list(type: InternetAddressType.any);
    if (all.isEmpty) return;
    final skipped = all.first.name;
    final sources = await Pinger.physicalSources([skipped]);
    final own = {for (final i in all.where((i) => i.name == skipped)) ...i.addresses.map((a) => a.address)};
    final others = {for (final i in all.where((i) => i.name != skipped)) ...i.addresses.map((a) => a.address)};
    // Адрес может стоять и на другой карте — тогда он остаётся законно.
    expect(sources.where((a) => own.contains(a.address) && !others.contains(a.address)), isEmpty);
    expect(sources.where((a) => a.isLoopback || a.isLinkLocal), isEmpty);
  });
}
