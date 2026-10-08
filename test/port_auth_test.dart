import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/net.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/core/singbox_config.dart';
import 'package:skipit/core/xray_config.dart';
import 'package:skipit/models/app_rules.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';

/// Пароль на локальные порты: где он ставится и пускает ли ядро без него.
void main() {
  final server = LinkParser.parseLink(
      'vless://b831381d-6324-4d53-ad4f-8cda48b30811@example.com:443?type=tcp&security=tls&sni=example.com#a')!;
  // Запросы к этому компьютеру идут напрямую — так тест обходится без VPN-сервера.
  final routing = RoutingProfile(name: 'тест', directIp: ['127.0.0.1']);
  AppSettings settings(ConnectionMode mode) => AppSettings()
    ..mode = mode
    ..socksPort = 20971
    ..httpPort = 20972
    ..apiPort = 20973
    ..portAuth = true
    ..portPassword = 'Ab-9+x_Z.q';

  Map inbound(Map<String, dynamic> cfg, String tag) => (cfg['inbounds'] as List).firstWhere((i) => i['tag'] == tag);

  test('пароль стоит на SOCKS всегда, на HTTP — кроме режимов с системным прокси', () {
    const account = [
      {'user': 'skipit', 'pass': 'Ab-9+x_Z.q'},
    ];
    for (final mode in ConnectionMode.values) {
      final cfg = XrayConfig.build(server: server, routing: routing, settings: settings(mode));
      expect(inbound(cfg, 'socks')['settings'], {'auth': 'password', 'accounts': account, 'udp': true});
      final system = mode == ConnectionMode.mixed || mode == ConnectionMode.systemProxy;
      expect(inbound(cfg, 'http')['settings'], system ? isEmpty : {'accounts': account}, reason: mode.name);
    }
    // Выключен — порты как раньше.
    final open = XrayConfig.build(server: server, routing: routing, settings: AppSettings()..portAuth = false);
    expect(inbound(open, 'socks')['settings'], {'auth': 'noauth', 'udp': true});
    expect(inbound(open, 'http')['settings'], isEmpty);
    // По умолчанию включён, пароль у каждой установки свой и переживает сохранение настроек.
    final fresh = AppSettings.fromJson({});
    expect(fresh.portAuth, isTrue);
    // 24 знака: буквы в обоих регистрах, цифры и знаки «-+_.» — и ничего, что ломает адрес прокси.
    expect(fresh.portPassword, matches(RegExp(r'^[A-Za-z0-9+_.\-]{24}$')));
    for (final kind in ['[A-Z]', '[a-z]', '[0-9]', r'[+_.\-]']) {
      expect(fresh.portPassword, contains(RegExp(kind)), reason: kind);
    }
    expect(fresh.portPassword, isNot(AppSettings().portPassword));
    expect(AppSettings.fromJson(fresh.toJson()).portPassword, fresh.portPassword);
  });

  test('sing-box ходит в SOCKS-порт Xray с тем же паролем', () async {
    final tun = SingboxConfig.build(
        settings: settings(ConnectionMode.tun), routing: routing, apps: AppRules(), serverDomains: const []);
    final proxy = (tun['outbounds'] as List).first as Map;
    expect(proxy['username'], 'skipit');
    expect(proxy['password'], 'Ab-9+x_Z.q');
    final singbox = File('core/skipit-sing-box.exe');
    if (!singbox.existsSync()) return;
    final f = File('${Directory.systemTemp.path}\\skipit-port-auth-tun-test.json');
    await f.writeAsString(jsonEncode(tun));
    final r = await Process.run(singbox.absolute.path, ['check', '-c', f.path]);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    await f.delete();
  });

  test('ядро пускает через HTTP-порт только с паролем; сама программа ходит с ним', () async {
    await AppPaths.init();
    if (!File(AppPaths.xrayExe).existsSync()) return;

    final site = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    site.listen((request) => request.response
      ..write('ok')
      ..close());

    final s = settings(ConnectionMode.proxyOnly);
    final core = await Process.start(AppPaths.xrayExe, ['run', '-c', 'stdin:']);
    core.stdin.add(utf8.encode(jsonEncode(XrayConfig.build(server: server, routing: routing, settings: s))));
    await core.stdin.close();
    final out = StringBuffer();
    await core.stdout.transform(utf8.decoder).firstWhere((line) {
      out.write(line);
      return line.contains('started');
    }, orElse: () => fail('ядро не запустилось: $out'));

    final url = 'http://127.0.0.1:${site.port}/file';
    final path = '${Directory.systemTemp.path}\\skipit-port-auth-test.bin';
    try {
      Net.proxyAuth = null;
      await expectLater(Net.download(url, path, proxyPort: s.httpPort), throwsA(isA<HttpException>()));

      Net.proxyAuth = 'skipit:wrong';
      await expectLater(Net.download(url, path, proxyPort: s.httpPort), throwsA(isA<HttpException>()));

      Net.proxyAuth = '${AppSettings.portUser}:${s.portPassword}';
      await Net.download(url, path, proxyPort: s.httpPort);
      expect(await File(path).readAsString(), 'ok');
    } finally {
      Net.proxyAuth = null;
      core.kill();
      await site.close(force: true);
      if (File(path).existsSync()) await File(path).delete();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
