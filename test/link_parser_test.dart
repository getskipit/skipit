import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/icons.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/singbox_config.dart';
import 'package:skipit/core/updates.dart';
import 'package:skipit/core/xray_config.dart';
import 'package:skipit/models/app_rules.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';
import 'package:skipit/ui/flag_text.dart';

void main() {
  test('VLESS Reality', () {
    final r = LinkParser.parseText(
        'vless://b831381d-6324-4d53-ad4f-8cda48b30811@1.2.3.4:443?type=tcp&security=reality&sni=yahoo.com'
        '&fp=chrome&pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw&sid=6ba8&flow=xtls-rprx-vision#%F0%9F%87%B3%F0%9F%87%B1%20NL');
    expect(r.servers, hasLength(1));
    final s = r.servers.first;
    expect(s.name, '🇳🇱 NL');
    expect(s.port, 443);
    final stream = s.outbound['streamSettings'] as Map;
    expect(stream['security'], 'reality');
    expect((stream['realitySettings'] as Map)['publicKey'], 'Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw');
  });

  test('VMess base64', () {
    final json = jsonEncode({
      'v': '2', 'ps': 'vm', 'add': 'a.com', 'port': '8443', 'id': 'b831381d-6324-4d53-ad4f-8cda48b30811',
      'net': 'ws', 'path': '/ws', 'host': 'a.com', 'tls': 'tls',
    });
    final r = LinkParser.parseText('vmess://${base64.encode(utf8.encode(json))}');
    expect(r.servers.single.port, 8443);
    expect((r.servers.single.outbound['streamSettings'] as Map)['network'], 'ws');
  });

  test('Shadowsocks SIP002 и старый формат', () {
    final a = LinkParser.parseText('ss://${base64Url.encode(utf8.encode('aes-256-gcm:pass'))}@h.com:8388#A');
    final b = LinkParser.parseText('ss://${base64.encode(utf8.encode('chacha20-ietf-poly1305:pw@h.com:1234'))}#B');
    expect(a.servers.single.port, 8388);
    expect(b.servers.single.port, 1234);
    final server = ((b.servers.single.outbound['settings'] as Map)['servers'] as List).first as Map;
    expect(server['password'], 'pw');
  });

  test('Hysteria2: Salamander, смена портов, порт по умолчанию, ECH', () {
    Map stream(String link) => LinkParser.parseLink(link)!.outbound['streamSettings'] as Map;
    List masks(String link) => (stream(link)['finalmask'] as Map)['udp'] as List;

    final a = LinkParser.parseLink('hy2://user:pw@h.example:443,20000-30000/?obfs=salamander&obfs-password=ob&ech=AEX&hop-interval=10s#A')!;
    expect(a.port, 443);
    expect(a.warning, isNull);
    expect(((a.outbound['streamSettings'] as Map)['hysteriaSettings'] as Map)['auth'], 'user:pw');
    expect((stream(a.link)['tlsSettings'] as Map)['echConfigList'], 'AEX');
    // Смена портов — последней: ядро требует её первой после разворота списка масок.
    expect(masks(a.link), [
      {'type': 'salamander', 'settings': {'password': 'ob'}},
      {'type': 'udphop', 'settings': {'mode': 'intervalRemote', 'interval': 10, 'remotePorts': '443,20000-30000'}},
    ]);

    // mport: основной порт тоже в списке; интервал меньше 5 с ядро не примет.
    expect((masks('hysteria2://pw@[2001:db8::1]:8443?mport=20000-30000&hopInterval=2')[0] as Map)['settings'],
        {'mode': 'intervalRemote', 'interval': 5, 'remotePorts': '8443,20000-30000'});
    expect(LinkParser.parseLink('hy2://pw@[2001:db8::1]:8443?mport=20000-30000')!.address, '2001:db8::1');

    final noPort = LinkParser.parseLink('hy2://pw@h.example?sni=h.example#B')!;
    expect(noPort.port, 443);
    expect(stream(noPort.link)['finalmask'], isNull);
    expect(LinkParser.parseLink('hy2://pw@h.example:/?sni=h.example')!.port, 443);

    expect(LinkParser.parseLink('hy2://pw@h.example:443?obfs=gecko&obfs-password=x')!.warning, isNotNull);
    expect(LinkParser.parseLink('hy2://pw@h.example:443?mport=abc')!.warning, isNotNull);
    // Порт вне 1–65535 — предупреждение при добавлении, смена портов выключена.
    final big = LinkParser.parseLink('hy2://pw@h.example:443?mport=60000-70000')!;
    expect(big.warning, isNotNull);
    expect(stream(big.link)['finalmask'], isNull);
  });

  test('Trojan, Hysteria2, подписка base64, URL и диплинки', () {
    final body = base64.encode(utf8.encode('trojan://pw@t.com:443?sni=t.com#T\nhy2://auth@h.com:443?sni=h.com#H'));
    final r = LinkParser.parseText(body);
    expect(r.servers.map((e) => e.protocol), ['trojan', 'hysteria']);

    final sub = LinkParser.parseText('happ://add/https://panel.example/sub/abc');
    expect(sub.subscriptionUrls, ['https://panel.example/sub/abc']);

    final crypt = LinkParser.parseText('happ://crypt3/xxxx');
    expect(crypt.errors, isNotEmpty);

    final routing = RoutingProfile(name: 'R', proxySites: ['geosite:youtube']);
    final rd = LinkParser.parseText(routing.toDeeplink().replaceFirst('/add/', '/onadd/'));
    expect(rd.routing.single.activate, isTrue);
    expect(rd.routing.single.profile!.proxySites, ['geosite:youtube']);
  });

  test('Генерация конфигов', () {
    final server = LinkParser.parseText('trojan://pw@t.com:443#T').servers.single;
    final routing = RoutingProfile.templates()[0];
    final settings = AppSettings();
    final x = XrayConfig.build(server: server, routing: routing, settings: settings);
    expect((x['outbounds'] as List).first['tag'], 'proxy');
    final apps = AppRules(mode: AppRoutingMode.allExcept, entries: [
      AppEntry(match: 'Telegram', label: 'Telegram', action: AppAction.direct),
      AppEntry(match: 'C:/Games/', label: 'Games', action: AppAction.direct),
    ]);
    final s = SingboxConfig.build(settings: settings, routing: routing, apps: apps, serverDomains: ['t.com']);
    final rules = (s['route'] as Map)['rules'] as List;
    expect(rules.any((r) => (r as Map)['process_name']?.contains('Telegram.exe') == true), isTrue);
  });

  test('Программа с само-обновлением добавляется папкой, а не путём к версии', () {
    // Discord после обновления лежит уже в другой папке app-…: правило по пути перестало бы совпадать.
    const discord = r'C:\Users\user\AppData\Local\Discord\app-1.0.9260\Discord.exe';
    const helper = r'C:\Users\user\AppData\Local\Discord\app-1.0.9260\modules\discord_utils-1\DiscordSystemHelper.exe';
    expect(AppEntry.matchForExe(discord), 'C:/Users/user/AppData/Local/Discord/');
    expect(AppEntry.matchForExe(helper), 'C:/Users/user/AppData/Local/Discord/');
    // Обычные программы остаются правилом по пути к файлу.
    expect(AppEntry.matchForExe(r'C:\Apps\Steam\steam.exe'), 'C:/Apps/Steam/steam.exe');
    expect(AppEntry.matchForExe(r'D:\app-store\tool.exe'), 'D:/app-store/tool.exe');

    // Программы из Microsoft Store: версия в имени папки, общей неизменной папки нет — правило по имени.
    const spotify = r'C:\Program Files\WindowsApps\SpotifyAB.SpotifyMusic_1.302.258.0_x64__zpdnekdrzrea0\Spotify.exe';
    expect(AppEntry.matchForExe(spotify), 'Spotify');
    expect(
        AppEntry.matchForExe(r'C:\Program Files\WindowsApps\Claude_2.19675.0.0_x64__pzs8sxrjxfjjc\app\claude.exe'), 'claude');
    // Обычная папка с похожим именем правилом по имени не становится.
    expect(AppEntry.matchForExe(r'D:\WindowsApps\tools\tool.exe'), 'D:/WindowsApps/tools/tool.exe');
    // Запись прежней версии с путём переводится на имя, а путь остаётся для значка.
    final store = AppRules.fromJson({
      'mode': 'allExcept',
      'entries': [
        {'match': spotify.replaceAll(r'\', '/'), 'label': 'Spotify'},
      ],
    });
    expect((store.entries.single.match, store.entries.single.exe), ('Spotify', spotify.replaceAll(r'\', '/')));
    expect(store.entries.single.isPath, isFalse);

    // Записи, сохранённые прежними версиями, исправляются при загрузке; повторы сливаются.
    final rules = AppRules.fromJson({
      'mode': 'onlySelected',
      'entries': [
        {'match': 'C:/Users/user/AppData/Local/Discord/app-1.0.9163/Discord.exe', 'label': 'Discord'},
        {'match': 'C:/Users/user/AppData/Local/Discord/app-1.0.9163/modules/x/DiscordSystemHelper.exe', 'label': 'Helper'},
        {'match': 'Telegram', 'label': 'Telegram'},
      ],
    });
    expect(rules.enabledMatches, ['C:/Users/user/AppData/Local/Discord/', 'Telegram']);
    expect(rules.entries.first.label, 'Discord');
    // Прежний путь остаётся файлом для значка и переживает сохранение.
    expect(rules.entries.first.exe, 'C:/Users/user/AppData/Local/Discord/app-1.0.9163/Discord.exe');
    expect(rules.entries.first.iconExe, rules.entries.first.exe);
    expect(AppRules.fromJson(rules.toJson()).entries.first.exe, rules.entries.first.exe);
    expect(rules.entries.last.iconExe, isNull);

    // Папка превращается в правило для sing-box, которое ловит любую версию программы.
    final s = SingboxConfig.build(
        settings: AppSettings(), routing: RoutingProfile.global(), apps: rules, serverDomains: const []);
    final rule = ((s['route'] as Map)['rules'] as List).firstWhere((r) => (r as Map)['process_path_regex'] != null) as Map;
    // sing-box понимает пометку (?i) «без учёта регистра», Dart — нет: здесь она задаётся отдельно.
    final pattern = (rule['process_path_regex'] as List).single as String;
    expect(pattern, startsWith('(?i)'));
    final regex = RegExp(pattern.substring(4), caseSensitive: false);
    expect(regex.hasMatch(r'C:\Users\user\AppData\Local\Discord\app-1.0.9999\Discord.exe'), isTrue);
    expect(regex.hasMatch(r'c:\users\user\appdata\local\discord\Update.exe'), isTrue);
    expect(regex.hasMatch(r'C:\Users\user\AppData\Local\DiscordPTB\app-1.0.1\Discord.exe'), isFalse);
  });

  test('Файл программы для значка находится в свежей папке версии', () async {
    final root = await Directory.systemTemp.createTemp('skipit-icons');
    try {
      for (final v in ['app-1.0.1', 'app-1.0.2']) {
        await File('${root.path}\\$v\\Discord.exe').create(recursive: true);
      }
      await File('${root.path}\\Update.exe').create();
      final folder = '${root.path.replaceAll('\\', '/')}/';
      expect(await IconCache.findExe(folder, 'Discord.exe'), '${folder}app-1.0.2/Discord.exe');
      expect(await IconCache.findExe(folder, 'Update.exe'), '${folder}Update.exe');
      expect(await IconCache.findExe(folder, 'Nope.exe'), isNull);
      expect(await IconCache.findExe('${folder}missing/', 'Discord.exe'), isNull);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('Названия для меню трея: без флагов и эмодзи', () {
    expect(Flags.forTray('Auto → [🚀 Оптимальная локация]'), 'Auto → [Оптимальная локация]');
    expect(Flags.forTray('🇩🇪 Germany'), 'Germany');
    expect(Flags.forTray('Russia - 1 [Сотовая связь]'), 'Russia - 1 [Сотовая связь]');
    expect(Flags.forTray('⚡️ Fast 👨‍👩‍👧 server ✈'), 'Fast server');
    // Стрелка и прочие обычные знаки остаются; название из одних эмодзи не становится пустым.
    expect(Flags.forTray('A → B'), 'A → B');
    expect(Flags.forTray('🚀'), '🚀');
  });

  test('Сравнение версий', () {
    expect(Updates.compare('26.3.27', '26.3.9'), 1);
    expect(Updates.compare('v1.14.2', '1.14.2'), 0);
    expect(Updates.compare('2.0.0', '2.0.0a'), 1);
    expect(Updates.compare('2.0.0b', '2.0.0a'), 1);
    expect(Updates.compare('2.0.1a', '2.0.0'), 1);
    // Порядок версий с буквой (предварительные): таких выпусков у SkipIt пока не было, номера условные.
    const order = ['2.0.0a', '2.0.1a', '2.0.2b', '2.0.3'];
    for (var i = 0; i + 1 < order.length; i++) {
      expect(Updates.compare(order[i + 1], order[i]), 1, reason: '${order[i + 1]} новее ${order[i]}');
      expect(Updates.compare(order[i], order[i + 1]), -1);
    }
    expect(Updates.compare('v2.0.2b', '2.0.2b'), 0);
    expect(Updates.compare('2.0.3', '2.0.3b'), 1);
  });

  test('Сравнение версий с номером сборки (условные номера)', () {
    const order = ['2.0.2', '2.0.3a', '2.0.3a-1', '2.0.3a-2', '2.0.3a-10', '2.0.3b', '2.0.3b-1', '2.0.3'];
    for (var i = 0; i + 1 < order.length; i++) {
      expect(Updates.compare(order[i + 1], order[i]), 1, reason: '${order[i + 1]} новее ${order[i]}');
      expect(Updates.compare(order[i], order[i + 1]), -1);
    }
    expect(Updates.compare('v2.0.3a-2', '2.0.3a-2'), 0);
  });
}