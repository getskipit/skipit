import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/singbox_config.dart';
import 'package:skipit/core/xray_config.dart';
import 'package:skipit/models/app_rules.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';

/// DNS по программам: запросы DNS из адаптера уходят посреднику службы SkipIt (windows\service\dns_split.cpp),
/// а он по журналу DNS-клиента Windows решает, спросить DNS ядра или местный DNS мимо VPN.
void main() {
  const uuid = '3b5a3c2e-8f6b-4c7e-9d1a-2f4e6a8c0b1d';
  const pbk = 'SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc';
  final server = LinkParser.parseText('vless://$uuid@example.com:443?type=tcp&security=reality&pbk=$pbk'
          '&sid=6ba85179e30d4fc2&sni=www.example.com&fp=chrome#a')
      .servers
      .single;
  final apps = AppRules(mode: AppRoutingMode.allExcept, entries: [
    AppEntry(match: 'game.exe', label: 'Game', action: AppAction.direct),
  ]);

  Future<void> coreAccepts(String exe, List<String> args, Map<String, dynamic> config, String name) async {
    final core = File(exe);
    if (!core.existsSync()) return;
    final f = File('${Directory.systemTemp.path}\\$name.json');
    await f.writeAsString(jsonEncode(config));
    final r = await Process.run(core.absolute.path, [...args, f.path]);
    await f.delete();
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
  }

  test('Xray: запросы DNS из адаптера идут посреднику службы, вход местного DNS — напрямую', () async {
    final s = AppSettings();
    final c = XrayConfig.build(server: server, routing: RoutingProfile(name: 'Тест'), settings: s);
    XrayConfig.addTun(c, settings: s, apps: apps, dnsSplitPort: 11113);
    XrayConfig.addDnsInbound(c, port: 11114, settings: s);
    XrayConfig.addLocalDnsInbound(c, port: 11115, server: ('77.88.8.8', 53), settings: s);

    final rules = (c['routing'] as Map)['rules'] as List;
    final dnsRule = rules.firstWhere((r) => r['port'] == '53' && (r['inboundTag'] as List).contains('skipit-tun'));
    expect(dnsRule['outboundTag'], 'skipit-dns-split');
    final outbounds = c['outbounds'] as List;
    expect(outbounds.singleWhere((o) => o['tag'] == 'skipit-dns-split'), {
      'tag': 'skipit-dns-split',
      'protocol': 'freedom',
      'settings': {'redirect': '127.0.0.1:11113'},
    });
    // Выход DNS ядра один, хотя его просят и адаптер, и вход для посредника.
    expect(outbounds.where((o) => o['tag'] == 'skipit-dns').length, 1);
    // Вход местного DNS: только этот компьютер, только этот сервер, правилом раньше правил провайдера.
    final local = (c['inbounds'] as List).singleWhere((i) => i['tag'] == 'skipit-local-dns');
    expect(local['listen'], '127.0.0.1');
    expect(local['settings'], {'address': '77.88.8.8', 'port': 53, 'network': 'tcp,udp'});
    expect(rules.first, {'inboundTag': ['skipit-local-dns'], 'outboundTag': 'skipit-direct'});
    // Сниффинг по-прежнему только для выбора правила (голос в играх с именами без записи в DNS).
    final tun = (c['inbounds'] as List).singleWhere((i) => i['tag'] == 'skipit-tun');
    expect((tun['sniffing'] as Map)['routeOnly'], isTrue);
    await coreAccepts('core/skipit-xray.exe', ['run', '-test', '-c'], c, 'skipit-dns-split-test');
  });

  test('Xray: без посредника запросы DNS из адаптера, как раньше, забирает DNS ядра', () {
    final s = AppSettings();
    final c = XrayConfig.build(server: server, routing: RoutingProfile(name: 'Тест'), settings: s);
    XrayConfig.addTun(c, settings: s, apps: apps);
    final rules = (c['routing'] as Map)['rules'] as List;
    expect(rules.firstWhere((r) => r['port'] == '53')['outboundTag'], 'skipit-dns');
    expect((c['outbounds'] as List).where((o) => o['tag'] == 'skipit-dns-split'), isEmpty);
  });

  test('sing-box: DNS программ спрашивается у посредника службы', () async {
    final s = AppSettings();
    final tun = SingboxConfig.build(
        settings: s,
        routing: RoutingProfile.templates()[0],
        apps: apps,
        serverDomains: const [],
        xrayDnsPort: 11114,
        dnsSplitPort: 11113);
    expect(((tun['dns'] as Map)['servers'] as List).first,
        {'type': 'udp', 'tag': 'remote', 'server': '127.0.0.1', 'server_port': 11113});
    await coreAccepts('core/skipit-sing-box.exe', ['check', '-c'], tun, 'skipit-dns-split-tun-test');
  });

  test('местный DNS: первый сервер с IPv4-адресом, иначе запасной 1.1.1.1', () {
    final s = AppSettings();
    expect(XrayConfig.localDnsServer(RoutingProfile.templates()[0], s), ('77.88.8.8', 53));
    final doh = RoutingProfile(name: 'DoH', domesticDnsType: 'DoH', domesticDnsDomain: 'https://dns.example/dns-query');
    expect(XrayConfig.localDnsServer(doh, s), ('1.1.1.1', 53));
    final own = AppSettings()
      ..ownDns = true
      ..ownDnsDomestic = 'https://dns.example/dns-query, udp://203.0.113.5:5353';
    expect(XrayConfig.localDnsServer(doh, own), ('203.0.113.5', 5353));
  });

  // Нужна собранная служба (flutter build windows): разбор команды без прав администратора.
  final exe = File('${Directory.current.path}\\build\\windows\\x64\\runner\\Release\\skipit-service.exe');
  test('служба отклоняет неверную команду посредника', () async {
    for (final args in [
      ['x', '11113', '11114', '11115', 'game.exe'],
      ['a', '53', '11114', '11115', 'game.exe'],
      ['a', '11113', '11114', '11115'],
      ['a', '11113', '1x', '11115', 'game.exe'],
    ]) {
      final r = await Process.run(exe.path, ['--dns-test', ...args]);
      expect(r.exitCode, 2, reason: args.join(' '));
    }
  }, skip: !exe.existsSync());
}
