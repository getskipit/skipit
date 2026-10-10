import 'dart:convert';
import 'dart:io';

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
    expect(DiagReport.serverNames(xray), {'vpn.example'});
  });

  test('отчёт: в журнале адреса VPN-серверов и имя пользователя Windows скрыты, сайты остаются', () {
    const log = 'xray\ttunneling request to tcp:site.example:443 via vpn.example:443\n'
        'xray\tapp/dns: UDP//1.1.1.1 got answer: vpn.example. TypeA -> [203.0.113.7 203.0.113.8], rtt: 20ms\n'
        'xray\ttransport/internet: dialing to tcp:203.0.113.7:443\n'
        'xray\tapp/dns: UDP//1.1.1.1 got answer: site.example. TypeA -> [203.0.113.50], rtt: 20ms\n'
        r'app' '\t' r'папка C:\Users\ivan\AppData\Roaming\SkipIt';
    final report = DiagReport.build(facts: {'Версия': '1.1.2', 'Страна выхода': null}, xray: xray, log: log);
    for (final secret in ['vpn.example', '203.0.113.7', '203.0.113.8', 'ivan', uuid, key]) {
      expect(report, isNot(contains(secret)), reason: secret);
    }
    expect(report, contains('tcp:site.example:443 via <VPN-сервер>:443'));
    expect(report, contains('dialing to tcp:<VPN-сервер>:443'));
    // Адрес обычного сайта — не секрет: без него по журналу ничего не понять.
    expect(report, contains('203.0.113.50'));
    expect(report, contains(r'C:\Users\<пользователь>\AppData'));
    expect(report, contains('Версия: 1.1.2'));
    expect(report, contains('Страна выхода: —'));
    expect(report, contains('=== Конфиг sing-box (устройство) ===\nядро в этом запуске не запускалось'));
  });

  test('отчёт: скрывается адрес целиком — чужие адреса и имена, в которые он входит, не портятся', () {
    const log = 'xray\tdialing to tcp:203.0.113.4:443\n'
        'xray\tdialing to tcp:203.0.113.45:443\n'
        'xray\tdialing to tcp:1203.0.113.4:443\n'
        'xray\ttunneling request to tcp:accounts.cover.example:443 via vpn.example:443\n'
        'xray\ttunneling request to tcp:my-vpn.example.org:443 via vpn.example:443\n'
        // Ответ DNS для чужого имени, в которое входит имя сервера, адресов сервера не даёт.
        'xray\tgot answer: my-vpn.example.org. TypeA -> [203.0.113.60]';
    final report = DiagReport.build(facts: const {}, xray: xray, serverIps: {'203.0.113.4'}, log: log);
    expect(report, contains('dialing to tcp:<VPN-сервер>:443'));
    expect(report, contains('tcp:203.0.113.45:443'));
    expect(report, contains('tcp:1203.0.113.4:443'));
    expect(report, contains('tcp:accounts.cover.example:443 via <VPN-сервер>:443'));
    expect(report, contains('tcp:my-vpn.example.org:443'));
    expect(report, contains('203.0.113.60'));
  });

  test('отчёт: скрыты и соседние имена на домене провайдера — его сайт и адрес подписки', () {
    expect(DiagReport.domainOf('fi.host.example'), 'host.example');
    expect(DiagReport.domainOf('host.example'), 'host.example');
    expect(DiagReport.domainOf('a.b.host.co.example'), 'host.co.example');
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
        facts: const {},
        xray: cfg,
        serverIps: {'203.0.113.40'},
        log: 'xray\tfailed to dial > dial tcp 203.0.113.40:443: i/o timeout');
    expect(quiet, isNot(contains('203.0.113.40')));
    expect(quiet, contains('dial tcp <VPN-сервер>:443'));
  });

  test('отчёт: длинный журнал читается концом, а адрес сервера находится по его началу', () async {
    final dir = await Directory.systemTemp.createTemp('skipit_report_test');
    addTearDown(() => dir.delete(recursive: true));
    final first = File('${dir.path}\\a.log');
    final second = File('${dir.path}\\a-2.log');
    // Ядро узнаёт адрес сервера в первые секунды — в самом начале первой части журнала.
    await first.writeAsString('xray\tgot answer: vpn.example. TypeA -> [203.0.113.7], rtt: 20ms\n${'начало\n' * 1000}');
    await second.writeAsString('${'x' * DiagReport.logLimit}\nxray\tdialing to tcp:203.0.113.7:443\n');

    final journal = await DiagReport.readLog([first, second]);
    expect(journal.cut, isTrue);
    expect(utf8.encode(journal.tail).length, DiagReport.logLimit);
    expect(journal.tail, isNot(contains('начало')));
    expect(journal.head, startsWith('xray\tgot answer: vpn.example.'));

    final report = DiagReport.build(
        facts: const {}, xray: xray, log: journal.tail, logStart: journal.head, logCut: journal.cut);
    expect(report, contains('(конец, последние 3 МБ)'));
    expect(report, isNot(contains('начало')));
    expect(report, isNot(contains('203.0.113.7')));
    expect(report, contains('dialing to tcp:<VPN-сервер>:443'));

    // Короткий журнал идёт в отчёт целиком, начало отдельно не читается.
    final short = await DiagReport.readLog([first]);
    expect(short.cut, isFalse);
    expect(short.head, isEmpty);
    expect(short.tail, startsWith('xray\tgot answer'));
    // Нет файлов — нет журнала, без ошибки.
    expect((await DiagReport.readLog([File('${dir.path}\\нет.log')])).tail, isEmpty);
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
