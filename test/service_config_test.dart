import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/singbox_config.dart';
import 'package:skipit/core/xray_config.dart';
import 'package:skipit/models/app_rules.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';

/// Служба SkipIt отдаёт ядру конфиг с правами системы, поэтому разбирает его, вырезает поля с файлами и
/// отклоняет оставшиеся пути за рабочей папкой ядра (windows\service\service.cpp, CleanConfig). Конфиги,
/// которые строит сама программа, должны проходить без изменений. Нужна собранная служба (flutter build windows).
void main() {
  final exe = File('${Directory.current.path}\\build\\windows\\x64\\runner\\Release\\skipit-service.exe');
  final hasService = exe.existsSync();

  /// Ответ службы: «ok», причина отказа или (с [clean]) очищенный конфиг.
  Future<String> run(Object config, {bool clean = false}) async {
    final f = File('${Directory.systemTemp.path}\\skipit-service-check-${config.hashCode}.json');
    await f.writeAsString(config is String ? config : jsonEncode(config));
    final r = await Process.run(exe.path, [clean ? '--clean-config' : '--check-config', f.path], stdoutEncoding: utf8);
    await f.delete();
    return (r.stdout as String).trim();
  }

  const uuid = '3b5a3c2e-8f6b-4c7e-9d1a-2f4e6a8c0b1d';
  const pbk = 'SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc';
  final links = [
    'vless://$uuid@example.com:443?type=tcp&security=reality&pbk=$pbk&sid=6ba85179e30d4fc2&sni=www.example.com&fp=chrome&flow=xtls-rprx-vision#a',
    'vless://$uuid@example.com:443?type=xhttp&security=tls&sni=example.com&host=example.com&path=%2Fx&mode=packet-up&alpn=h2&extra=%7B%22xPaddingBytes%22%3A%22100-1000%22%7D#a',
    'vless://$uuid@example.com:443?type=ws&security=tls&sni=example.com&host=example.com&path=%2Fws&fp=firefox#a',
    'vless://$uuid@example.com:443?type=httpupgrade&security=tls&sni=example.com&host=example.com&path=%2Fup#a',
    'vless://$uuid@192.168.1.10:80?type=tcp&headerType=http&host=example.com&path=%2F#a',
    'vless://$uuid@192.168.1.10:443?type=kcp&headerType=wechat-video&seed=secret#a',
    'vless://$uuid@example.com:443?type=ws&security=tls&sni=example.com&path=%2Fws&ech=cloudflare-ech.com%2Bhttps%3A%2F%2F1.1.1.1%2Fdns-query#a',
    'vless://$uuid@example.com:443?type=h2&security=tls&sni=example.com&path=%2Fh2#a',
    'trojan://password@example.com:443?type=grpc&security=tls&sni=example.com&serviceName=t#a',
    // gRPC без serviceName: имя сервиса берётся из path и начинается с «/».
    'vless://$uuid@example.com:443?type=grpc&security=tls&sni=example.com&path=%2Fgrpc#a',
    'hysteria2://password@example.com:443?sni=example.com#a',
  ];
  final apps = AppRules(mode: AppRoutingMode.allExcept, entries: [
    AppEntry(match: 'Telegram', label: 'Telegram', action: AppAction.direct),
    AppEntry(match: 'C:/Games/', label: 'Games', action: AppAction.direct),
  ]);

  test('конфиги программы проходят без изменений: все виды ссылок, адаптер Xray, sing-box с правилами программ',
      () async {
    final configs = <Map<String, dynamic>>[];
    for (final link in links) {
      final server = LinkParser.parseText(link).servers.single;
      final c = XrayConfig.build(server: server, routing: RoutingProfile.templates()[0], settings: AppSettings());
      XrayConfig.addTun(c, settings: AppSettings(), apps: apps);
      configs.add(c);
    }
    configs.add(SingboxConfig.build(
        settings: AppSettings(), routing: RoutingProfile.templates()[0], apps: apps, serverDomains: ['example.com']));
    // Кириллица, флаги и экранирование переживают разбор и обратную запись.
    configs.add({'remarks': 'Германия 🇩🇪 «тест»', 'escape': 'a"b\\c\n\t\u0001'});
    for (final c in configs) {
      final cleaned = await run(c, clean: true);
      expect(jsonDecode(cleaned), equals(jsonDecode(jsonEncode(c))), reason: jsonEncode(c));
    }
  }, skip: !hasService);

  test('поля с файлами служба вырезает, остальное оставляет', () async {
    final cleaned = jsonDecode(await run({
      'log': {'loglevel': 'debug', 'access': r'C:\a.log', 'error': 'b.log', 'output': 'c.log'},
      'experimental': {
        'cache_file': {'enabled': true, 'path': 'cache.db'},
        'clash_api': {'external_controller': '127.0.0.1:9090', 'external_ui': 'ui', 'external_ui_download_url': 'https://example.com/ui.zip'},
      },
      'route': {
        'rule_set': [
          {'type': 'local', 'tag': 'a', 'path': 'a.srs'},
          {'type': 'remote', 'tag': 'b', 'url': 'https://example.com/b.srs', 'path': 'b.srs'},
        ],
      },
      'outbounds': [
        {'tls': {'enabled': true, 'certificate_path': 'x.pem', 'key_path': 'x.key'}},
        {'streamSettings': {'tlsSettings': {'certificates': [{'certificateFile': 'x.crt', 'keyFile': 'x.key', 'usage': 'verify'}]}}},
      ],
    }, clean: true)) as Map;
    expect(cleaned['log'], {'loglevel': 'debug'});
    expect(cleaned['experimental'], {'clash_api': {'external_controller': '127.0.0.1:9090'}});
    expect(cleaned['route'], {'rule_set': [{'type': 'remote', 'tag': 'b', 'url': 'https://example.com/b.srs'}]});
    expect(cleaned['outbounds'], [
      {'tls': {'enabled': true}},
      {'streamSettings': {'tlsSettings': {'certificates': [{'usage': 'verify'}]}}},
    ]);
  }, skip: !hasService);

  test('пути за пределы папки ядра в остальных полях служба отклоняет', () async {
    for (final bad in [
      {'outbounds': [{'settings': {'file': r'C:\Windows\System32\x'}}]},
      {'x': 'C:/Windows/x'},
      {'x': 'D:x'},
      {'x': r'\\server\share\x'},
      {'x': '/Windows/x'},
      {'x': r'\??\C:\x'},
      {'x': r'..\x'},
      {'x': 'logs/../../x'},
      {'routing': {'rules': [{'domain': [r'ext:C:\x.dat:tag'], 'outboundTag': 'direct'}]}},
      {'routing': {'rules': [{'domain': [r'ext:..\..\x.dat:tag'], 'outboundTag': 'direct'}]}},
      {'outbounds': [{'streamSettings': {'wsSettings': {'path': r'\x'}}}]},
      // У DNS-сервера sing-box вида hosts path — файлы на диске, корень диска сюда нельзя (в любом порядке ключей).
      {'dns': {'servers': [{'type': 'hosts', 'path': ['/Windows/System32/drivers/etc/hosts']}]}},
      {'dns': {'servers': [{'path': ['/x'], 'type': 'hosts'}]}},
      // Экранирование JSON не помогает обойти проверку.
      '{"x":"C:\\u005cx.log"}',
      // Не строгий JSON (комментарий, лишняя запятая) не принимается: ядро и служба поняли бы его по-разному.
      '{"x": 1 /* c */}',
      '{"x": 1,}',
    ]) {
      expect(await run(bad), isNot('ok'), reason: '$bad');
    }
  }, skip: !hasService);

  test('законные строки, похожие на пути, служба пропускает', () async {
    expect(
        await run({
          'dns': {'servers': ['https://1.1.1.1/dns-query', 'tcp+local://8.8.8.8', {'type': 'https', 'path': '/dns-query'}, {'type': 'hosts', 'path': ['hosts.txt']}]},
          'outbounds': [{'streamSettings': {'grpcSettings': {'serviceName': '/svc/name'}}}],
          'routing': {'rules': [{'ip': ['fd00::/8', 'a::1'], 'domain': ['regexp:^api\\.', 'ext:custom.dat:tag']}]},
          'route': {'rules': [{'process_path': [r'C:\Games\game.exe'], 'outbound': 'direct'}]},
        }),
        'ok');
  }, skip: !hasService);
}
