import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/rule_list.dart';
import 'package:skipit/core/xray_config.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';

void main() {
  RuleListEntries entries() => RuleListEntries()
    ..proxyDomains.add('domain:cdn.example')
    ..blockDomains.add('domain:ads.example')
    ..directIps.add('203.0.113.0/24');

  List<Map> rules(Map<String, dynamic> cfg) => [
        for (final r in (cfg['routing'] as Map)['rules'] as List) r as Map,
      ];

  test('build(): записи списков встают в правила с нужным выходом', () {
    final server = LinkParser.parseText('trojan://pw@vpn.example:443#S').servers.single;
    final cfg = XrayConfig.build(
      server: server,
      routing: RoutingProfile(name: 'Тест'),
      settings: AppSettings(),
      ruleLists: entries(),
    );
    final rs = rules(cfg);
    expect(
      rs.firstWhere((r) => (r['domain'] as List?)?.contains('domain:ads.example') == true)['outboundTag'],
      'block',
    );
    expect(
      rs.firstWhere((r) => (r['domain'] as List?)?.contains('domain:cdn.example') == true)['outboundTag'],
      'proxy',
    );
    expect(
      rs.firstWhere((r) => (r['ip'] as List?)?.contains('203.0.113.0/24') == true)['outboundTag'],
      'direct',
    );
  });

  test('build(): без ruleLists конфиг как раньше', () {
    final server = LinkParser.parseText('trojan://pw@vpn.example:443#S').servers.single;
    final cfg = XrayConfig.build(server: server, routing: RoutingProfile(name: 'Тест'), settings: AppSettings());
    expect(
      rules(cfg).any((r) => (r['domain'] as List?)?.contains('domain:cdn.example') ?? false),
      isFalse,
    );
  });

  test('addOwnRules: записи встают перед «всё остальное» провайдера', () {
    final cfg = XrayConfig.buildFromProvider({
      'outbounds': [
        {
          'tag': 'proxy',
          'protocol': 'trojan',
          'settings': {'servers': [{'address': 'a.example', 'port': 443, 'password': 'p'}]},
          'streamSettings': {'network': 'tcp', 'security': 'tls'},
        },
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
      'routing': {
        'rules': [
          {'type': 'field', 'network': 'tcp,udp', 'outboundTag': 'proxy'},
        ],
      },
    }, AppSettings());
    XrayConfig.addOwnRules(cfg, RoutingProfile(name: 'Тест'), AppSettings(), ruleLists: entries());
    final rs = rules(cfg);
    final catchAll = rs.indexWhere((r) =>
        r.keys.every(const {'type', 'network', 'outboundTag', 'balancerTag', 'ruleTag'}.contains) &&
        const {null, 'tcp,udp', 'udp,tcp'}.contains(r['network']));
    final cdn = rs.indexWhere((r) => (r['domain'] as List?)?.contains('domain:cdn.example') ?? false);
    expect(cdn, greaterThanOrEqualTo(0));
    expect(cdn, lessThan(catchAll));
  });

  test('build(): у JSON-провайдера записи списков тоже встают в правила', () {
    final server = LinkParser.parseText(_provider).servers.single;
    expect(server.isJson, isTrue);
    final cfg = XrayConfig.build(
      server: server,
      routing: RoutingProfile(name: 'Тест'),
      settings: AppSettings(),
      ruleLists: entries(),
    );
    final rs = rules(cfg);
    expect(rs.any((r) => (r['domain'] as List?)?.contains('domain:cdn.example') ?? false), isTrue);
    expect(rs.any((r) => (r['domain'] as List?)?.contains('domain:ads.example') ?? false), isTrue);
    expect(rs.any((r) => (r['ip'] as List?)?.contains('203.0.113.0/24') ?? false), isTrue);
    // Перед правилом «всё остальное» провайдера.
    final catchAll = rs.indexWhere((r) =>
        r.keys.every(const {'type', 'network', 'outboundTag', 'balancerTag', 'ruleTag'}.contains) &&
        const {null, 'tcp,udp', 'udp,tcp'}.contains(r['network']));
    final cdn = rs.indexWhere((r) => (r['domain'] as List?)?.contains('domain:cdn.example') ?? false);
    expect(catchAll, greaterThanOrEqualTo(0));
    expect(cdn, lessThan(catchAll));
  });

  test('hasOwnRules: профиль только со списками по ссылке — свои правила есть', () {
    final p = RoutingProfile(name: 'Тест', ruleLists: [RuleListSource(url: 'https://rules.example/a.txt')]);
    expect(XrayConfig.hasOwnRules(p), isTrue);
    expect(XrayConfig.hasOwnRules(RoutingProfile(name: 'Пустой')), isFalse);
  });
}

/// Маленький JSON-конфиг провайдера: прокси, direct и правило «всё остальное».
const _provider = '''
[{
  "remarks": "Провайдер",
  "outbounds": [
    {"tag": "proxy", "protocol": "trojan", "settings": {"servers": [{"address": "a.example", "port": 443,
      "password": "p"}]}, "streamSettings": {"network": "tcp", "security": "tls"}},
    {"tag": "direct", "protocol": "freedom"}
  ],
  "routing": {"rules": [{"type": "field", "network": "tcp,udp", "outboundTag": "proxy"}]}
}]
''';
