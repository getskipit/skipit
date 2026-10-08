import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/dns_check.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/core/xray_config.dart';

/// Проверка DNS-серверов подключения: список серверов из конфига, вход проверки в основном ядре
/// и сам замер временным ядром — на настоящем Xray, без выхода в интернет.
void main() {
  final config = {
    'dns': {
      'tag': 'dns-in',
      'servers': [
        {'address': '77.88.8.8', 'domains': ['domain:ru', 'domain:su'], 'skipFallback': true},
        {'address': 'https+local://doh.example/dns-query', 'timeoutMs': 1500},
        'https://cloudflare-dns.com/dns-query',
        {'address': '77.88.8.8', 'domains': ['full:vpn.example'], 'skipFallback': true},
        {'address': '9.9.9.9', 'port': 9953},
        'localhost',
      ],
    },
    'outbounds': [
      {'tag': 'proxy', 'protocol': 'freedom'},
      {'tag': 'direct', 'protocol': 'freedom'},
    ],
    'routing': {
      'rules': [
        {'inboundTag': ['dns-in'], 'ip': ['77.88.8.8'], 'outboundTag': 'direct'},
        {'inboundTag': ['dns-in'], 'outboundTag': 'proxy'},
        {'inboundTag': ['socks'], 'outboundTag': 'proxy'},
      ],
    },
  };

  test('список серверов: без повторов, с пометкой «напрямую» и лимитом ожидания', () {
    final probes = DnsCheck.servers(config);
    expect(probes.any((p) => p.service), isFalse);
    // Служебные серверы, которые программа добавила сама, помечаются отдельно.
    final withService = DnsCheck.servers({
      'dns': {
        'servers': [
          '1.1.1.1',
          {'address': 'tcp+local://1.1.1.1', 'domains': ['full:vpn.example'], 'skipFallback': true},
        ],
      },
    }, service: {'tcp+local://1.1.1.1'});
    expect(withService.map((p) => p.service), [false, true]);
    expect(probes.map((p) => p.label),
        ['77.88.8.8', 'https+local://doh.example/dns-query', 'https://cloudflare-dns.com/dns-query', '9.9.9.9:9953']);
    expect(probes[0].domains, 3);
    expect(probes[1].local, isTrue);
    expect(probes[1].limitMs, 1500);
    expect(probes[2].local, isFalse);
    expect(probes[2].domains, 0);

    // Ответ позже, чем ядро готово ждать, помечается.
    probes[1]
      ..firstMs = 1700
      ..nextMs = 90;
    expect(probes[1].slow, isTrue);
    expect(probes[1].result, 'первый запрос 1700 мс, следующий 90 мс');
    expect(probes[1].path, 'напрямую, мимо правил');
    expect(probes[2].result, 'не ответил за 5 с');
  });

  test('вход проверки DNS: правила для запросов DNS действуют и на него', () {
    final cfg = jsonDecode(jsonEncode(config)) as Map<String, dynamic>;
    XrayConfig.addDnsCheckInbound(cfg, port: 20961, password: 'p');
    final inbound = (cfg['inbounds'] as List).single as Map;
    expect(inbound['listen'], '127.0.0.1');
    final rules = (cfg['routing'] as Map)['rules'] as List;
    expect(rules[0]['inboundTag'], ['dns-in', XrayConfig.dnsCheckInTag]);
    expect(rules[1]['inboundTag'], ['dns-in', XrayConfig.dnsCheckInTag]);
    expect(rules[2]['inboundTag'], ['socks']);
  });

  test('замер: временное ядро спрашивает сервер через вход проверки основного ядра', () async {
    await AppPaths.init();
    if (!File(AppPaths.xrayExe).existsSync()) return;

    // Ядро принимает оба вида конфига временной копии.
    for (final probe in DnsCheck.servers(config)) {
      final f = File('${Directory.systemTemp.path}\\skipit-dns-helper-test.json');
      await f.writeAsString(jsonEncode(DnsCheck.helperConfig(probe, port: 20962, checkPort: 20963, password: 'secret', nic: 'Ethernet')));
      final r = await Process.run(AppPaths.xrayExe, ['run', '-test', '-c', f.path]);
      expect(r.exitCode, 0, reason: '${probe.label}\n${r.stdout}\n${r.stderr}');
      await f.delete();
    }

    // Свой DNS-сервер на этом компьютере: на любой запрос отвечает одним адресом.
    final server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    var asked = 0;
    server.listen((event) {
      final packet = event == RawSocketEvent.read ? server.receive() : null;
      if (packet == null) return;
      asked++;
      final q = packet.data;
      server.send([
        q[0], q[1], 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0,
        ...q.sublist(12),
        0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 203, 0, 113, 7,
      ], packet.address, packet.port);
    });

    // «Основное ядро»: только вход проверки DNS.
    final main = <String, dynamic>{
      'log': {'loglevel': 'warning'},
      'outbounds': [
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
    };
    XrayConfig.addDnsCheckInbound(main, port: 20963, password: 'secret');
    final core = await Process.start(AppPaths.xrayExe, ['run', '-c', 'stdin:']);
    core.stdin.add(utf8.encode(jsonEncode(main)));
    await core.stdin.close();
    await core.stdout.transform(utf8.decoder).firstWhere((line) => line.contains('started'));

    final probe = DnsProbe(address: '127.0.0.1', port: server.port, domains: 0);
    await DnsCheck.run(probe, checkPort: 20963, password: 'secret');
    core.kill();
    server.close();

    expect(probe.error, isNull);
    expect(probe.firstMs, isNotNull, reason: 'временное ядро не получило ответ от DNS-сервера');
    expect(probe.nextMs, isNotNull);
    expect(asked, 2);

    // Сервер, которого нет, — «не ответил».
    final dead = DnsProbe(address: '127.0.0.1', port: 9, domains: 0);
    await DnsCheck.run(dead, checkPort: 20964, password: 'secret');
    expect(dead.ok, isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
