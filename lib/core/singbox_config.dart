import 'dart:io';

import '../models/app_rules.dart';
import '../models/routing.dart';
import '../models/settings.dart';
import 'paths.dart';
import 'xray_config.dart';

/// sing-box поднимает TUN-адаптер и отправляет весь трафик в SOCKS-порт Xray.
/// Сам Xray (и sing-box) идут напрямую — иначе получится петля.
/// Здесь же применяются правила по приложениям: sing-box видит, какой процесс открыл соединение.
class SingboxConfig {
  static Map<String, dynamic> _dnsServer(String tag, String address, {String? detour}) {
    if (address.startsWith('https://')) {
      final uri = Uri.parse(address);
      final isIp = InternetAddress.tryParse(uri.host) != null;
      return {
        'type': 'https',
        'tag': tag,
        'server': uri.host,
        if (uri.hasPort) 'server_port': uri.port,
        'path': uri.path.isEmpty ? '/dns-query' : uri.path,
        if (!isIp) 'domain_resolver': 'bootstrap',
        if (detour != null) 'detour': detour,
      };
    }
    // DNS поверх TLS (DoT), по TCP и обычный с портом: tls://…, tcp://…, udp://… или адрес:порт.
    final uri = InternetAddress.tryParse(address) != null
        ? null
        : Uri.tryParse(address.contains('://') ? address : 'udp://$address');
    if (uri != null && uri.host.isNotEmpty && const ['tls', 'tcp', 'udp'].contains(uri.scheme)) {
      return {
        'type': uri.scheme,
        'tag': tag,
        'server': uri.host,
        if (uri.hasPort) 'server_port': uri.port,
        if (InternetAddress.tryParse(uri.host) == null) 'domain_resolver': 'bootstrap',
        if (detour != null) 'detour': detour,
      };
    }
    return {'type': 'udp', 'tag': tag, 'server': address, if (detour != null) 'detour': detour};
  }

  static Map<String, dynamic> _processMatch(List<String> matches) {
    final names = <String>[];
    final paths = <String>[];
    final regex = <String>[];
    for (final m in matches) {
      if (m.endsWith('/')) {
        regex.add('(?i)^${RegExp.escape(m.replaceAll('/', '\\'))}');
      } else if (m.contains('/')) {
        paths.add(m.replaceAll('/', '\\'));
      } else {
        names.add(m.toLowerCase().endsWith('.exe') ? m : '$m.exe');
      }
    }
    return {
      if (names.isNotEmpty) 'process_name': names,
      if (paths.isNotEmpty) 'process_path': paths,
      if (regex.isNotEmpty) 'process_path_regex': regex,
    };
  }

  static Map<String, dynamic> build({
    required AppSettings settings,
    required RoutingProfile routing,
    required AppRules apps,
    required List<String> serverDomains,
    int? statsPort,
    String statsSecret = '',
    int? xrayDnsPort,
  }) {
    final rules = <Map<String, dynamic>>[
      {'action': 'sniff'},
      {'protocol': 'dns', 'action': 'hijack-dns'},
      {
        'process_name': ['skipit-xray.exe', 'skipit-sing-box.exe'],
        'outbound': 'direct',
      },
      {'ip_is_private': true, 'outbound': 'direct'},
      // IPv6 выключен — такой трафик не выпускаем вовсе (ни в туннель, ни мимо него).
      if (!settings.ipv6) {'ip_version': 6, 'action': 'reject'},
    ];

    var finalOutbound = 'proxy';
    final directApps = <String>[];

    // Список один, его смысл задаёт режим: «все, кроме списка» — список идёт напрямую,
    // «только выбранные» — через VPN идёт только список.
    final listed = apps.enabledMatches;
    switch (apps.mode) {
      case AppRoutingMode.off:
        break;
      case AppRoutingMode.allExcept:
        if (listed.isNotEmpty) rules.add({..._processMatch(listed), 'outbound': 'direct'});
        directApps.addAll(listed);
      case AppRoutingMode.onlySelected:
        if (listed.isNotEmpty) rules.add({..._processMatch(listed), 'outbound': 'proxy'});
        finalOutbound = 'direct';
    }

    final dnsRules = <Map<String, dynamic>>[
      // Адрес VPN-сервера резолвим напрямую, иначе Xray не сможет к нему подключиться.
      if (serverDomains.isNotEmpty) {'domain': serverDomains, 'server': 'local'},
      if (directApps.isNotEmpty) {..._processMatch(directApps), 'server': 'local'},
    ];

    final ipv6 = settings.ipv6;
    return {
      // Своё время ядро не пишет: журнал программы ставит его каждой строке сам.
      'log': {'level': settings.logLevel == 'warning' ? 'warn' : settings.logLevel, 'timestamp': false},
      'dns': {
        'servers': [
          // Запросы программ пересылаются ядру Xray (см. XrayConfig.addDnsInbound): у него полный список
          // DNS с запасными и правила провайдера. Без порта — прежняя схема: удалённый DNS через VPN.
          if (xrayDnsPort != null)
            {'type': 'udp', 'tag': 'remote', 'server': '127.0.0.1', 'server_port': xrayDnsPort}
          else
            _dnsServer('remote', routing.remoteDnsAddress, detour: 'proxy'),
          _dnsServer('local', routing.domesticDnsAddress),
          {'type': 'udp', 'tag': 'bootstrap', 'server': '77.88.8.8'},
        ],
        'rules': dnsRules,
        'final': finalOutbound == 'proxy' ? 'remote' : 'local',
        'strategy': ipv6 ? 'prefer_ipv4' : 'ipv4_only',
      },
      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',
          'interface_name': AppPaths.appName,
          // IPv6-адрес у адаптера есть всегда: иначе IPv6-трафик шёл бы мимо туннеля (утечка IP),
          // если у интернет-провайдера пользователя есть IPv6. При выключенном IPv6 он блокируется правилом ниже.
          'address': ['${XrayConfig.tunV4}/30', '${XrayConfig.tunV6}/126'],
          'mtu': settings.mtu,
          'auto_route': true,
          'strict_route': true,
          'stack': 'mixed',
        },
      ],
      'outbounds': [
        {
          'type': 'socks',
          'tag': 'proxy',
          'server': '127.0.0.1',
          'server_port': settings.socksPort,
          'version': '5',
          if (settings.portAuth) ...{'username': settings.portUser, 'password': settings.portPassword},
        },
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'rules': rules,
        'final': finalOutbound,
        'auto_detect_interface': true,
        'default_domain_resolver': 'bootstrap',
      },
      // Список соединений для счётчика трафика «напрямую». Слушает только этот компьютер и закрыт
      // ключом: без него другая программа могла бы разрывать соединения и менять режим ядра.
      if (statsPort != null)
        'experimental': {
          'clash_api': {'external_controller': '127.0.0.1:$statsPort', 'secret': statsSecret},
        },
    };
  }
}
