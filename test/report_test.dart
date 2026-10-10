import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/report.dart';
import 'package:skipit/models/settings.dart';

void main() {
  const uuid = '11111111-2222-3333-4444-555555555555';
  const key = 'PUBLICKEYxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';
  final xray = <String, dynamic>{
    'log': {'loglevel': 'debug'},
    'dns': {
      'tag': 'dns-in',
      'hosts': {'secret-host.example': '203.0.113.9'},
      'servers': [
        {
          'address': 'https://doh.example/dns-query',
          'domains': ['domain:private-site.example'],
          'timeoutMs': 1500,
        },
        '1.1.1.1',
      ],
    },
    'inbounds': [
      {
        'tag': 'socks',
        'protocol': 'socks',
        'listen': '127.0.0.1',
        'port': 10808,
        'settings': {
          'accounts': [
            {'user': 'portuser', 'pass': 'portpassword'},
          ],
        },
      },
    ],
    'outbounds': [
      {
        'tag': 'proxy',
        'protocol': 'vless',
        'settings': {'address': 'vpn.example', 'port': 443, 'id': uuid},
        'streamSettings': {
          'network': 'tcp',
          'security': 'reality',
          'realitySettings': {'serverName': 'cover.example', 'publicKey': key, 'shortId': 'abcd1234'},
          'sockopt': {'domainStrategy': 'UseIPv4'},
        },
      },
      {
        'tag': 'skipit-direct',
        'protocol': 'freedom',
        'streamSettings': {
          'sockopt': {'domainStrategy': 'ForceIPv4'},
        },
      },
    ],
    'routing': {
      'rules': [
        {
          'domain': ['domain:private-site.example', 'full:another.example'],
          'outboundTag': 'skipit-direct',
        },
        {'network': 'tcp,udp', 'outboundTag': 'proxy'},
      ],
    },
    'burstObservatory': {
      'subjectSelector': ['proxy'],
      'pingConfig': {'destination': 'https://probe.example/generate_204', 'interval': '30s'},
    },
  };

  test('отчёт: из конфига Xray берётся только устройство — без ключей, адресов серверов и списков сайтов', () {
    final text = jsonEncode(DiagReport.xrayShape(xray));
    for (final secret in [
      'vpn.example',
      uuid,
      key,
      'abcd1234',
      'cover.example',
      'portpassword',
      'portuser',
      'private-site.example',
      'another.example',
      'secret-host.example',
      'probe.example',
    ]) {
      expect(text, isNot(contains(secret)), reason: secret);
    }
    // А то, что нужно для разбора, на месте.
    for (final kept in ['vless', 'reality', 'ForceIPv4', 'skipit-direct', '(2 имён)', '1500', 'doh.example']) {
      expect(text, contains(kept), reason: kept);
    }
    expect(DiagReport.serverAddresses(xray), {'vpn.example', 'cover.example'});
  });

  test('отчёт: в журнале адреса VPN-серверов и имя пользователя Windows скрыты, сайты остаются', () {
    const log = 'xray\ttunneling request to tcp:site.example:443 via vpn.example:443\n'
        'xray\tapp/dns: UDP//1.1.1.1 got answer: vpn.example. TypeA -> [203.0.113.7 203.0.113.8], rtt: 20ms\n'
        'xray\ttransport/internet: dialing to tcp:203.0.113.7:443\n'
        'xray\tapp/dns: UDP//1.1.1.1 got answer: site.example. TypeA -> [198.51.100.5], rtt: 20ms\n'
        r'app' '\t' r'папка C:\Users\ivan\AppData\Roaming\SkipIt';
    final report = DiagReport.build(facts: {'Версия': '1.1.2', 'Страна выхода': null}, xray: xray, log: log);
    for (final secret in ['vpn.example', '203.0.113.7', '203.0.113.8', 'ivan', uuid, key]) {
      expect(report, isNot(contains(secret)), reason: secret);
    }
    expect(report, contains('tcp:site.example:443 via <VPN-сервер>:443'));
    expect(report, contains('dialing to tcp:<VPN-сервер>:443'));
    // Адрес обычного сайта — не секрет: без него по журналу ничего не понять.
    expect(report, contains('198.51.100.5'));
    expect(report, contains(r'C:\Users\<пользователь>\AppData'));
    expect(report, contains('Версия: 1.1.2'));
    expect(report, contains('Страна выхода: —'));
    expect(report, contains('=== Конфиг sing-box (устройство) ===\nядро в этом запуске не запускалось'));
  });

  test('отчёт: скрыты и соседние имена на домене провайдера — его сайт и адрес подписки', () {
    expect(DiagReport.domainOf('fi.host.example'), 'host.example');
    expect(DiagReport.domainOf('host.example'), 'host.example');
    expect(DiagReport.domainOf('a.b.host.co.uk'), 'host.co.uk');
    final cfg = <String, dynamic>{
      'outbounds': [
        {
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': {'address': 'fi.host.example', 'port': 443, 'id': uuid},
        },
      ],
    };
    const log = 'xray\tproxy/http: request to Method [CONNECT] Host [panel.host.example:443]\n'
        'xray\ttunneling request to tcp:panel.host.example:443 via fi.host.example:443\n'
        'xray\ttunneling request to tcp:pay.billing.example:443 via fi.host.example:443\n'
        'xray\ttunneling request to tcp:site.example:443 via fi.host.example:443';
    final report = DiagReport.build(facts: const {}, xray: cfg, providerHosts: {'sub.billing.example'}, log: log);
    expect(report, isNot(contains('host.example')));
    expect(report, isNot(contains('billing.example')));
    expect(report, contains('Host [<адрес провайдера>:443]'));
    expect(report, contains('tcp:<адрес провайдера>:443 via <VPN-сервер>:443'));
    expect(report, contains('tcp:site.example:443 via <VPN-сервер>:443'));

    // На уровне warning ответов DNS в журнале нет — адрес сервера из ошибки скрывается по готовому списку.
    final quiet = DiagReport.build(
        facts: const {}, xray: cfg, serverIps: {'203.0.113.40'}, log: 'xray\tfailed to dial > dial tcp 203.0.113.40:443: i/o timeout');
    expect(quiet, isNot(contains('203.0.113.40')));
    expect(quiet, contains('dial tcp <VPN-сервер>:443'));
  });

  test('отчёт: журнал длиннее предела попадает в отчёт концом', () {
    final log = '${'начало\n' * 10}${'x' * DiagReport.logLimit}';
    final report = DiagReport.build(facts: const {}, log: log);
    expect(report, isNot(contains('начало')));
    expect(report, contains('(конец, последние 3 МБ)'));
  });

  test('отчёт: из конфига sing-box убраны пароль порта, ключ и списки программ', () {
    final text = jsonEncode(DiagReport.singboxShape({
      'outbounds': [
        {'type': 'socks', 'tag': 'proxy', 'server': '127.0.0.1', 'username': 'portuser', 'password': 'portpassword'},
      ],
      'route': {
        'rules': [
          {
            'process_name': ['game.exe', 'chat.exe'],
            'outbound': 'direct',
          },
          {
            'domain': ['vpn.example'],
            'server': 'bootstrap',
          },
        ],
      },
      'experimental': {
        'clash_api': {'external_controller': '127.0.0.1:10900', 'secret': 'apisecret'},
      },
    }));
    for (final secret in ['portuser', 'portpassword', 'apisecret', 'game.exe', 'vpn.example']) {
      expect(text, isNot(contains(secret)), reason: secret);
    }
    expect(text, contains('(2 программ)'));
    expect(text, contains('socks'));
  });

  test('исключения системного прокси: пусто по умолчанию, свой список сохраняется', () {
    expect(AppSettings().proxyBypass, '');
    expect(AppSettings.fromJson(const {}).proxyBypass, '');
    final own = AppSettings()..proxyBypass = 'localhost;*.corp.example;<local>';
    expect(AppSettings.fromJson(own.toJson()).proxyBypass, 'localhost;*.corp.example;<local>');
  });
}
