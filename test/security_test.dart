import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/net.dart';
import 'package:skipit/core/singbox_config.dart';
import 'package:skipit/core/updates.dart';
import 'package:skipit/core/util.dart';
import 'package:skipit/core/windows.dart';
import 'package:skipit/main.dart' show sanitizeArgs;
import 'package:skipit/models/subscription.dart';
import 'package:skipit/core/xray_config.dart';
import 'package:skipit/models/app_rules.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/version.dart';

void main() {
  test('ссылки извне не импортируются без подтверждения', () async {
    final state = AppState();
    await state.handleArgs(['skipit://add/https://evil.example/sub', '--autostart']);
    expect(state.pendingLinks, ['skipit://add/https://evil.example/sub']);
    expect(state.subscriptions, isEmpty);
    await state.resolvePendingLink(state.pendingLinks.first, accept: false);
    expect(state.pendingLinks, isEmpty);
    expect(state.subscriptions, isEmpty);
  });

  test('адрес подписки (ключ доступа) не попадает в журнал и в текст ошибки', () {
    // Так сетевая ошибка Dart печатает адрес: целиком, вместе с путём-ключом.
    final e = HttpException('Connection closed before full header was received',
        uri: Uri.parse('https://panel.example/sub/SECRET-TOKEN?x=1'));
    expect('$e', contains('SECRET-TOKEN'));
    expect(scrubUrls('$e'), isNot(contains('SECRET-TOKEN')));
    expect(scrubUrls('$e'), contains('https://panel.example/…'));
    expect(describeNetError(e), isNot(contains('SECRET-TOKEN')));
    // Имя и пароль в адресе тоже убираются; текст без адресов не меняется.
    expect(scrubUrls('GET http://user:pass@host.example:8080/a/b failed'), 'GET http://host.example:8080/… failed');
    expect(scrubUrls('Сервер ответил 404'), 'Сервер ответил 404');
  });

  test('мимо VPN-сервера обновляются только подписки по https', () {
    expect(AppState.directSubscriptionHost('https://panel.example/sub/abc'), 'panel.example');
    // По http ссылка с ключом ушла бы открытым текстом через интернет-провайдера.
    expect(AppState.directSubscriptionHost('http://panel.example/sub/abc'), isNull);
    expect(AppState.directSubscriptionHost('not a url'), isNull);
  });

  test('TUN перехватывает IPv6: при выключенном IPv6 он блокируется, а не идёт мимо VPN', () async {
    final settings = AppSettings()..ipv6 = false;
    final cfg = SingboxConfig.build(
        settings: settings, routing: RoutingProfile.global(), apps: AppRules(), serverDomains: const []);
    final tun = (cfg['inbounds'] as List).single as Map;
    expect((tun['address'] as List).any((a) => '$a'.contains(':')), isTrue);
    final rules = (cfg['route'] as Map)['rules'] as List;
    expect(rules.any((r) => r['ip_version'] == 6 && r['action'] == 'reject'), isTrue);

    settings.ipv6 = true;
    final on = SingboxConfig.build(
        settings: settings, routing: RoutingProfile.global(), apps: AppRules(), serverDomains: const []);
    expect(((on['route'] as Map)['rules'] as List).any((r) => r['ip_version'] == 6), isFalse);

    // Проверка самим ядром sing-box, если оно лежит в проекте.
    final singbox = File('core/skipit-sing-box.exe');
    if (singbox.existsSync()) {
      final f = File('${Directory.systemTemp.path}\\skipit-tun-test.json');
      await f.writeAsString(jsonEncode(cfg));
      final r = await Process.run(singbox.absolute.path, ['check', '-c', f.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      await f.delete();
    }
  });

  test('из конфига провайдера убирается то, чем он мог бы навредить компьютеру', () async {
    final cfg = XrayConfig.buildFromProvider({
      'reverse': {'bridges': [{'tag': 'bridge', 'domain': 'x.example'}]},
      'metrics': {'tag': 'metrics', 'listen': '0.0.0.0:11111'},
      'inbounds': [
        {'tag': 'dns-in', 'protocol': 'dokodemo-door', 'listen': '0.0.0.0', 'port': 10853, 'settings': {'address': '1.1.1.1', 'port': 53, 'network': 'udp'}},
        {'tag': 'evil-tun', 'protocol': 'tun', 'settings': {'name': 'evil'}},
        {'tag': 'skipit-tun', 'protocol': 'dokodemo-door', 'port': 1, 'settings': {'address': '1.1.1.1'}},
      ],
      'outbounds': [
        {
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': {'address': 'a.example', 'port': 443, 'id': '3b5a3c2e-8f6b-4c7e-9d1a-2f4e6a8c0b1d', 'encryption': 'none', 'reverse': {'tag': 'r'}},
          'streamSettings': {'security': 'tls', 'tlsSettings': {'serverName': 'a.example', 'masterKeyLog': r'C:\Windows\keys.log'}},
        },
        {'tag': 'skipit-direct', 'protocol': 'vless', 'settings': {'address': 'b.example', 'port': 443, 'id': '3b5a3c2e-8f6b-4c7e-9d1a-2f4e6a8c0b1d', 'encryption': 'none'}},
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
    }, AppSettings());
    final text = jsonEncode(cfg);
    for (final bad in ['reverse', 'metrics', 'masterKeyLog', 'evil-tun', 'b.example']) {
      expect(text, isNot(contains(bad)), reason: bad);
    }
    // Чужие входы слушают только этот компьютер; тег, занятый программой, из конфига не берётся.
    final inbounds = cfg['inbounds'] as List;
    expect(inbounds.map((i) => i['tag']), ['socks', 'http', 'dns-in']);
    expect(inbounds.last['listen'], '127.0.0.1');

    // Очищенный конфиг принимается ядром.
    final xray = File('core/skipit-xray.exe');
    if (xray.existsSync()) {
      final f = File('${Directory.systemTemp.path}\\skipit-harden-test.json');
      await f.writeAsString(jsonEncode(cfg));
      final r = await Process.run(xray.absolute.path, ['run', '-test', '-c', f.path], stdoutEncoding: utf8, stderrEncoding: utf8);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      await f.delete();
    }
  });

  test('подменённый файл обновления отбрасывается', () async {
    final f = File('${Directory.systemTemp.path}\\skipit-verify-test.bin');
    await f.writeAsString('настоящий установщик');
    final real = await Updates.sha256Of(f.path);

    await Updates.verify(f.path, real.toUpperCase());
    expect(f.existsSync(), isTrue);

    await expectLater(Updates.verify(f.path, '0' * 64), throwsA(isA<Exception>()));
    expect(f.existsSync(), isFalse, reason: 'подменённый файл должен быть удалён');

    await f.writeAsString('настоящий установщик');
    await expectLater(Updates.verify(f.path, null), throwsA(isA<Exception>()));
    expect(f.existsSync(), isFalse, reason: 'без контрольной суммы установщик не остаётся на диске');
  });

  test('скачивание сообщает, сколько уже получено, — окно показывает проценты', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final body = List<int>.generate(300000, (i) => i % 251);
    server.listen((req) async {
      req.response.contentLength = body.length;
      // Отдаём частями, как настоящая сеть.
      for (var i = 0; i < body.length; i += 50000) {
        req.response.add(body.sublist(i, i + 50000));
        await req.response.flush();
      }
      await req.response.close();
    });
    final path = '${Directory.systemTemp.path}\\skipit-download-test.bin';
    final seen = <(int, int)>[];
    await Net.download('http://127.0.0.1:${server.port}/file', path, onProgress: (got, total) => seen.add((got, total)));
    await server.close(force: true);

    expect(File(path).readAsBytesSync(), body);
    expect(seen.last, (body.length, body.length));
    expect(seen.every((p) => p.$2 == body.length), isTrue);
    // Получено растёт без скачков назад.
    expect([for (final p in seen) p.$1], [for (final p in seen) p.$1]..sort());
    expect(File('$path.part').existsSync(), isFalse);
    await File(path).delete();
  });

  test('отказ Windows запустить установщик объясняется словами', () {
    // Так отвечает Windows при включённом Интеллектуальном контроле приложений.
    final blocked = Updates.launchFailure(const ProcessException('setup.exe', [], 'blocked', 4551));
    expect(blocked, contains('не подписан'));
    expect(blocked, contains('Интеллектуальный контроль приложений'));
    expect(Updates.launchFailure(const ProcessException('setup.exe', [], 'virus', 225)), contains('Антивирус'));
    final other = Updates.launchFailure(const ProcessException('setup.exe', [], 'Отказано в доступе.', 5));
    expect(other, contains('Отказано в доступе'));
    expect(other, contains('код 5'));
    expect(Updates.launchFailure(Exception('x')), contains('Windows не дала его запустить'));
  });

  test('адреса обновления строятся из тега релиза, без API GitHub', () {
    final r = Release('v1.0.4', 'getskipit/skipit');
    expect(r.version, '1.0.4');
    expect(r.installerUrl,
        'https://github.com/getskipit/skipit/releases/download/v1.0.4/SkipIt-Setup-Windows-1.0.4.exe');
    expect(r.checksumUrl, '${r.installerUrl}.sha256');
  });

  test('allowInsecure не попадает в конфиг: Xray 26 с ним не запускается', () {
    final s = LinkParser.parseLink(
        'vless://3b5a3c2e-8f6b-4c7e-9d1a-2f4e6a8c0b1d@example.com:443?security=tls&sni=example.com&allowInsecure=1#a')!;
    expect(jsonEncode(s.outbound), isNot(contains('allowInsecure')));
    expect(s.warning, contains('allowInsecure'));

    // Отпечаток и имя сертификата из ссылки (pcs, vcn) переходят в новые параметры ядра.
    final pinned = LinkParser.parseLink(
        'vless://3b5a3c2e-8f6b-4c7e-9d1a-2f4e6a8c0b1d@example.com:443?security=tls&sni=example.com&allowInsecure=1&pcs=${'ab' * 32}&vcn=example.org#a')!;
    final tls = (pinned.outbound['streamSettings'] as Map)['tlsSettings'] as Map;
    expect(tls['pinnedPeerCertSha256'], 'ab' * 32);
    expect(tls['verifyPeerCertByName'], 'example.org');
    expect(pinned.warning, isNull);

    // Серверы, сохранённые старой версией, и конфиги провайдеров: параметр вычищается при сборке конфига.
    final legacy = {
      'outbounds': [
        {'protocol': 'trojan', 'streamSettings': {'security': 'tls', 'tlsSettings': {'allowInsecure': true, 'serverName': 'a.com'}}},
      ],
    };
    final cleaned = jsonEncode(XrayConfig.dropRemovedOptions(legacy));
    expect(cleaned, isNot(contains('allowInsecure')));
    expect(cleaned, contains('a.com'));
  });

  test('просьба применить правила приложений зависит от того, изменилось ли что-то на деле', () {
    final rules = AppRules(mode: AppRoutingMode.allExcept, entries: [
      AppEntry(match: 'C:/Apps/Steam.exe', label: 'steam'),
      AppEntry(match: 'C:/Apps/Game.exe', label: 'game', enabled: false),
    ]);
    final applied = rules.signature;

    // Переключили режим и вернули обратно — применять нечего.
    rules.mode = AppRoutingMode.onlySelected;
    expect(rules.signature, isNot(applied));
    rules.mode = AppRoutingMode.allExcept;
    expect(rules.signature, applied);

    // Выключенная запись и переименование на трафик не влияют.
    rules.entries.removeLast();
    rules.entries.first.label = 'Steam';
    expect(rules.signature, applied);

    // А включение/выключение программы — влияет.
    rules.entries.first.enabled = false;
    expect(rules.signature, isNot(applied));

    // В режиме «Выключено» список не важен.
    rules.mode = AppRoutingMode.off;
    final off = rules.signature;
    rules.entries.first.enabled = true;
    expect(rules.signature, off);
  });

  test('User-Agent по умолчанию несёт версию программы и обновляется вместе с ней', () {
    expect(AppSettings().userAgent, 'SkipIt/$appVersion');
    // Значение, сохранённое старой версией, — не выбор пользователя: заменяется текущим.
    expect(AppSettings.fromJson({'userAgent': 'SkipIt/1.0'}).userAgent, 'SkipIt/$appVersion');
    expect(AppSettings.fromJson({'userAgent': 'SkipIt/1.0.1'}).userAgent, 'SkipIt/$appVersion');
    // А своё значение пользователя сохраняется как есть.
    expect(AppSettings.fromJson({'userAgent': 'Happ/2.0'}).userAgent, 'Happ/2.0');
  });

  test('VLESS без шифрования к серверу в интернете помечается предупреждением', () {
    const id = '3b5a3c2e-8f6b-4c7e-9d1a-2f4e6a8c0b1d';
    expect(LinkParser.parseLink('vless://$id@example.com:80?type=tcp&security=none#a')!.warning, isNotNull);
    expect(LinkParser.parseLink('vless://$id@192.168.1.10:80?type=tcp&security=none#a')!.warning, isNull);
    expect(LinkParser.parseLink('vless://$id@example.com:443?type=tcp&security=tls&sni=example.com#a')!.warning, isNull);
  });

  test('ссылка не может подсунуть программе свои ключи запуска', () {
    // Windows запускает `SkipIt.exe "%1"`; ссылка с кавычкой даёт лишние аргументы.
    expect(sanitizeArgs(['skipit://add/https://a.example/sub', '--quit']), ['skipit://add/https://a.example/sub']);
    expect(sanitizeArgs(['--connect', 'skipit://x', '--elevated', '--autostart']), ['skipit://x']);
    // Обычный запуск с ключами (автозапуск, установщик) не трогается.
    expect(sanitizeArgs(['--autostart']), ['--autostart']);
    expect(sanitizeArgs(['--quit']), ['--quit']);
    expect(sanitizeArgs([]), isEmpty);
  });

  test('из данных провайдера открываются только веб-ссылки', () {
    for (final ok in ['https://t.me/support', 'http://example.com/help', 'tg://resolve?domain=x']) {
      expect(WinSys.isSafeUrl(ok), isTrue, reason: ok);
    }
    for (final bad in [
      r'C:\Windows\System32\calc.exe',
      r'\\evil.example\share\run.exe',
      'file:///C:/Windows/System32/calc.exe',
      'javascript:alert(1)',
      'ms-settings:privacy',
      'https://a.example/" & calc',
      '',
    ]) {
      expect(WinSys.isSafeUrl(bad), isFalse, reason: bad);
    }
    final sub = Subscription(url: 'https://panel.example/sub')
      ..applyMeta({'support-url': r'C:\Windows\System32\calc.exe', 'profile-web-page-url': 'https://panel.example'});
    expect(sub.supportUrl, isNull);
    expect(sub.webPageUrl, 'https://panel.example');
    expect(Subscription.fromJson({'url': 'https://a.example', 'supportUrl': 'file:///C:/x.exe'}).supportUrl, isNull);
  });

  test('парсер не падает на мусоре из ссылки', () {
    for (final s in ['skipit://add/', 'vless://', 'ss://@:0', 'happ://routing/add/%%%', 'vmess://!!!']) {
      expect(() => LinkParser.parseText(s), returnsNormally, reason: s);
    }
  });
}
