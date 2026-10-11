import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/xray_config.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/flag_text.dart';

/// Проверка связи через VPN: отдельный вход ядра, запрос через который всегда идёт на VPN-сервер.
void main() {
  List<Map> checkRules(Map<String, dynamic> cfg) => [
        for (final r in (cfg['routing'] as Map)['rules'] as List)
          if (r is Map && (r['inboundTag'] as List?)?.contains(XrayConfig.checkInTag) == true) r,
      ];

  Future<void> acceptedByCore(Map<String, dynamic> cfg, String name) async {
    final xray = File('core/skipit-xray.exe');
    if (!xray.existsSync()) return;
    final f = File('${Directory.systemTemp.path}\\skipit-check-$name.json');
    await f.writeAsString(jsonEncode(cfg));
    final r = await Process.run(xray.absolute.path, ['run', '-test', '-c', f.path], stdoutEncoding: utf8, stderrEncoding: utf8);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    await f.delete();
  }

  test('свой конфиг: проверка связи идёт на VPN-сервер, даже когда по умолчанию всё напрямую', () async {
    final server = LinkParser.parseText('trojan://pw@t.com:443#S').servers.single;
    // В этом профиле через VPN идут только выбранные сайты — обычный запрос ушёл бы напрямую.
    final routing = RoutingProfile(name: 'Только выбранные', globalProxy: false)..proxySites = ['example.com'];
    final cfg = XrayConfig.build(server: server, routing: routing, settings: AppSettings());
    XrayConfig.addCheckInbound(cfg, port: 10830);

    final inbound = (cfg['inbounds'] as List).last as Map;
    expect((inbound['tag'], inbound['listen'], inbound['port']), (XrayConfig.checkInTag, '127.0.0.1', 10830));
    final rules = checkRules(cfg);
    expect(rules.first['domain'], ['full:${XrayConfig.checkHost}', 'full:${XrayConfig.speedHost}']);
    expect(rules.first['outboundTag'], 'proxy');
    // Через этот вход нельзя ходить никуда, кроме адреса проверки.
    expect((rules.last['outboundTag'], rules.last.containsKey('domain')), ('skipit-block', false));
    // Правила входа стоят первыми — общие правила профиля их не перехватят.
    expect(((cfg['routing'] as Map)['rules'] as List).take(2).toList(), rules);
    await acceptedByCore(cfg, 'own');
  });

  test('конфиг провайдера с автовыбором сервера: проверка идёт в его балансировщик', () async {
    final cfg = XrayConfig.buildFromProvider({
      'outbounds': [
        {
          'tag': 'de-1',
          'protocol': 'trojan',
          'settings': {'servers': [{'address': 'a.example', 'port': 443, 'password': 'p'}]},
          'streamSettings': {'network': 'tcp', 'security': 'tls'},
        },
        {
          'tag': 'de-2',
          'protocol': 'trojan',
          'settings': {'servers': [{'address': 'b.example', 'port': 443, 'password': 'p'}]},
          'streamSettings': {'network': 'tcp', 'security': 'tls'},
        },
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
      'routing': {
        'balancers': [{'tag': 'AUTO', 'selector': ['de-']}],
        'rules': [
          {'type': 'field', 'domain': ['domain:ru'], 'outboundTag': 'direct'},
          {'type': 'field', 'network': 'tcp,udp', 'balancerTag': 'AUTO'},
        ],
      },
    }, AppSettings());
    XrayConfig.addCheckInbound(cfg, port: 10830);
    final rule = checkRules(cfg).first;
    expect((rule['balancerTag'], rule.containsKey('outboundTag')), ('AUTO', false));
    await acceptedByCore(cfg, 'provider');
  });

  test('блокировка файрволом узнаётся по строке ядра — на английской и русской Windows', () {
    expect(
        AppState.looksLikeFirewall('dial tcp 1.2.3.4:443: connectex: An attempt was made to access a socket '
            'in a way forbidden by its access permissions.'),
        isTrue);
    expect(
        AppState.looksLikeFirewall('wsasend: A request to send or receive data was disallowed because the socket is not connected'),
        isTrue);
    expect(AppState.looksLikeFirewall('connectex: Сделана попытка доступа к сокету методом, запрещенным правами доступа.'), isTrue);
    // Числа 10013 и 10057 сами по себе ничего не значат: это может быть номер соединения или порт.
    expect(AppState.looksLikeFirewall('[Info] [10057] proxy/http: request to tcp:example.com:10013'), isFalse);
    expect(AppState.looksLikeFirewall('[Warning] core: Xray 26.9.30 started'), isFalse);
  });

  test('страна выхода пишется по-русски, незнакомая — кодом', () {
    expect(Flags.countryName('fi'), 'Финляндия');
    expect(Flags.countryName('DE'), 'Германия');
    expect(Flags.countryName('zz'), 'ZZ');
  });
}
