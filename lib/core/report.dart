import 'dart:convert';

/// Отчёт для разбора: одним текстовым файлом то, по чему можно понять, что не так у человека, —
/// версия, настройки, устройство конфигов ядер и журнал подключения. Ключей, ссылок подписок и
/// адресов VPN-серверов в нём нет: из конфигов берутся только перечисленные здесь поля, а в журнале
/// адреса серверов заменяются словом. Адреса сайтов из журнала остаются — без них разбор невозможен.
class DiagReport {
  /// Сколько знаков журнала попадает в отчёт: при уровне debug файл подключения бывает на десятки мегабайт.
  static const logLimit = 3 * 1024 * 1024;

  static const _hidden = '<VPN-сервер>';
  static const _hiddenDomain = '<адрес провайдера>';

  static String _count(Object? list, String what) => '(${list is List ? list.length : 1} $what)';

  static Map<String, dynamic>? _pick(Object? node, List<String> keys) => node is! Map
      ? null
      : {
          for (final k in keys)
            if (node[k] != null) k: node[k],
        };

  /// Устройство конфига Xray без ключей, адресов серверов и списков сайтов.
  static Map<String, dynamic> xrayShape(Map<String, dynamic> cfg) {
    final routing = cfg['routing'] as Map? ?? const {};
    final dns = cfg['dns'] as Map? ?? const {};
    return {
      'log': _pick(cfg['log'], const ['loglevel']),
      'inbounds': [
        for (final i in (cfg['inbounds'] as List? ?? const []).whereType<Map>())
          {
            ...?_pick(i, const ['tag', 'protocol', 'listen', 'port', 'sniffing']),
            if (i['protocol'] == 'tun')
              'settings': _pick(i['settings'], const [
                'mtu',
                'gateway',
                'dns',
                'autoSystemRoutingTable',
                'autoOutboundsInterface',
                'autoSystemWfpBlockLeak',
              ]),
          },
      ],
      'outbounds': [
        for (final o in (cfg['outbounds'] as List? ?? const []).whereType<Map>())
          {
            ...?_pick(o, const ['tag', 'protocol', 'mux']),
            ...?_pick(o['streamSettings'], const ['network', 'security', 'sockopt']),
            if ((o['settings'] as Map?)?['domainStrategy'] != null)
              'domainStrategy': (o['settings'] as Map)['domainStrategy'],
          },
      ],
      'routing': {
        ...?_pick(routing, const ['domainStrategy']),
        'balancers': [
          for (final b in (routing['balancers'] as List? ?? const []).whereType<Map>())
            _pick(b, const ['tag', 'selector', 'strategy', 'fallbackTag']),
        ],
        'rules': [
          for (final r in (routing['rules'] as List? ?? const []).whereType<Map>())
            {
              ...?_pick(r, const ['inboundTag', 'outboundTag', 'balancerTag', 'port', 'network', 'protocol']),
              if (r['domain'] != null) 'domain': _count(r['domain'], 'имён'),
              if (r['ip'] != null) 'ip': _count(r['ip'], 'адресов'),
              if (r['process'] != null) 'process': _count(r['process'], 'программ'),
            },
        ],
      },
      'dns': {
        ...?_pick(dns, const [
          'tag',
          'queryStrategy',
          'disableCache',
          'serveStale',
          'disableFallback',
          'disableFallbackIfMatch',
          'enableParallelQuery',
        ]),
        if (dns['hosts'] is Map) 'hosts': '(${(dns['hosts'] as Map).length} записей)',
        'servers': [
          for (final s in dns['servers'] as List? ?? const [])
            if (s is Map)
              {
                ...?_pick(s, const ['address', 'port', 'skipFallback', 'timeoutMs', 'queryStrategy', 'finalQuery']),
                if (s['domains'] != null) 'domains': _count(s['domains'], 'имён'),
                if (s['expectedIPs'] != null) 'expectedIPs': _count(s['expectedIPs'], 'адресов'),
              }
            else
              s,
        ],
      },
      for (final k in const ['observatory', 'burstObservatory'])
        if (cfg[k] is Map)
          k: {
            ...?_pick(cfg[k], const ['subjectSelector', 'probeInterval']),
            'pingConfig': _pick((cfg[k] as Map)['pingConfig'], const ['interval', 'sampling', 'timeout']),
          },
      if (cfg['policy'] != null) 'policy': cfg['policy'],
    };
  }

  /// Устройство конфига sing-box: серверов в нём нет, убираются логин и пароль локального порта,
  /// ключ списка соединений и списки программ и сайтов.
  static Object? singboxShape(Object? node) {
    if (node is List) return [for (final v in node) singboxShape(v)];
    if (node is! Map) return node;
    return {
      for (final e in node.entries)
        if (const ['username', 'password', 'secret'].contains(e.key))
          e.key: '(скрыто)'
        else if (const ['process_name', 'process_path', 'process_path_regex'].contains(e.key))
          e.key: _count(e.value, 'программ')
        else if (e.key == 'domain' || e.key == 'domain_suffix')
          e.key: _count(e.value, 'имён')
        else
          e.key: singboxShape(e.value),
    };
  }

  /// Адреса VPN-серверов из конфига Xray: имена и адреса у выходов и имена из настроек TLS.
  static Set<String> serverAddresses(Map<String, dynamic> cfg) {
    final out = <String>{};
    void walk(Object? node) {
      if (node is Map) {
        for (final k in const ['address', 'serverName', 'host']) {
          final v = node[k];
          if (v is String && v.length > 3) out.add(v);
        }
        final endpoint = node['endpoint'];
        if (endpoint is String && endpoint.contains(':')) out.add(endpoint.substring(0, endpoint.lastIndexOf(':')));
        node.values.forEach(walk);
      } else if (node is List) {
        node.forEach(walk);
      }
    }

    for (final o in (cfg['outbounds'] as List? ?? const []).whereType<Map>()) {
      if (const ['freedom', 'blackhole', 'dns', 'loopback'].contains(o['protocol'])) continue;
      walk(o['settings']);
      walk(o['streamSettings']);
    }
    return out..removeWhere((a) => a == '127.0.0.1' || a == 'localhost');
  }

  /// Имена серверов из конфига Xray (без адресов цифрами и без имён из настроек TLS).
  static Set<String> serverNames(Map<String, dynamic> cfg) {
    final out = <String>{};
    void walk(Object? node) {
      if (node is Map) {
        final a = node['address'];
        if (a is String && RegExp(r'[a-zA-Z]').hasMatch(a) && a.contains('.')) out.add(a);
        node.values.forEach(walk);
      } else if (node is List) {
        node.forEach(walk);
      }
    }

    for (final o in (cfg['outbounds'] as List? ?? const []).whereType<Map>()) {
      if (!const ['freedom', 'blackhole', 'dns', 'loopback'].contains(o['protocol'])) walk(o['settings']);
    }
    return out;
  }

  /// Домен провайдера по имени его узла: `fi.vpn.example` → `vpn.example`. По нему скрываются и соседние
  /// имена — сайт провайдера, адрес подписки, — на которые программа и браузер ходят через тот же VPN.
  static String domainOf(String host) {
    final labels = host.toLowerCase().split('.');
    if (labels.length <= 2) return labels.join('.');
    const generic = ['co', 'com', 'net', 'org', 'gov', 'edu', 'ac'];
    return labels.sublist(labels.length - (generic.contains(labels[labels.length - 2]) ? 3 : 2)).join('.');
  }

  static final _answer = RegExp(r'-> \[([0-9a-fA-F:. ,]+)\]');
  static final _userDir = RegExp(r'\\Users\\[^\\/:*?"<>|\r\n]+', caseSensitive: false);

  /// Убирает из текста адреса VPN-серверов [servers] — и адреса, в которые их имена превратил DNS
  /// (в журнале это строки «got answer: имя. … -> [адреса]»), — любые имена на доменах [domains]
  /// и имя пользователя Windows в путях.
  static String mask(String text, Set<String> servers, {Set<String> domains = const {}}) {
    final secrets = {...servers};
    if (servers.isNotEmpty) {
      for (final line in const LineSplitter().convert(text)) {
        if (!line.contains('-> [') || !servers.any(line.contains)) continue;
        final m = _answer.firstMatch(line);
        if (m != null) secrets.addAll(m[1]!.split(RegExp(r'[ ,]+')).where((a) => a.length > 6));
      }
    }
    // Длинные раньше коротких: иначе имя, входящее в другое, оставило бы от него хвост.
    for (final s in secrets.toList()..sort((a, b) => b.length.compareTo(a.length))) {
      text = text.replaceAll(s, _hidden);
    }
    for (final d in domains) {
      // Только имя целиком и его поддомены: чужое имя, которое лишь оканчивается так же, не трогаем.
      final name = RegExp('(?<![a-z0-9.-])(?:[a-z0-9-]+\\.)*${RegExp.escape(d)}(?![a-z0-9-])', caseSensitive: false);
      text = text.replaceAll(name, _hiddenDomain);
    }
    return text.replaceAll(_userDir, r'\Users\<пользователь>');
  }

  /// Собирает отчёт. [facts] — строки «что: значение» о программе и подключении, [log] — журнал
  /// подключения как есть; конфиги — те, с которыми ядра запускались в последний раз (или null);
  /// [providerHosts] — имена из адресов подписок: их домены скрываются так же, как домены серверов;
  /// [serverIps] — адреса, в которые имена серверов превращаются сейчас (в журнале уровня warning нет
  /// строк с ответами DNS, по которым их находит [mask], а в ошибках подключения адрес сервера бывает).
  static String build({
    required Map<String, Object?> facts,
    Map<String, dynamic>? xray,
    Map<String, dynamic>? singbox,
    Set<String> providerHosts = const {},
    Set<String> serverIps = const {},
    required String log,
  }) {
    const json = JsonEncoder.withIndent('  ');
    final servers = {if (xray != null) ...serverAddresses(xray), ...serverIps};
    final cut = log.length > logLimit;
    final b = StringBuffer()
      ..writeln('Отчёт SkipIt для разбора')
      ..writeln('Ключей, ссылок подписок и адресов VPN-серверов здесь нет. Адреса сайтов из журнала есть.')
      ..writeln();
    for (final e in facts.entries) {
      b.writeln('${e.key}: ${e.value ?? '—'}');
    }
    b
      ..writeln()
      ..writeln('=== Конфиг Xray (устройство) ===')
      ..writeln(xray == null ? 'ядро в этом запуске не запускалось' : json.convert(xrayShape(xray)))
      ..writeln()
      ..writeln('=== Конфиг sing-box (устройство) ===')
      ..writeln(singbox == null ? 'ядро в этом запуске не запускалось' : json.convert(singboxShape(singbox)))
      ..writeln()
      ..writeln('=== Журнал подключения${cut ? ' (конец, последние ${logLimit ~/ (1024 * 1024)} МБ)' : ''} ===')
      ..writeln(cut ? log.substring(log.length - logLimit) : log);
    final domains = {
      for (final h in {...providerHosts, if (xray != null) ...serverNames(xray)})
        if (h.contains('.') && RegExp(r'[a-zA-Z]').hasMatch(h)) domainOf(h),
    };
    return mask(b.toString(), servers, domains: domains);
  }
}
