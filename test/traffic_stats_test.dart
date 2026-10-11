import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/core_manager.dart';
import 'package:skipit/core/singbox_config.dart';
import 'package:skipit/core/util.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/core/xray_config.dart';
import 'package:skipit/models/app_rules.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';

Map<String, String> _stat(String tag, String dir, int value) =>
    {'name': 'outbound>>>$tag>>>traffic>>>$dir', 'value': '$value'};

Map<String, dynamic> _conn(String id, String exe, int up, int down, {String chain = 'direct'}) => {
      'id': id,
      'chains': [chain],
      'upload': up,
      'download': down,
      'metadata': {'processPath': exe},
    };

void main() {
  test('счётчик делит трафик Xray на VPN и «напрямую», блокировка и DNS не считаются', () {
    const routes = {
      'proxy': ConnRoute.proxy,
      'direct': ConnRoute.direct,
      'skipit-direct': ConnRoute.direct,
      'block': ConnRoute.block,
      'skipit-dns': ConnRoute.dns,
    };
    final stats = TrafficStats()
      ..applyXray([
        _stat('proxy', 'uplink', 100),
        _stat('proxy', 'downlink', 5000),
        _stat('direct', 'uplink', 10),
        _stat('direct', 'downlink', 200),
        _stat('skipit-direct', 'downlink', 30),
        _stat('block', 'uplink', 7),
        _stat('skipit-dns', 'uplink', 9),
        _stat('api', 'downlink', 99),
      ], routes);
    expect((stats.vpnUp, stats.vpnDown), (100, 5000));
    expect((stats.directUp, stats.directDown), (10, 230));
    expect((stats.up, stats.down), (110, 5230));
  });

  test('выход, через который ходит другой выход, не считается второй раз', () {
    final cfg = {
      'outbounds': [
        {
          'tag': 'proxy',
          'protocol': 'vless',
          'streamSettings': {
            'sockopt': {'dialerProxy': 'fragment'},
          },
        },
        {'tag': 'fragment', 'protocol': 'freedom'},
        {'tag': 'second', 'protocol': 'vless', 'proxySettings': {'tag': 'first'}},
        {'tag': 'first', 'protocol': 'trojan'},
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
    };
    final skip = XrayConfig.chainedOutbounds(cfg);
    expect(skip, {'fragment', 'first'});

    final stats = TrafficStats()
      ..applyXray([
        _stat('proxy', 'downlink', 1000),
        _stat('fragment', 'downlink', 1000),
        _stat('direct', 'downlink', 50),
      ], const {'proxy': ConnRoute.proxy, 'fragment': ConnRoute.direct, 'direct': ConnRoute.direct}, skip: skip);
    expect((stats.vpnDown, stats.directDown), (1000, 50));
  });

  test('трафик, который sing-box выпустил напрямую сам, прибавляется к «напрямую»', () {
    final stats = TrafficStats()
      ..applyXray([_stat('proxy', 'downlink', 1000), _stat('direct', 'downlink', 40)],
          const {'proxy': ConnRoute.proxy, 'direct': ConnRoute.direct})
      ..applySingbox({
        'connections': [
          _conn('a', r'C:\Games\game.exe', 10, 300),
          // Соединения ядер и то, что ушло в Xray, уже посчитаны на выходах Xray.
          _conn('x', r'C:\Program Files\SkipIt\core\skipit-xray.exe', 500, 9000),
          _conn('p', r'C:\Apps\browser.exe', 70, 800, chain: 'proxy'),
        ],
      });
    expect((stats.vpnDown, stats.directUp, stats.directDown), (1000, 10, 340));

    // Соединение выросло, появилось новое — прибавляется только разница.
    stats.applySingbox({
      'connections': [_conn('a', r'C:\Games\game.exe', 25, 450), _conn('b', r'C:\Games\game.exe', 5, 60)],
    });
    expect((stats.directUp, stats.directDown), (30, 550));

    // Закрытое соединение пропадает из списка — посчитанное остаётся.
    stats.applySingbox({'connections': [_conn('b', r'C:\Games\game.exe', 5, 60)]});
    expect((stats.directUp, stats.directDown), (30, 550));

    stats.reset();
    expect((stats.up, stats.down), (0, 0));
    stats.applySingbox({'connections': [_conn('b', r'C:\Games\game.exe', 5, 60)]});
    expect((stats.directUp, stats.directDown), (5, 60));
  });

  test('скорость считается по прошедшему времени, а не по числу замеров', () {
    const routes = {'proxy': ConnRoute.proxy};
    final t0 = DateTime(2026, 10, 3, 12);
    final stats = TrafficStats()
      ..applyXray([_stat('proxy', 'downlink', 1000)], routes)
      ..markSpeed(t0);
    // Окно было спрятано минуту: накопившееся за это время не выдаётся за скорость одной секунды.
    stats
      ..applyXray([_stat('proxy', 'downlink', 61000)], routes)
      ..markSpeed(t0.add(const Duration(seconds: 60)));
    expect(stats.downSpeed, 1000);
    stats
      ..applyXray([_stat('proxy', 'downlink', 61500)], routes)
      ..markSpeed(t0.add(const Duration(seconds: 61)));
    expect(stats.downSpeed, 500);
  });

  test('итог подключения для журнала: VPN и «напрямую» отдельно', () {
    final stats = TrafficStats();
    expect(AppState.trafficSummary(stats), isNull);
    stats.applyXray([
      _stat('proxy', 'downlink', 3 * 1024 * 1024),
      _stat('proxy', 'uplink', 2048),
      _stat('direct', 'downlink', 1024),
    ], const {'proxy': ConnRoute.proxy, 'direct': ConnRoute.direct});
    final text = AppState.trafficSummary(stats)!;
    expect(text, contains('через VPN: ${formatBytes(3 * 1024 * 1024)} получено, ${formatBytes(2048)} отправлено'));
    expect(text, contains('напрямую: ${formatBytes(1024)} получено, ${formatBytes(0)} отправлено'));
  });

  test('список соединений sing-box слушает только этот компьютер и закрыт ключом', () async {
    final settings = AppSettings();
    final cfg = SingboxConfig.build(
        settings: settings,
        routing: RoutingProfile.global(),
        apps: AppRules(),
        serverDomains: const [],
        statsPort: 10815,
        statsSecret: 'key');
    final api = (cfg['experimental'] as Map)['clash_api'] as Map;
    expect(api['external_controller'], '127.0.0.1:10815');
    expect(api['secret'], 'key');
    // Без порта (TUN на ядре Xray, тесты) списка соединений в конфиге нет.
    final plain = SingboxConfig.build(
        settings: settings, routing: RoutingProfile.global(), apps: AppRules(), serverDomains: const []);
    expect(plain.containsKey('experimental'), isFalse);

    // Проверка самим ядром sing-box, если оно лежит в проекте.
    final singbox = File('core/skipit-sing-box.exe');
    if (singbox.existsSync()) {
      final f = File('${Directory.systemTemp.path}\\skipit-tun-stats-test.json');
      await f.writeAsString(jsonEncode(cfg));
      final r = await Process.run(singbox.absolute.path, ['check', '-c', f.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      await f.delete();
    }
  });
}
