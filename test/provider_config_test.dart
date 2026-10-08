import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/core/singbox_config.dart';
import 'package:skipit/core/xray_config.dart';
import 'package:skipit/models/app_rules.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';
import 'package:skipit/state/app_state.dart';

/// JSON-подписка в духе Remnawave: балансировщик, DNS-вход, правила «напрямую/через VPN/блок».
const _provider = '''
[{
  "remarks": "🇩🇪Germany",
  "log": {"loglevel": "warning"},
  "dns": {"tag": "dns-in", "servers": [{"address": "77.88.8.8", "domains": ["domain:ru"]}, "1.1.1.1"]},
  "inbounds": [
    {"tag": "socks", "protocol": "socks", "listen": "127.0.0.1", "port": 10808, "settings": {"udp": true}},
    {"tag": "http", "protocol": "http", "listen": "127.0.0.1", "port": 10809}
  ],
  "outbounds": [
    {"tag": "proxy", "protocol": "vless", "settings": {"vnext": [{"address": "de.example.com", "port": 443,
      "users": [{"id": "b831381d-6324-4d53-ad4f-8cda48b30811", "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
     "streamSettings": {"network": "raw", "security": "reality", "realitySettings": {"serverName": "yahoo.com",
      "fingerprint": "chrome", "publicKey": "Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw", "shortId": "6ba8"}}},
    {"tag": "proxy-2", "protocol": "vless", "settings": {"vnext": [{"address": "de2.example.com", "port": 443,
      "users": [{"id": "b831381d-6324-4d53-ad4f-8cda48b30811", "encryption": "none"}]}]},
     "streamSettings": {"network": "xhttp", "security": "tls", "tlsSettings": {"serverName": "de2.example.com"},
      "xhttpSettings": {"path": "/x", "mode": "auto"}}},
    {"tag": "block", "protocol": "blackhole"},
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "dns-out", "protocol": "dns"}
  ],
  "observatory": {"subjectSelector": ["proxy"], "probeUrl": "https://www.gstatic.com/generate_204"},
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "balancers": [{"tag": "PROXY", "selector": ["proxy"], "strategy": {"type": "leastPing"}, "fallbackTag": "proxy"}],
    "rules": [
      {"type": "field", "inboundTag": ["dns-in"], "balancerTag": "PROXY"},
      {"type": "field", "port": 53, "outboundTag": "dns-out"},
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
      {"type": "field", "ip": ["::/0"], "outboundTag": "block"},
      {"type": "field", "network": "udp", "port": "443", "outboundTag": "block"},
      {"type": "field", "ip": ["10.0.0.0/8", "192.168.0.0/16"], "outboundTag": "direct"},
      {"type": "field", "domain": ["domain:ru", "domain:su", "domain:xn--p1ai", "domain:2ip.ru"], "outboundTag": "direct"},
      {"type": "field", "domain": ["domain:telegram.org", "domain:t.me"], "balancerTag": "PROXY"},
      {"type": "field", "network": "tcp,udp", "balancerTag": "PROXY"}
    ]
  }
}]
''';

void main() {
  test('JSON-конфиг провайдера используется целиком, меняются только порты и статистика', () async {
    final server = LinkParser.parseText(_provider).servers.single;
    expect(server.isJson, isTrue);
    expect(server.name, '🇩🇪Germany');

    final settings = AppSettings()
      ..socksPort = 20808
      ..httpPort = 20809;
    final cfg = XrayConfig.build(server: server, routing: RoutingProfile.global(), settings: settings);

    // Правила и балансировщик провайдера на месте.
    final routing = cfg['routing'] as Map;
    expect((routing['rules'] as List).length, 9);
    expect((routing['balancers'] as List).single['tag'], 'PROXY');
    expect(cfg['observatory'], isNotNull);
    expect((cfg['outbounds'] as List).map((o) => o['tag']), containsAll(['proxy', 'proxy-2', 'direct', 'block']));

    // Входы — наши порты, статистика включена.
    final inbounds = cfg['inbounds'] as List;
    expect(inbounds.firstWhere((i) => i['tag'] == 'socks')['port'], 20808);
    expect(inbounds.firstWhere((i) => i['tag'] == 'http')['port'], 20809);
    expect(cfg['api'], isNotNull);
    expect(((cfg['policy'] as Map)['system'] as Map)['statsOutboundUplink'], isTrue);

    final s = XrayConfig.summarize(cfg);
    expect(s.direct, 6);
    expect(s.blockNotes, containsAll(['торренты', 'IPv6', 'QUIC']));

    // Проверка самим ядром Xray, если оно лежит в проекте.
    final xray = File('core/skipit-xray.exe');
    if (xray.existsSync()) {
      final f = File('${Directory.systemTemp.path}\\skipit-provider-test.json');
      await f.writeAsString(jsonEncode(cfg));
      final r = await Process.run(xray.absolute.path, ['run', '-test', '-c', f.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      await f.delete();
    }
  });

  test('«Мой DNS»: адреса берутся из настроек, сохранённый профиль не меняется', () async {
    await AppPaths.init();
    final state = AppState()..routingProfiles.add(RoutingProfile.global());
    expect(state.routingForConfig, same(state.selectedRouting));

    state.settings
      ..ownDns = true
      ..ownDnsRemote = '9.9.9.9'
      ..ownDnsDomestic = 'https://dns.example/dns-query';
    final routing = state.routingForConfig;
    expect(routing.remoteDnsAddress, '9.9.9.9');
    expect(routing.domesticDnsAddress, 'https://dns.example/dns-query');
    expect(routing.id, RoutingProfile.globalPresetId);
    expect(state.selectedRouting.remoteDnsAddress, 'https://cloudflare-dns.com/dns-query');

    // Действует и на сервер с конфигом провайдера, и на обычную ссылку.
    final provider = LinkParser.parseText(_provider).servers.single;
    final link = LinkParser.parseLink(
        'vless://b831381d-6324-4d53-ad4f-8cda48b30811@example.com:443?type=tcp&security=tls&sni=example.com#a')!;
    for (final server in [provider, link]) {
      final dns = XrayConfig.build(server: server, routing: routing, settings: state.settings)['dns'] as Map;
      expect((dns['servers'] as List).first, '9.9.9.9');
    }
  });

  test('«Мой DNS»: несколько адресов через запятую; обычный DNS, TCP, DoH и DoT', () async {
    expect(RoutingProfile.splitDns(' 1.1.1.1, https://dns.google/dns-query;tls://1.1.1.1\n8.8.8.8 '),
        ['1.1.1.1', 'https://dns.google/dns-query', 'tls://1.1.1.1', '8.8.8.8']);
    expect(XrayConfig.dnsServer('1.1.1.1'), '1.1.1.1');
    expect(XrayConfig.dnsServer('udp://1.1.1.1'), '1.1.1.1');
    expect(XrayConfig.dnsServer('udp://1.1.1.1:5353'), {'address': '1.1.1.1', 'port': 5353});
    expect(XrayConfig.dnsServer('9.9.9.9:9953'), {'address': '9.9.9.9', 'port': 9953});
    expect(XrayConfig.dnsServer('2001:4860:4860::8888'), '2001:4860:4860::8888');
    expect(XrayConfig.dnsServer('tcp://8.8.8.8'), 'tcp://8.8.8.8');
    expect(XrayConfig.dnsServer('tcp://8.8.8.8', direct: true), 'tcp+local://8.8.8.8');
    expect(XrayConfig.dnsServer('https://dns.google/dns-query', direct: true), 'https+local://dns.google/dns-query');
    // DNS поверх TLS ядро Xray не умеет: такой адрес оно пропускает.
    expect(XrayConfig.dnsServer('tls://1.1.1.1'), isNull);

    await AppPaths.init();
    final state = AppState()..routingProfiles.add(RoutingProfile.global());
    state.settings
      ..ownDns = true
      ..ownDnsRemote = 'tls://1.1.1.1, https://dns.google/dns-query, 8.8.8.8:53'
      ..ownDnsDomestic = '77.88.8.8, tcp://77.88.8.1';
    final routing = state.routingForConfig;

    final provider = XrayConfig.build(
        server: LinkParser.parseText(_provider).servers.single, routing: routing, settings: state.settings);
    expect((provider['dns'] as Map)['servers'], [
      'https://dns.google/dns-query',
      {'address': '8.8.8.8', 'port': 53},
      {'address': '77.88.8.8', 'domains': ['domain:ru']},
      {'address': 'tcp+local://77.88.8.1', 'domains': ['domain:ru']},
    ]);
    expect(((provider['routing'] as Map)['rules'] as List).first,
        {'ip': ['77.88.8.8'], 'port': '53', 'outboundTag': 'skipit-direct'});

    final link = XrayConfig.build(
        server: LinkParser.parseLink(
            'vless://b831381d-6324-4d53-ad4f-8cda48b30811@example.com:443?type=tcp&security=tls&sni=example.com#a')!,
        routing: routing
          ..directSites = ['domain:ru']
          ..directIp = [],
        settings: state.settings);
    expect((link['dns'] as Map)['servers'], [
      'https://dns.google/dns-query',
      {'address': '8.8.8.8', 'port': 53},
      {'address': '77.88.8.8', 'domains': ['domain:ru'], 'skipFallback': true},
      {'address': 'tcp+local://77.88.8.1', 'domains': ['domain:ru'], 'skipFallback': true},
    ]);

    // Адаптер держит sing-box: запросы DNS он пересылает ядру Xray, и отвечает тот же список с запасными.
    XrayConfig.addDnsInbound(link, port: 20953);
    expect(((link['routing'] as Map)['rules'] as List).first,
        {'inboundTag': ['skipit-dns-port'], 'outboundTag': 'skipit-dns'});

    final xray = File('core/skipit-xray.exe');
    for (final c in [provider, link]) {
      if (!xray.existsSync()) continue;
      final f = File('${Directory.systemTemp.path}\\skipit-own-dns-test.json');
      await f.writeAsString(jsonEncode(c));
      final r = await Process.run(xray.absolute.path, ['run', '-test', '-c', f.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      await f.delete();
    }

    final tun = SingboxConfig.build(
        settings: state.settings, routing: routing, apps: AppRules(), serverDomains: const [], xrayDnsPort: 20953);
    expect(((tun['dns'] as Map)['servers'] as List).first,
        {'type': 'udp', 'tag': 'remote', 'server': '127.0.0.1', 'server_port': 20953});
    final singbox = File('core/skipit-sing-box.exe');
    if (singbox.existsSync()) {
      final f = File('${Directory.systemTemp.path}\\skipit-own-dns-tun-test.json');
      await f.writeAsString(jsonEncode(tun));
      final r = await Process.run(singbox.absolute.path, ['check', '-c', f.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      await f.delete();
    }
  });

  test('свой профиль и свой DNS ложатся поверх конфига провайдера', () async {
    final server = LinkParser.parseText(_provider).servers.single;
    final profile = RoutingProfile(
      name: 'Мои правила',
      proxySites: ['example.org'],
      directSites: ['domain:example.com'],
      directIp: ['203.0.113.0/24'],
      blockSites: ['ads.example'],
      domesticDnsIp: '77.88.8.1',
      dnsHosts: {'router.example': '192.168.1.1'},
    );

    // Списки профиля стоят перед правилами провайдера; «через VPN» — в его балансировщик (автовыбор).
    final cfg = XrayConfig.build(server: server, routing: profile, settings: AppSettings());
    final rules = (cfg['routing'] as Map)['rules'] as List;
    expect(rules.length, 9 + 4);
    expect(rules.take(4), [
      {'domain': ['domain:ads.example'], 'outboundTag': 'skipit-block'},
      {'domain': ['domain:example.org'], 'balancerTag': 'PROXY'},
      {'domain': ['domain:example.com'], 'outboundTag': 'skipit-direct'},
      {'ip': ['203.0.113.0/24'], 'outboundTag': 'skipit-direct'},
    ]);
    // Без выключателя «Мой DNS» остаётся DNS провайдера.
    expect(((cfg['dns'] as Map)['servers'] as List).last, '1.1.1.1');

    // «Мой DNS»: общий DNS провайдера заменён удалённым из профиля, запись «для таких-то сайтов» спрашивает
    // локальный; локальный идёт напрямую, остальные запросы DNS — через VPN.
    final own = XrayConfig.build(server: server, routing: profile, settings: AppSettings()..ownDns = true);
    final dns = own['dns'] as Map;
    expect(dns['servers'], [
      'https://cloudflare-dns.com/dns-query',
      {'address': '77.88.8.1', 'domains': ['domain:ru']},
      {'address': '77.88.8.1', 'domains': ['domain:example.com'], 'skipFallback': true},
    ]);
    expect(dns['hosts'], {'router.example': '192.168.1.1'});
    expect(((own['routing'] as Map)['rules'] as List).take(2), [
      {'ip': ['77.88.8.1'], 'port': '53', 'outboundTag': 'skipit-direct'},
      {'inboundTag': ['dns-in'], 'balancerTag': 'PROXY'},
    ]);

    // Локальный DNS по HTTPS ядро спрашивает само, мимо правил, — то есть напрямую.
    final doh = RoutingProfile(name: 'DoH', domesticDnsType: 'DoH', domesticDnsDomain: 'https://dns.example/dns-query');
    final viaDoh = XrayConfig.build(server: server, routing: doh, settings: AppSettings()..ownDns = true);
    expect(jsonEncode((viaDoh['dns'] as Map)['servers']), contains('https+local://dns.example/dns-query'));
    // Встроенный профиль «Весь трафик через VPN» правил не добавляет.
    final plain = XrayConfig.build(server: server, routing: RoutingProfile.global(), settings: AppSettings());
    expect(((plain['routing'] as Map)['rules'] as List).length, 9);

    // Со всем, что программа дописывает при подключении, теги выходов не повторяются и ядро конфиг принимает.
    final xray = File('core/skipit-xray.exe');
    for (final c in [cfg, own, viaDoh]) {
      XrayConfig.addTun(c, settings: AppSettings(), apps: AppRules());
      XrayConfig.addDirectInbound(c, port: 20901, hosts: ['sub.example'], settings: AppSettings());
      XrayConfig.addCheckInbound(c, port: 20902);
      XrayConfig.resolveServersInside(c, settings: AppSettings());
      final tags = [for (final o in c['outbounds'] as List) o['tag']];
      expect(tags.toSet().length, tags.length, reason: '$tags');
      if (!xray.existsSync()) continue;
      final f = File('${Directory.systemTemp.path}\\skipit-own-rules-test.json');
      await f.writeAsString(jsonEncode(c));
      final r = await Process.run(xray.absolute.path, ['run', '-test', '-c', f.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      await f.delete();
    }
  });
}
