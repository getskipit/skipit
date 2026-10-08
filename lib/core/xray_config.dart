import 'dart:convert';
import 'dart:io';

import '../models/app_rules.dart';
import '../models/routing.dart';
import '../models/server.dart';
import '../models/settings.dart';
import 'paths.dart';
import 'util.dart';

class XrayConfig {
  static const _prefixes = ['geosite:', 'domain:', 'full:', 'regexp:', 'keyword:', 'ext:', 'dotless:'];

  /// Happ пишет домены без префикса — в Xray это была бы подстрока, поэтому добавляем `domain:`.
  static List<String> normalizeDomains(List<String> list) => [
        for (final raw in list)
          if (raw.trim().isNotEmpty)
            _prefixes.any((p) => raw.trim().toLowerCase().startsWith(p)) ? raw.trim() : 'domain:${raw.trim()}',
      ];

  static List<String> normalizeIps(List<String> list) =>
      [for (final raw in list) if (raw.trim().isNotEmpty) raw.trim()];

  static bool needsGeoFiles(RoutingProfile r) => [
        ...r.directSites, ...r.directIp, ...r.proxySites, ...r.proxyIp, ...r.blockSites, ...r.blockIp,
      ].any((e) => e.startsWith('geosite:') || e.startsWith('geoip:') || e.startsWith('ext:'));

  /// Полный JSON-конфиг сервера от провайдера (правила, балансировщики, DNS) или null для обычных ссылок.
  static Map<String, dynamic>? providerConfig(ServerProfile server) {
    if (!server.isJson) return null;
    try {
      final data = jsonDecode(server.link);
      final cfg = data is List ? data.first : data;
      return cfg is Map<String, dynamic> && cfg['outbounds'] is List ? cfg : null;
    } catch (_) {
      return null;
    }
  }

  static bool configNeedsGeoFiles(Map<String, dynamic> cfg) {
    final text = jsonEncode(cfg['routing'] ?? const {});
    return text.contains('geosite:') || text.contains('geoip:') || text.contains('ext:');
  }

  /// Убирает параметры, с которыми свежий Xray отказывается запускаться. Сейчас это `allowInsecure`:
  /// в Xray 26 он удалён (вместо него pinnedPeerCertSha256 / verifyPeerCertByName), а конфиги
  /// провайдеров и старые сохранённые серверы всё ещё могут его содержать.
  static T dropRemovedOptions<T>(T node) {
    if (node is Map) {
      final tls = node['tlsSettings'];
      if (tls is Map) tls.remove('allowInsecure');
      node.values.forEach(dropRemovedOptions);
    } else if (node is List) {
      node.forEach(dropRemovedOptions);
    }
    return node;
  }

  /// Переносит устаревшие параметры конфига провайдера на новое место, чтобы ядро не ругалось в журнале.
  /// Сейчас это `domainStrategy` у выхода freedom: в Xray 26 он переехал из settings в sockopt.
  static void _migrateDeprecated(Map<String, dynamic> cfg) {
    for (final o in (cfg['outbounds'] as List? ?? const [])) {
      if (o is! Map || o['protocol'] != 'freedom') continue;
      final settings = o['settings'];
      if (settings is! Map || !settings.containsKey('domainStrategy')) continue;
      final strategy = settings.remove('domainStrategy');
      final stream = (o['streamSettings'] ??= <String, dynamic>{}) as Map;
      final sockopt = (stream['sockopt'] ??= <String, dynamic>{}) as Map;
      sockopt['domainStrategy'] ??= strategy;
    }
  }

  /// Теги, которые программа ставит сама: вход `api` и всё с приставкой `skipit-`.
  static bool _reservedTag(Object? tag) => tag is String && (tag == 'api' || tag.startsWith('skipit-'));

  /// Убирает из конфига провайдера то, чем чужой конфиг мог бы навредить компьютеру. Подключению это
  /// не нужно, а SkipIt обычно работает с правами администратора:
  ///  - `reverse` — обратный прокси: даёт серверу доступ в домашнюю сеть пользователя;
  ///  - `metrics` — отладочный порт ядра, который можно открыть в сеть;
  ///  - `masterKeyLog` — запись ключей шифрования в произвольный файл на диске.
  static void _dropDangerous(Map<String, dynamic> cfg) {
    cfg
      ..remove('reverse')
      ..remove('metrics');
    for (final o in (cfg['outbounds'] as List? ?? const [])) {
      final settings = o is Map ? o['settings'] : null;
      if (settings is Map) settings.remove('reverse');
    }
    void strip(Object? node) {
      if (node is Map) {
        node.remove('masterKeyLog');
        node.values.forEach(strip);
      } else if (node is List) {
        node.forEach(strip);
      }
    }

    strip(cfg);
  }

  /// Конфиг провайдера используется целиком; подменяются только локальные входы (наши порты),
  /// журнал и статистика — чтобы работали счётчики трафика и настройки портов.
  static Map<String, dynamic> buildFromProvider(Map<String, dynamic> provider, AppSettings settings) {
    final cfg = deepCopyMap(provider);
    final listen = settings.allowLan ? '0.0.0.0' : '127.0.0.1';
    final sniffing = {
      'enabled': settings.sniffing,
      'destOverride': ['http', 'tls', 'quic'],
      'routeOnly': false,
    };

    // Входы SOCKS/HTTP провайдера заменяем своими (теги те же — правила провайдера на них ссылаются),
    // прочие входы (например, DNS) оставляем.
    // Они слушают только этот компьютер: конфиг пришёл извне и не должен открывать порты в сеть.
    // Вход TUN и теги, занятые программой, из конфига провайдера не берутся.
    final keep = [
      for (final i in (cfg['inbounds'] as List? ?? const []))
        if (i is Map &&
            !const ['socks', 'http', 'mixed', 'tun'].contains(i['protocol']) &&
            !_reservedTag(i['tag']))
          i..['listen'] = '127.0.0.1',
    ];
    cfg['outbounds'] = [
      for (final o in (cfg['outbounds'] as List))
        if (!(o is Map && _reservedTag(o['tag']))) o,
    ];
    cfg['inbounds'] = [
      {
        'tag': 'socks',
        'protocol': 'socks',
        'listen': listen,
        'port': settings.socksPort,
        'settings': _socksSettings(settings),
        'sniffing': sniffing,
      },
      {
        'tag': 'http',
        'protocol': 'http',
        'listen': listen,
        'port': settings.httpPort,
        'settings': _httpSettings(settings),
        'sniffing': sniffing,
      },
      ...keep,
    ];
    // Журнал доступа включён всегда: из него строится список соединений в разделе «Логи».
    cfg['log'] = {'loglevel': settings.logLevel};
    cfg['api'] = {
      'tag': 'api',
      'listen': '127.0.0.1:${settings.apiPort}',
      'services': ['StatsService'],
    };
    cfg['stats'] = <String, dynamic>{};
    final policy = (cfg['policy'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final system = (policy['system'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    system['statsOutboundUplink'] = true;
    system['statsOutboundDownlink'] = true;
    policy['system'] = system;
    cfg['policy'] = policy;
    // Метаданные клиента Xray не нужны.
    cfg.remove('remarks');
    _dropDangerous(cfg);
    _migrateDeprecated(cfg);
    return dropRemovedOptions(cfg);
  }

  /// Краткое содержание правил провайдера для экрана «Маршрутизация».
  static ({int direct, int proxy, int block, List<String> directExamples, List<String> blockNotes}) summarize(
      Map<String, dynamic> cfg) {
    var direct = 0, proxy = 0, block = 0;
    final examples = <String>[];
    final notes = <String>{};
    for (final r in ((cfg['routing'] as Map?)?['rules'] as List? ?? const [])) {
      if (r is! Map || r['inboundTag'] != null) continue;
      final domains = (r['domain'] as List?)?.cast<Object>() ?? const [];
      final ips = (r['ip'] as List?)?.cast<Object>() ?? const [];
      final count = domains.length + ips.length;
      final target = r['outboundTag'] ?? r['balancerTag'];
      if (target == 'direct') {
        direct += count;
        for (final d in domains) {
          if (examples.length < 4) examples.add('$d'.replaceFirst(RegExp(r'^(domain|full):'), '.'));
        }
      } else if (target == 'block') {
        block += count;
        if (r['protocol'] != null) notes.add('торренты');
        if (ips.contains('::/0')) notes.add('IPv6');
        if (r['network'] == 'udp' && '${r['port']}' == '443') notes.add('QUIC');
      } else if (target != null && r['network'] == null && r['port'] == null) {
        proxy += count;
      }
    }
    return (direct: direct, proxy: proxy, block: block, directExamples: examples, blockNotes: notes.toList());
  }

  static Map<String, dynamic> build({
    required ServerProfile server,
    required RoutingProfile routing,
    required AppSettings settings,
  }) {
    final provider = providerConfig(server);
    if (provider != null) {
      final cfg = buildFromProvider(provider, settings);
      addOwnRules(cfg, routing, settings);
      if (settings.ownDns) useOwnDns(cfg, routing, settings);
      return cfg;
    }

    final listen = settings.allowLan ? '0.0.0.0' : '127.0.0.1';
    final sniffing = {
      'enabled': settings.sniffing,
      'destOverride': ['http', 'tls', 'quic'],
      'routeOnly': false,
    };

    final proxy = dropRemovedOptions(deepCopyMap(server.outbound))..['tag'] = 'proxy';

    final directDomains = normalizeDomains(routing.directSites);
    final remoteDns = _dnsServers(routing.remoteDnsList, fallback: '1.1.1.1');
    final domesticDns = _dnsServers(routing.domesticDnsList, direct: true, fallback: '77.88.8.8');
    final rules = <Map<String, dynamic>>[
      // DNS-сервер для российских доменов ходит напрямую.
      ..._directDnsRules(domesticDns, 'direct'),
    ];

    void add(List<String> domains, List<String> ips, String tag) {
      final d = normalizeDomains(domains);
      final i = normalizeIps(ips);
      if (d.isNotEmpty) rules.add({'domain': d, 'outboundTag': tag});
      if (i.isNotEmpty) rules.add({'ip': i, 'outboundTag': tag});
    }

    add(routing.blockSites, routing.blockIp, 'block');
    add(routing.proxySites, routing.proxyIp, 'proxy');
    add(routing.directSites, routing.directIp, 'direct');
    rules.add({'network': 'tcp,udp', 'outboundTag': routing.globalProxy ? 'proxy' : 'direct'});

    return {
      'log': {'loglevel': settings.logLevel},
      'api': {
        'tag': 'api',
        'listen': '127.0.0.1:${settings.apiPort}',
        'services': ['StatsService'],
      },
      'stats': <String, dynamic>{},
      'policy': {
        'system': {'statsOutboundUplink': true, 'statsOutboundDownlink': true},
      },
      'dns': {
        if (routing.dnsHosts.isNotEmpty) 'hosts': routing.dnsHosts,
        'servers': [
          ...remoteDns,
          if (directDomains.isNotEmpty)
            for (final s in domesticDns) {..._dnsEntry(s), 'domains': directDomains, 'skipFallback': true},
        ],
        'queryStrategy': settings.ipv6 ? 'UseIP' : 'UseIPv4',
      },
      'inbounds': [
        {
          'tag': 'socks',
          'protocol': 'socks',
          'listen': listen,
          'port': settings.socksPort,
          'settings': _socksSettings(settings),
          'sniffing': sniffing,
        },
        {
          'tag': 'http',
          'protocol': 'http',
          'listen': listen,
          'port': settings.httpPort,
          'settings': _httpSettings(settings),
          'sniffing': sniffing,
        },
      ],
      'outbounds': [
        proxy,
        {
          'tag': 'direct',
          'protocol': 'freedom',
          // В Xray 26 стратегия адресов переехала из settings в sockopt (старое место объявлено устаревшим).
          'streamSettings': {
            'sockopt': {'domainStrategy': settings.ipv6 ? 'UseIP' : 'UseIPv4'},
          },
        },
        {'tag': 'block', 'protocol': 'blackhole'},
      ],
      'routing': {'domainStrategy': routing.domainStrategy, 'rules': rules},
    };
  }

  /// Адрес DNS из поля ввода → запись для Xray (строка или, если указан порт, объект). `1.1.1.1` и
  /// `udp://…` — обычный DNS, `tcp://…` и `https://…` (DoH) ядро понимает как есть. DNS поверх TLS
  /// (`tls://`, DoT) ядро Xray не умеет — null. [direct]: ядро идёт к серверу само, мимо правил.
  static Object? dnsServer(String address, {bool direct = false}) {
    var a = address.trim();
    if (a.isEmpty || a.startsWith('tls://')) return null;
    if (a.startsWith('https://') || a.startsWith('tcp://')) return direct ? a.replaceFirst('://', '+local://') : a;
    if (a.startsWith('udp://')) a = a.substring(6);
    if (InternetAddress.tryParse(a) != null) return a;
    final uri = Uri.tryParse('udp://$a');
    if (uri == null || uri.host.isEmpty) return null;
    return uri.hasPort ? {'address': uri.host, 'port': uri.port} : uri.host;
  }

  static List<Object> _dnsServers(List<String> addresses, {bool direct = false, required String fallback}) {
    final servers = [
      for (final a in addresses)
        if (dnsServer(a, direct: direct) case final s?) s,
    ];
    return servers.isEmpty ? [fallback] : servers;
  }

  static Map<String, dynamic> _dnsEntry(Object server) =>
      server is Map ? server.cast<String, dynamic>() : {'address': server};

  /// Обычный DNS по IP-адресу идёт через правила — для локальных серверов нужно правило «напрямую».
  static List<Map<String, dynamic>> _directDnsRules(List<Object> servers, String tag) => [
        for (final s in servers.map(_dnsEntry))
          if (InternetAddress.tryParse('${s['address']}') != null)
            {'ip': [s['address']], 'port': '${s['port'] ?? 53}', 'outboundTag': tag},
      ];

  /// Настройки локальных входов SOCKS и HTTP: с логином и паролем, если пароль на порты включён.
  static Map<String, dynamic> _socksSettings(AppSettings s) => {
        'auth': s.portAuth ? 'password' : 'noauth',
        if (s.portAuth) 'accounts': [_account(s)],
        'udp': true,
      };

  static Map<String, dynamic> _httpSettings(AppSettings s) => {
        if (s.httpAuth) 'accounts': [_account(s)],
      };

  static Map<String, dynamic> _account(AppSettings s) => {'user': s.portUser, 'pass': s.portPassword};

  static const _direct = 'skipit-direct', _block = 'skipit-block';

  /// Свои выходы «напрямую» и «блокировать»: добавляются, если их в конфиге ещё нет.
  static void _addOwnOutbounds(Map<String, dynamic> cfg, AppSettings settings) {
    final outbounds = [...(cfg['outbounds'] as List)];
    bool has(String tag) => outbounds.any((o) => o is Map && o['tag'] == tag);
    if (!has(_direct)) {
      outbounds.add({
        'tag': _direct,
        'protocol': 'freedom',
        'streamSettings': {
          'sockopt': {'domainStrategy': settings.ipv6 ? 'UseIP' : 'UseIPv4'},
        },
      });
    }
    if (!has(_block)) outbounds.add({'tag': _block, 'protocol': 'blackhole'});
    cfg['outbounds'] = outbounds;
  }

  /// Куда идёт трафик «через VPN»: у провайдера с автовыбором сервера — в его балансировщик,
  /// иначе — в первый выход, который ведёт на VPN-сервер. null — такого выхода в конфиге нет.
  static Map<String, String>? _vpnTarget(Map<String, dynamic> cfg) {
    final rules = (cfg['routing'] as Map?)?['rules'] as List? ?? const [];
    final balancer = rules.reversed
        .whereType<Map>()
        .where((r) => r['inboundTag'] == null && r['balancerTag'] is String)
        .map((r) => r['balancerTag'] as String)
        .firstOrNull;
    if (balancer != null) return {'balancerTag': balancer};
    final proxy = (cfg['outbounds'] as List)
        .whereType<Map>()
        .where((o) => !const ['freedom', 'blackhole', 'dns', 'loopback'].contains(o['protocol']))
        .firstOrNull;
    return proxy == null ? null : {'outboundTag': (proxy['tag'] ??= 'proxy') as String};
  }

  /// Есть ли у профиля свои правила для сайтов и IP. Встроенный «Весь трафик через VPN» — это «правил нет».
  static bool hasOwnRules(RoutingProfile r) => r.id != RoutingProfile.globalPresetId && r.ruleCount > 0;

  /// Свой профиль вместе с правилами провайдера: его списки «блокировать», «через VPN» и «напрямую»
  /// стоят после всех правил провайдера, перед его правилом «всё остальное». Они решают только за то,
  /// о чём провайдер ничего не сказал, и потому не могут ему противоречить: при споре действует правило
  /// провайдера. Когда узнавать адрес сайта (domainStrategy), тоже определяет конфиг провайдера.
  /// «Через VPN» — это балансировщик провайдера, если он есть: автовыбор сервера сохраняется.
  static void addOwnRules(Map<String, dynamic> cfg, RoutingProfile profile, AppSettings settings) {
    if (!hasOwnRules(profile)) return;
    final vpn = _vpnTarget(cfg);
    final own = <Map<String, dynamic>>[];
    void add(List<String> domains, List<String> ips, Map<String, String>? target) {
      if (target == null) return;
      final d = normalizeDomains(domains);
      final i = normalizeIps(ips);
      if (d.isNotEmpty) own.add({'domain': d, ...target});
      if (i.isNotEmpty) own.add({'ip': i, ...target});
    }

    add(profile.blockSites, profile.blockIp, const {'outboundTag': _block});
    add(profile.proxySites, profile.proxyIp, vpn);
    add(profile.directSites, profile.directIp, const {'outboundTag': _direct});
    if (own.isEmpty) return;
    _addOwnOutbounds(cfg, settings);
    final routing = (cfg['routing'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final rules = [...(routing['rules'] as List? ?? const [])];
    // Правило «всё остальное»: без условий, кроме сети. Нет такого — свои правила идут последними.
    final rest = rules.indexWhere((r) =>
        r is Map &&
        r.keys.every(const {'type', 'network', 'outboundTag', 'balancerTag', 'ruleTag'}.contains) &&
        const {null, 'tcp,udp', 'udp,tcp'}.contains(r['network']));
    rules.insertAll(rest < 0 ? rules.length : rest, own);
    routing['rules'] = rules;
    cfg['routing'] = routing;
  }

  /// Тег встроенного DNS, если провайдер не дал своего: по нему запросы DNS узнаются в правилах.
  static const _dnsTag = 'skipit-dns-in';

  /// Свой DNS вместо DNS провайдера (выключатель «Мой DNS»). Записи провайдера «для таких-то сайтов»
  /// (с полем domains) остаются, но спрашивают локальный DNS профиля; все остальные заменяет одна —
  /// удалённый DNS профиля. Локальный идёт напрямую, удалённый — через VPN-сервер.
  static void useOwnDns(Map<String, dynamic> cfg, RoutingProfile profile, AppSettings settings) {
    final dns = (cfg['dns'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final domestic = _dnsServers(profile.domesticDnsList, direct: true, fallback: '77.88.8.8');
    final directDomains = hasOwnRules(profile) ? normalizeDomains(profile.directSites) : const <String>[];
    dns['servers'] = [
      ..._dnsServers(profile.remoteDnsList, fallback: '1.1.1.1'),
      for (final s in (dns['servers'] as List? ?? const []))
        if (s is Map && (s['domains'] as List? ?? const []).isNotEmpty)
          for (final d in domestic) {...({...s}..remove('port')), ..._dnsEntry(d)},
      if (directDomains.isNotEmpty)
        for (final d in domestic) {..._dnsEntry(d), 'domains': directDomains, 'skipFallback': true},
    ];
    if (profile.dnsHosts.isNotEmpty) dns['hosts'] = {...?(dns['hosts'] as Map?), ...profile.dnsHosts};
    final tag = (dns['tag'] ??= _dnsTag) as String;
    cfg['dns'] = dns;

    final vpn = _vpnTarget(cfg);
    _addOwnOutbounds(cfg, settings);
    final routing = (cfg['routing'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    routing['rules'] = [
      ..._directDnsRules(domestic, _direct),
      if (vpn != null) {'inboundTag': [tag], ...vpn},
      ...(routing['rules'] as List? ?? const []),
    ];
    cfg['routing'] = routing;
  }

  /// Выходы, через которые ходят другие выходы (цепочка `dialerProxy` / `proxySettings` в конфиге
  /// провайдера). В счётчике трафика они не учитываются: тот же трафик уже посчитан на основном выходе.
  static Set<String> chainedOutbounds(Map<String, dynamic> cfg) {
    final tags = <String>{};
    for (final o in (cfg['outbounds'] as List? ?? const [])) {
      if (o is! Map) continue;
      final dialer = ((o['streamSettings'] as Map?)?['sockopt'] as Map?)?['dialerProxy'];
      final chain = (o['proxySettings'] as Map?)?['tag'];
      if (dialer is String && dialer.isNotEmpty) tags.add(dialer);
      if (chain is String && chain.isNotEmpty) tags.add(chain);
    }
    return tags;
  }

  static const tunTag = 'skipit-tun';

  /// Адреса TUN-адаптера (одни и те же с обоими ядрами). По ним же Kill Switch узнаёт соединения,
  /// идущие через адаптер.
  static const tunV4 = '172.19.0.1', tunV6 = 'fdfe:dcba:9876::1';
  static const _tunGateway = ['$tunV4/30', '$tunV6/126'];

  /// DNS адаптера — сосед шлюза в подсети TUN: запросы к нему попадают в адаптер, там их
  /// перехватывает правило, и отвечает встроенный DNS Xray.
  static const _tunDns = '172.19.0.2';

  /// DNS, у которых ядро напрямую узнаёт адреса VPN-серверов (спросить их через VPN до подключения
  /// невозможно) и DNS-серверов «+local», когда в конфиге нет запасного. По умолчанию — 1.1.1.1 и
  /// 8.8.8.8; при включённом «Мой DNS» — его локальные серверы, заданные IPv4-адресом. Следующий
  /// спрашивается, если предыдущий не ответил.
  static List<String> bootstrapDns(AppSettings settings) {
    if (settings.ownDns) {
      final own = <String>[];
      for (final a in RoutingProfile.splitDns(settings.ownDnsDomestic)) {
        final server = dnsServer(a);
        if (server == null) continue;
        final entry = _dnsEntry(server);
        final address = InternetAddress.tryParse('${entry['address']}');
        if (address == null || address.type != InternetAddressType.IPv4) continue;
        own.add(entry['port'] == null ? address.address : '${address.address}:${entry['port']}');
      }
      if (own.isNotEmpty) return own;
    }
    return const ['1.1.1.1', '8.8.8.8'];
  }

  /// Те же серверы записями для ядра. Запрос идёт по TCP с пометкой «+local»: ядро отправляет его само,
  /// мимо правил, — поэтому отдельного правила «напрямую» не нужно, и запросы программ или провайдера
  /// к тому же адресу (например, к 1.1.1.1) идут своим обычным путём.
  static List<Map<String, dynamic>> _bootstrapEntries(AppSettings settings, List<String> names) => [
        for (final a in bootstrapAddresses(settings)) {'address': a, 'domains': names, 'skipFallback': true},
      ];

  /// Адреса этих служебных серверов в том виде, как они записаны в конфиге ядра.
  static List<String> bootstrapAddresses(AppSettings settings) =>
      [for (final a in bootstrapDns(settings)) 'tcp+local://$a'];
  static const _privateNets = [
    '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '127.0.0.0/8', '224.0.0.0/4',
    '255.255.255.255/32', 'fc00::/7', 'fe80::/10', 'ff00::/8',
  ];

  /// Теги из правила: в конфиге Xray это список или одна строка.
  static List<String> _tags(Object? value) => switch (value) {
        final List l => [for (final t in l) '$t'],
        final String s => [s],
        _ => const [],
      };

  static void _collectAddresses(Object? node, Set<String> out) {
    if (node is Map) {
      final a = node['address'];
      if (a is String && a.isNotEmpty && InternetAddress.tryParse(a) == null) out.add(a);
      node.values.forEach((v) => _collectAddresses(v, out));
    } else if (node is List) {
      node.forEach((v) => _collectAddresses(v, out));
    }
  }

  /// Режим «TUN на ядре Xray»: адаптер поднимает сам Xray, sing-box не запускается.
  /// Дописывает в готовый конфиг (свой или провайдера) вход TUN, перехват DNS и правила по приложениям —
  /// то же, что в обычном режиме делает [SingboxConfig]. Свои выходы и правила названы с приставкой
  /// `skipit-`, чтобы не совпасть с тегами провайдера.
  static void addTun(
    Map<String, dynamic> cfg, {
    required AppSettings settings,
    required AppRules apps,
    List<String> directDomains = const [],
  }) {
    const direct = _direct, block = _block, dnsOut = 'skipit-dns';
    final inbound = [tunTag];
    _addOwnOutbounds(cfg, settings);

    final tun = {
      'tag': tunTag,
      'protocol': 'tun',
      'settings': {
        'name': AppPaths.appName,
        'desc': AppPaths.appName,
        'mtu': settings.mtu,
        // IPv6-адрес и маршрут есть всегда: иначе IPv6-трафик шёл бы мимо туннеля (утечка IP).
        // При выключенном IPv6 он блокируется правилом ниже.
        'gateway': _tunGateway,
        'dns': [_tunDns],
        'autoSystemRoutingTable': ['0.0.0.0/0', '::/0'],
        // Сам Xray ходит через настоящий сетевой адаптер — иначе получится петля.
        'autoOutboundsInterface': 'auto',
        // DNS-запросы программ мимо адаптера блокируются фильтром Windows.
        'autoSystemWfpBlockLeak': ['dns'],
      },
      'sniffing': {
        'enabled': settings.sniffing,
        'destOverride': ['http', 'tls', 'quic'],
        'routeOnly': false,
      },
    };
    cfg['inbounds'] = [...(cfg['inbounds'] as List? ?? const []), tun];

    final outbounds = [...(cfg['outbounds'] as List)];
    final first = outbounds.first as Map;
    final defaultTag = (first['tag'] ??= 'proxy') as String;
    final domains = <String>{...directDomains};
    _collectAddresses(outbounds, domains);
    outbounds.add(_dnsOutbound);
    cfg['outbounds'] = outbounds;
    resolveLocalDnsNames(cfg, settings: settings);

    final dns = (cfg['dns'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final servers = [...(dns['servers'] as List? ?? const [])];
    if (servers.isEmpty) servers.add('1.1.1.1');
    if (domains.isNotEmpty) servers.addAll(_bootstrapEntries(settings, [for (final d in domains) 'full:$d']));
    dns['servers'] = servers;
    cfg['dns'] = dns;

    final routing = (cfg['routing'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    // Правила провайдера, привязанные к прокси-портам, должны действовать и на трафик из адаптера —
    // иначе он пошёл бы мимо них, через выход по умолчанию.
    final rules = [
      for (final r in (routing['rules'] as List? ?? const []))
        if (r is Map && _tags(r['inboundTag']).any(_proxyInbounds.contains))
          {...r, 'inboundTag': [..._tags(r['inboundTag']), tunTag]}
        else
          r,
    ];
    final own = <Map<String, dynamic>>[
      {'inboundTag': inbound, 'port': '53', 'outboundTag': dnsOut},
      {'inboundTag': inbound, 'ip': _privateNets, 'outboundTag': direct},
      if (!settings.ipv6) {'inboundTag': inbound, 'ip': ['::/0'], 'outboundTag': block},
    ];

    routing['rules'] = [
      ...own,
      // Правила по приложениям действуют и на адаптер, и на HTTP-порт: в «Смешанном» режиме
      // браузеры ходят через системный прокси, мимо адаптера.
      ..._appRules(apps, [tunTag, _httpInbound], rules, defaultTag, direct),
      ...rules,
    ];
    cfg['routing'] = routing;
  }

  /// Вход системного прокси. На SOCKS-порт правила по приложениям не распространяются: для UDP через
  /// SOCKS Xray не определяет программу, и в режиме «только выбранные» такой трафик ушёл бы мимо VPN.
  static const _httpInbound = 'http';
  static const _proxyInbounds = ['socks', _httpInbound];

  /// Правила по приложениям для соединений, пришедших через входы [inbound].
  /// Запись списка — имя процесса, путь или папка с прямыми слэшами: Xray понимает их в том же виде.
  static List<Map<String, dynamic>> _appRules(
    AppRules apps,
    List<String> inbound,
    List rules,
    String defaultTag,
    String direct,
  ) {
    final listed = apps.enabledMatches;
    switch (apps.mode) {
      case AppRoutingMode.off:
        return const [];
      case AppRoutingMode.allExcept:
        return [
          if (listed.isNotEmpty) {'inboundTag': inbound, 'process': listed, 'outboundTag': direct},
        ];
      case AppRoutingMode.onlySelected:
        // Правила «все, кроме списка» в Xray нет. Поэтому для выбранных программ повторяются обычные
        // правила, а всё остальное с этих входов идёт напрямую.
        final vpn = listed;
        return [
          if (vpn.isNotEmpty) ...[
            for (final r in rules)
              // Берутся общие правила и те, что провайдер привязал к этим же входам.
              if (r is Map &&
                  r['process'] == null &&
                  (r['inboundTag'] == null || _tags(r['inboundTag']).any(inbound.contains)))
                {...r.cast<String, dynamic>(), 'inboundTag': inbound, 'process': vpn}..remove('ruleTag'),
            {'inboundTag': inbound, 'process': vpn, 'outboundTag': defaultTag},
          ],
          {'inboundTag': inbound, 'outboundTag': direct},
        ];
    }
  }

  /// TUN держит sing-box: правила по приложениям для трафика из адаптера применяет он сам
  /// ([SingboxConfig]). Но через системный прокси программы приходят в Xray напрямую, мимо sing-box
  /// (в «Смешанном» режиме так ходят браузеры) — для них те же правила добавляются сюда.
  /// SOCKS-порт не затрагивается: через него в Xray приходит весь трафик из адаптера от sing-box.
  static void addProxyAppRules(Map<String, dynamic> cfg, {required AppSettings settings, required AppRules apps}) {
    if (apps.mode == AppRoutingMode.off) return;
    const direct = _direct;
    final defaultTag = (((cfg['outbounds'] as List).first as Map)['tag'] ??= 'proxy') as String;
    _addOwnOutbounds(cfg, settings);
    final routing = (cfg['routing'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final rules = [...(routing['rules'] as List? ?? const [])];
    routing['rules'] = [
      ..._appRules(apps, const [_httpInbound], rules, defaultTag, direct),
      ...rules,
    ];
    cfg['routing'] = routing;
  }

  static const directInTag = 'skipit-direct-in';

  /// Локальный вход «мимо VPN-сервера»: через него программа обновляет подписку, когда через VPN
  /// сервер подписки недоступен (некоторые провайдеры не пускают к нему запросы со своих же серверов).
  /// Обычный запрос «напрямую» в режиме TUN всё равно уходит в адаптер, а при включённом Kill Switch
  /// не выходит вовсе; ядро же выходит в сеть мимо адаптера.
  /// Вход пропускает только адреса из [hosts] (серверы подписок) — всё остальное блокируется, чтобы
  /// другая программа на компьютере не могла ходить через него в обход VPN.
  static void addDirectInbound(
    Map<String, dynamic> cfg, {
    required int port,
    required List<String> hosts,
    required AppSettings settings,
  }) {
    const direct = _direct, block = _block;
    cfg['inbounds'] = [
      ...(cfg['inbounds'] as List? ?? const []),
      {
        'tag': directInTag,
        'protocol': 'http',
        'listen': '127.0.0.1',
        'port': port,
        'settings': <String, dynamic>{},
      },
    ];
    _addOwnOutbounds(cfg, settings);

    final routing = (cfg['routing'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final domains = [for (final h in hosts.toSet()) if (InternetAddress.tryParse(h) == null) 'full:$h'];
    final ips = [for (final h in hosts.toSet()) if (InternetAddress.tryParse(h) != null) h];
    const inbound = [directInTag];
    routing['rules'] = [
      if (domains.isNotEmpty) {'inboundTag': inbound, 'domain': domains, 'outboundTag': direct},
      if (ips.isNotEmpty) {'inboundTag': inbound, 'ip': ips, 'outboundTag': direct},
      {'inboundTag': inbound, 'outboundTag': block},
      ...(routing['rules'] as List? ?? const []),
    ];
    cfg['routing'] = routing;
  }

  /// Выход, который отвечает на запросы DNS встроенным DNS Xray.
  static const _dnsOutbound = {
    'tag': 'skipit-dns',
    'protocol': 'dns',
    'settings': {
      // На запросы адресов (A и AAAA) отвечает встроенный DNS Xray. На остальные (SRV, TXT, PTR…) —
      // пустой ответ без ошибки. Отказ (код 5) Windows принимала за сбой сервера и шла к DNS сетевой
      // карты, закрытому защитой от утечек: программа ждала 12 секунд и получала ошибку.
      'rules': [
        {'action': 'hijack', 'qType': '1,28'},
        {'action': 'return', 'rCode': 0},
      ],
    },
  };

  /// К DNS-серверу с пометкой «+local» ядро подключается само и его имя ищет своим же DNS. Без отдельной
  /// записи имя сервера спрашивалось бы у него самого: каждое новое соединение с ним ждало отказа по
  /// времени, а вместе с ним — все запросы, что стояли в очереди. Имя узнаётся у запасного DNS из того же
  /// конфига (общего и не «+local» — обычно он идёт через VPN), а если такого нет — напрямую у
  /// [bootstrapDns], как адреса VPN-серверов. Нужно везде, где на запросы программ отвечает DNS ядра.
  static void resolveLocalDnsNames(Map<String, dynamic> cfg, {required AppSettings settings}) {
    final dns = (cfg['dns'] as Map?)?.cast<String, dynamic>();
    final servers = [...(dns?['servers'] as List? ?? const [])];
    final localDns = <String>{};
    Object? spareDns;
    for (final s in servers) {
      final address = s is Map ? s['address'] : s;
      if (address is! String || address == 'localhost' || address == 'fakedns') continue;
      if (address.contains('+local://')) {
        final host = Uri.tryParse(address)?.host ?? '';
        if (host.isNotEmpty && InternetAddress.tryParse(host) == null) localDns.add(host);
      } else if (s is! Map || (s['domains'] as List? ?? const []).isEmpty) {
        spareDns ??= s;
      }
    }
    if (dns == null || localDns.isEmpty) return;
    final names = [for (final d in localDns) 'full:$d'];
    if (spareDns != null) {
      servers.add({..._dnsEntry(spareDns), 'domains': names, 'skipFallback': true});
    } else {
      servers.addAll(_bootstrapEntries(settings, names));
    }
    dns['servers'] = servers;
    cfg['dns'] = dns;
  }

  static const dnsInTag = 'skipit-dns-port';

  /// Локальный вход DNS для режима, где адаптер держит sing-box: тот пересылает сюда запросы программ,
  /// и отвечает на них встроенный DNS Xray — со всеми серверами из конфига, запасными и правилами
  /// провайдера, как в режиме «TUN на ядре Xray». Слушает только этот компьютер.
  static void addDnsInbound(Map<String, dynamic> cfg, {required int port, required AppSettings settings}) {
    resolveLocalDnsNames(cfg, settings: settings);
    cfg['inbounds'] = [
      ...(cfg['inbounds'] as List? ?? const []),
      {
        'tag': dnsInTag,
        'protocol': 'dokodemo-door',
        'listen': '127.0.0.1',
        'port': port,
        // Адрес назначения ни на что не влияет: все запросы с этого входа забирает правило ниже.
        'settings': {'address': _tunDns, 'port': 53, 'network': 'tcp,udp'},
      },
    ];
    cfg['outbounds'] = [...(cfg['outbounds'] as List), _dnsOutbound];
    final routing = (cfg['routing'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    routing['rules'] = [
      {'inboundTag': const [dnsInTag], 'outboundTag': 'skipit-dns'},
      ...(routing['rules'] as List? ?? const []),
    ];
    cfg['routing'] = routing;
  }

  static const dnsCheckInTag = 'skipit-dnscheck-in';

  /// Локальный вход для проверки DNS (см. DnsCheck): запрос к DNS-серверу, пришедший через него, идёт
  /// тем же путём, каким к этому серверу ходит само ядро. Для этого правила, привязанные к запросам
  /// встроенного DNS (inboundTag = тег dns), распространяются и на этот вход. Слушает только этот
  /// компьютер и закрыт паролем [password] — своим на каждое подключение: без него другая программа
  /// могла бы ходить через этот вход в VPN. Вызывается последним — когда все правила уже на месте.
  static void addDnsCheckInbound(Map<String, dynamic> cfg, {required int port, required String password}) {
    cfg['inbounds'] = [
      ...(cfg['inbounds'] as List? ?? const []),
      {
        'tag': dnsCheckInTag,
        'protocol': 'socks',
        'listen': '127.0.0.1',
        'port': port,
        'settings': {
          'auth': 'password',
          'accounts': [
            {'user': AppSettings.serviceUser, 'pass': password},
          ],
          'udp': true,
        },
      },
    ];
    final tag = (cfg['dns'] as Map?)?['tag'];
    if (tag is! String) return;
    final routing = (cfg['routing'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    routing['rules'] = [
      for (final r in (routing['rules'] as List? ?? const []))
        if (r is Map && _tags(r['inboundTag']).contains(tag))
          {...r, 'inboundTag': [..._tags(r['inboundTag']), dnsCheckInTag]}
        else
          r,
    ];
    cfg['routing'] = routing;
  }

  static const checkInTag = 'skipit-check-in';

  /// Адрес, по которому программа проверяет связь через VPN и узнаёт страну выхода.
  static const checkHost = 'www.cloudflare.com';

  /// Локальный вход для проверки связи: запрос программы к [checkHost] всегда идёт через VPN-сервер,
  /// какими бы ни были правила маршрутизации (обычный запрос мог бы уйти напрямую и ничего не сказал бы
  /// о сервере). Всё, кроме этого адреса, вход блокирует.
  static void addCheckInbound(Map<String, dynamic> cfg, {required int port}) {
    const block = 'skipit-block';
    cfg['inbounds'] = [
      ...(cfg['inbounds'] as List? ?? const []),
      {
        'tag': checkInTag,
        'protocol': 'http',
        'listen': '127.0.0.1',
        'port': port,
        'settings': <String, dynamic>{},
      },
    ];
    final outbounds = [...(cfg['outbounds'] as List)];
    if (!outbounds.any((o) => o is Map && o['tag'] == block)) outbounds.add({'tag': block, 'protocol': 'blackhole'});
    cfg['outbounds'] = outbounds;

    final routing = (cfg['routing'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final rules = [...(routing['rules'] as List? ?? const [])];
    final vpn = _vpnTarget(cfg);
    if (vpn == null) return;
    const inbound = [checkInTag];
    routing['rules'] = [
      {
        'inboundTag': inbound,
        'domain': ['full:$checkHost'],
        ...vpn,
      },
      {'inboundTag': inbound, 'outboundTag': block},
      ...rules,
    ];
    cfg['routing'] = routing;
  }

  /// Адреса VPN-серверов ядро узнаёт само — своим DNS и напрямую, а не через Windows.
  /// Windows в момент подключения может спросить имя сервера только у DNS обычной сети, а этот запрос
  /// не выпускает защита от утечек DNS (и Kill Switch). Тогда ядро ждёт ответа секунд двенадцать
  /// (столько Windows перебирает попытки), и всё это время VPN «подключён», но не работает — так
  /// бывало не при каждом подключении. Запрос самого ядра к [bootstrapDns] разрешён: ядру можно
  /// выходить в сеть мимо адаптера.
  static void resolveServersInside(Map<String, dynamic> cfg, {required AppSettings settings}) {
    final strategy = settings.ipv6 ? 'UseIP' : 'UseIPv4';
    final outbounds = [...(cfg['outbounds'] as List)];
    final domains = <String>{};
    for (final o in outbounds) {
      if (o is! Map || const ['freedom', 'blackhole', 'dns'].contains(o['protocol'])) continue;
      final own = <String>{};
      _collectAddresses(o, own);
      if (own.isEmpty) continue;
      domains.addAll(own);
      // С этой настройкой адрес сервера в исходящем соединении ищет встроенный DNS Xray.
      final stream = (o['streamSettings'] ??= <String, dynamic>{}) as Map;
      final sockopt = (stream['sockopt'] ??= <String, dynamic>{}) as Map;
      // «AsIs» из конфига провайдера значит «спросить Windows» — это как раз то, чего здесь быть не должно.
      if (sockopt['domainStrategy'] == null || sockopt['domainStrategy'] == 'AsIs') sockopt['domainStrategy'] = strategy;
    }
    if (domains.isEmpty) return;
    cfg['outbounds'] = outbounds;

    final dns = (cfg['dns'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final servers = [...(dns['servers'] as List? ?? const [])];
    if (servers.isEmpty) servers.add('1.1.1.1');
    final wanted = [for (final d in domains) 'full:$d'];
    final entries = _bootstrapEntries(settings, wanted);
    // В режиме «TUN на ядре Xray» такие записи уже добавлены в [addTun].
    final known = servers.any((s) =>
        s is Map &&
        s['address'] == entries.first['address'] &&
        wanted.every((s['domains'] as List? ?? const []).contains));
    if (!known) servers.addAll(entries);
    dns['servers'] = servers;
    cfg['dns'] = dns;
  }

  /// Конфиг для проверки задержки: на каждый сервер свой HTTP-inbound на своём порту.
  static Map<String, dynamic> buildTest(List<ServerProfile> servers, int basePort) {
    final inbounds = <Map<String, dynamic>>[];
    final outbounds = <Map<String, dynamic>>[];
    final rules = <Map<String, dynamic>>[];
    for (var i = 0; i < servers.length; i++) {
      inbounds.add({
        'tag': 'in$i',
        'protocol': 'http',
        'listen': '127.0.0.1',
        'port': basePort + i,
        'settings': <String, dynamic>{},
      });
      outbounds.add(dropRemovedOptions(deepCopyMap(servers[i].outbound))..['tag'] = 'out$i');
      rules.add({
        'inboundTag': ['in$i'],
        'outboundTag': 'out$i',
      });
    }
    return {
      'log': {'loglevel': 'none', 'access': 'none'},
      'inbounds': inbounds,
      'outbounds': outbounds,
      'routing': {'rules': rules},
    };
  }
}
