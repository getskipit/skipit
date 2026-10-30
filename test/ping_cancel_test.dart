import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/core/ping.dart';
import 'package:skipit/models/server.dart';
import 'package:skipit/models/settings.dart';
import 'package:skipit/state/app_state.dart';

/// «Остановить» в проверке задержки отпускает кнопку и строки сразу, а не когда досидят соединения.
void main() {
  setUpAll(AppPaths.init);

  test('список сетевых карт для проверки по TCP запрашивается один раз на минуту', () async {
    final a = Pinger.physicalSources(['Нет такого адаптера']);
    final b = Pinger.physicalSources(['Нет такого адаптера']);
    expect(identical(a, b), isTrue);
    expect(identical(Pinger.physicalSources(['Другой']), a), isFalse);
    await a;
    // Сеть сменилась — тот же запрос берёт список заново.
    final c = Pinger.physicalSources(['Нет такого адаптера']);
    expect(identical(c, Pinger.physicalSources(['Нет такого адаптера'])), isTrue);
    Pinger.forgetSources();
    expect(identical(c, Pinger.physicalSources(['Нет такого адаптера'])), isFalse);
  });

  test('остановленная проверка задержки сразу снимается, следующую можно начать', () async {
    final state = AppState()..settings.pingType = PingType.tcp;
    final servers = [
      for (var i = 1; i <= 3; i++)
        LinkParser.parseLink(
            'vless://b831381d-6324-4d53-ad4f-8cda48b30811@203.0.113.$i:443?type=tcp&security=tls&sni=a.example#s$i')!,
    ];
    state.servers.addAll(servers);
    final first = state.ping(servers);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(state.pinging, isTrue);
    await state.cancelPing();
    await Future<void>.delayed(Duration.zero);
    expect(state.pinging, isFalse);
    expect(servers.map((s) => s.delayMs), everyElement(isNull));
    // Новая проверка начинается сразу, а запоздалые результаты прежней её не трогают.
    final second = state.ping(servers);
    expect(state.pinging, isTrue);
    await first;
    expect(state.pinging, isTrue);
    await state.cancelPing();
    await second;
    expect(state.pinging, isFalse);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('тестовое ядро не запустилось — у серверов остаются прежние результаты, а не «нет»', () async {
    final state = AppState()..settings.pingType = PingType.realDelay;
    // Такой выход Xray не знает и не запускается.
    final broken = ServerProfile(
      name: 'broken',
      protocol: 'vless',
      address: '203.0.113.1',
      port: 443,
      link: '',
      outbound: {'protocol': 'no-such-protocol', 'settings': {}},
    )..delayMs = 123;
    await state.ping([broken]);
    expect(broken.delayMs, 123);
    expect(state.pinging, isFalse);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('настройки проверки задержки сохраняются и не выходят за пределы', () {
    final s = AppSettings()
      ..pingTimeout = 10
      ..pingParallel = 4;
    final back = AppSettings.fromJson(s.toJson());
    expect((back.pingTimeout, back.pingParallel), (10, 4));
    final wild = AppSettings.fromJson({...s.toJson(), 'pingTimeout': 99, 'pingParallel': 0});
    expect((wild.pingTimeout, wild.pingParallel), (15, 1));
    final old = AppSettings.fromJson({});
    expect((old.pingTimeout, old.pingParallel), (6, 12));
  });
}
