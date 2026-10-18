import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/singbox_config.dart';
import 'package:skipit/core/xray_config.dart';
import 'package:skipit/models/app_rules.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';

/// Служба SkipIt отдаёт ядру конфиг с правами системы, поэтому отклоняет пути к файлам за рабочей
/// папкой ядра (windows\service\service.cpp, ConfigProblem). Конфиги, которые строит сама программа,
/// она пропускать должна, а подложенные пути — нет. Нужна собранная служба (flutter build windows).
void main() {
  final exe = File('${Directory.current.path}\\build\\windows\\x64\\runner\\Release\\skipit-service.exe');
  final hasService = exe.existsSync();

  Future<String> check(Object config) async {
    final f = File('${Directory.systemTemp.path}\\skipit-service-check-${config.hashCode}.json');
    await f.writeAsString(config is String ? config : jsonEncode(config));
    final r = await Process.run(exe.path, ['--check-config', f.path]);
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
    'hysteria2://password@example.com:443?sni=example.com#a',
  ];
  final apps = AppRules(mode: AppRoutingMode.allExcept, entries: [
    AppEntry(match: 'Telegram', label: 'Telegram', action: AppAction.direct),
    AppEntry(match: 'C:/Games/', label: 'Games', action: AppAction.direct),
  ]);

  test('конфиги программы служба пропускает: все виды ссылок, адаптер Xray, sing-box с правилами программ',
      () async {
    for (final link in links) {
      final server = LinkParser.parseText(link).servers.single;
      final c = XrayConfig.build(server: server, routing: RoutingProfile.templates()[0], settings: AppSettings());
      XrayConfig.addTun(c, settings: AppSettings(), apps: apps);
      expect(await check(c), 'ok', reason: link);
    }
    final tun = SingboxConfig.build(
        settings: AppSettings(), routing: RoutingProfile.templates()[0], apps: apps, serverDomains: ['example.com']);
    expect(await check(tun), 'ok');
  }, skip: !hasService);

  test('пути за пределы папки ядра служба отклоняет', () async {
    for (final bad in [
      {'log': {'error': r'C:\Windows\System32\x.log'}},
      {'log': {'access': 'C:/Windows/x.log'}},
      {'log': {'access': 'D:x.log'}},
      {'log': {'error': r'\\server\share\x'}},
      {'log': {'error': '/Windows/x'}},
      {'log': {'error': r'..\x.log'}},
      {'log': {'output': 'logs/../../x'}},
      {'routing': {'rules': [{'domain': [r'ext:C:\x.dat:tag'], 'outboundTag': 'direct'}]}},
      {'experimental': {'cache_file': {'enabled': true, 'path': '/cache.db'}}},
      {'route': {'rule_set': [{'type': 'local', 'path': r'\x.srs'}]}},
      // Экранирование JSON не помогает обойти проверку.
      '{"log":{"error":"C:\\u005cx.log"}}',
    ]) {
      expect(await check(bad), isNot('ok'), reason: '$bad');
    }
  }, skip: !hasService);

  test('законные строки, похожие на пути, служба пропускает', () async {
    expect(
        await check({
          'dns': {'servers': ['https://1.1.1.1/dns-query', 'tcp+local://8.8.8.8']},
          'routing': {'rules': [{'ip': ['fd00::/8', 'a::1'], 'domain': ['regexp:^api\\.', 'ext:custom.dat:tag']}]},
          'route': {'rules': [{'process_path': [r'C:\Games\game.exe'], 'outbound': 'direct'}]},
          'log': {'error': 'core.log'},
        }),
        'ok');
  }, skip: !hasService);
}
