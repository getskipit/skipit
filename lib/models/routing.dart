import 'dart:convert';

import '../core/util.dart';

class RoutingDeeplink {
  RoutingDeeplink({this.profile, this.activate = false, this.off = false});

  final RoutingProfile? profile;

  /// `onadd` — сразу сделать профиль активным.
  final bool activate;

  /// `happ://routing/off` — отключить маршрутизацию (весь трафик через VPN).
  final bool off;
}

/// Профиль маршрутизации, совместимый по полям с Happ (`happ://routing/add/{base64}`).
class RoutingProfile {
  RoutingProfile({
    String? id,
    required this.name,
    this.globalProxy = true,
    this.domainStrategy = 'IPIfNonMatch',
    this.remoteDnsType = 'DoH',
    this.remoteDnsDomain = 'https://cloudflare-dns.com/dns-query',
    this.remoteDnsIp = '1.1.1.1',
    this.domesticDnsType = 'DoU',
    this.domesticDnsDomain = '',
    this.domesticDnsIp = '77.88.8.8',
    List<String>? directSites,
    List<String>? directIp,
    List<String>? proxySites,
    List<String>? proxyIp,
    List<String>? blockSites,
    List<String>? blockIp,
    Map<String, String>? dnsHosts,
    this.geoipUrl = defaultGeoipUrl,
    this.geositeUrl = defaultGeositeUrl,
    this.subscriptionId,
  })  : id = id ?? newId(),
        directSites = directSites ?? [],
        directIp = directIp ?? [],
        proxySites = proxySites ?? [],
        proxyIp = proxyIp ?? [],
        blockSites = blockSites ?? [],
        blockIp = blockIp ?? [],
        dnsHosts = dnsHosts ?? {};

  static const defaultGeoipUrl =
      'https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat';
  static const defaultGeositeUrl =
      'https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat';
  static const domainStrategies = ['AsIs', 'IPIfNonMatch', 'IPOnDemand'];
  static const dnsTypes = ['DoH', 'DoU'];
  static const globalPresetId = 'preset-global';

  String id;
  String name;

  /// true — всё, что не попало в правила, идёт через VPN; false — напрямую.
  bool globalProxy;
  String domainStrategy;
  String remoteDnsType;
  String remoteDnsDomain;
  String remoteDnsIp;
  String domesticDnsType;
  String domesticDnsDomain;
  String domesticDnsIp;
  List<String> directSites;
  List<String> directIp;
  List<String> proxySites;
  List<String> proxyIp;
  List<String> blockSites;
  List<String> blockIp;
  Map<String, String> dnsHosts;
  String geoipUrl;
  String geositeUrl;
  String? subscriptionId;

  String get remoteDnsAddress =>
      dnsAddress(remoteDnsType, remoteDnsDomain, remoteDnsIp, fallback: '1.1.1.1');

  String get domesticDnsAddress =>
      dnsAddress(domesticDnsType, domesticDnsDomain, domesticDnsIp, fallback: '77.88.8.8');

  /// Полные списки DNS из блока «Мой DNS»: первый адрес — основной, остальные — запасные. В профиле
  /// не хранятся; без них список — это один адрес профиля.
  List<String>? remoteDnsAll, domesticDnsAll;

  List<String> get remoteDnsList => remoteDnsAll ?? [remoteDnsAddress];
  List<String> get domesticDnsList => domesticDnsAll ?? [domesticDnsAddress];

  /// Несколько адресов из одного поля: через запятую, точку с запятой или пробел.
  static List<String> splitDns(String text) => text.split(RegExp(r'[,;\s]+')).where((a) => a.isNotEmpty).toList();

  /// Адреса DNS в том виде, как их вводят в поле: «https://…» — DNS по HTTPS, иначе IP-адрес сервера.
  void setDns({required String remote, required String domestic}) {
    remote = remote.trim();
    remoteDnsType = remote.startsWith('https://') ? 'DoH' : 'DoU';
    remoteDnsDomain = remote.startsWith('https://') ? remote : '';
    remoteDnsIp = remote.startsWith('https://') ? '' : remote;
    domestic = domestic.trim();
    domesticDnsType = domestic.startsWith('https://') ? 'DoH' : 'DoU';
    domesticDnsDomain = domestic.startsWith('https://') ? domestic : '';
    domesticDnsIp = domestic.startsWith('https://') ? '' : domestic;
  }

  /// Адрес DNS-сервера в формате Xray. `localhost` не используем: в режиме TUN
  /// системный DNS снова попадёт в туннель.
  static String dnsAddress(String type, String domain, String ip, {required String fallback}) {
    final d = domain.trim();
    final i = ip.trim();
    if (type.toLowerCase() == 'doh') {
      if (d.startsWith('https://')) return d;
      if (i.isNotEmpty) return 'https://$i/dns-query';
    }
    if (i.isNotEmpty) return i;
    if (d.isNotEmpty && !d.contains('://')) return d;
    return fallback;
  }

  int get ruleCount =>
      directSites.length + directIp.length + proxySites.length + proxyIp.length + blockSites.length + blockIp.length;

  String get summary {
    final base = globalProxy ? 'По умолчанию через VPN' : 'По умолчанию напрямую';
    return ruleCount == 0 ? base : '$base · правил: $ruleCount';
  }

  /// Единственный встроенный профиль: без правил, весь трафик через VPN (как по умолчанию в Happ).
  static RoutingProfile global() => RoutingProfile(
        id: globalPresetId,
        name: 'Весь трафик через VPN',
        directIp: ['geoip:private'],
      );

  /// Шаблоны для кнопки «Создать» — в список попадают, только если пользователь их выбрал.
  static List<RoutingProfile> templates() => [
        RoutingProfile(
          name: 'Россия напрямую',
          proxySites: ['geosite:ru-blocked'],
          proxyIp: ['geoip:ru-blocked'],
          directSites: ['geosite:category-ru', 'domain:ru', 'domain:su', 'domain:xn--p1ai'],
          directIp: ['geoip:ru', 'geoip:private'],
        ),
        RoutingProfile(
          name: 'Только заблокированное',
          globalProxy: false,
          proxySites: ['geosite:ru-blocked'],
          proxyIp: ['geoip:ru-blocked'],
          directIp: ['geoip:private'],
        ),
      ];

  /// id старых встроенных шаблонов — убираются из сохранённых данных при загрузке.
  static const legacyPresetIds = ['preset-ru-direct', 'preset-blocked-only'];

  factory RoutingProfile.fromHapp(Map<String, dynamic> j, {String? id}) {
    List<String> list(String key) {
      final v = j[key];
      if (v is List) {
        return v.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
      }
      if (v is String && v.trim().isNotEmpty) {
        return v.split(RegExp(r'[,\r\n]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      }
      return [];
    }

    String str(String key, String fallback) {
      final v = j[key];
      return v == null ? fallback : v.toString();
    }

    final hosts = <String, String>{};
    final rawHosts = j['DnsHosts'];
    if (rawHosts is Map) {
      rawHosts.forEach((k, v) => hosts[k.toString()] = v.toString());
    }

    return RoutingProfile(
      id: id,
      name: str('Name', 'Импортированный профиль'),
      globalProxy: parseBool(j['GlobalProxy'], true),
      domainStrategy: str('DomainStrategy', 'IPIfNonMatch'),
      remoteDnsType: str('RemoteDNSType', 'DoH'),
      remoteDnsDomain: str('RemoteDNSDomain', ''),
      remoteDnsIp: str('RemoteDNSIP', ''),
      domesticDnsType: str('DomesticDNSType', 'DoU'),
      domesticDnsDomain: str('DomesticDNSDomain', ''),
      domesticDnsIp: str('DomesticDNSIP', ''),
      directSites: list('DirectSites'),
      directIp: list('DirectIp'),
      proxySites: list('ProxySites'),
      proxyIp: list('ProxyIp'),
      blockSites: list('BlockSites'),
      blockIp: list('BlockIp'),
      dnsHosts: hosts,
      geoipUrl: str('Geoipurl', defaultGeoipUrl),
      geositeUrl: str('Geositeurl', defaultGeositeUrl),
    );
  }

  Map<String, dynamic> toHapp() => {
        'Name': name,
        'GlobalProxy': globalProxy.toString(),
        'RemoteDNSType': remoteDnsType,
        'RemoteDNSDomain': remoteDnsDomain,
        'RemoteDNSIP': remoteDnsIp,
        'DomesticDNSType': domesticDnsType,
        'DomesticDNSDomain': domesticDnsDomain,
        'DomesticDNSIP': domesticDnsIp,
        'Geoipurl': geoipUrl,
        'Geositeurl': geositeUrl,
        'LastUpdated': (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
        'DnsHosts': dnsHosts,
        'DirectSites': directSites,
        'DirectIp': directIp,
        'ProxySites': proxySites,
        'ProxyIp': proxyIp,
        'BlockSites': blockSites,
        'BlockIp': blockIp,
        'DomainStrategy': domainStrategy,
        'FakeDNS': 'false',
      };

  /// Своя схема skipit://, но формат данных тот же, что у Happ — такие ссылки понимают оба клиента.
  String toDeeplink() => 'skipit://routing/add/${base64.encode(utf8.encode(jsonEncode(toHapp())))}';

  Map<String, dynamic> toJson() => {...toHapp(), 'id': id, 'subscriptionId': subscriptionId};

  factory RoutingProfile.fromJson(Map<String, dynamic> j) =>
      RoutingProfile.fromHapp(j, id: j['id'] as String?)..subscriptionId = j['subscriptionId'] as String?;

  static bool isDeeplink(String s) {
    final l = s.trim().toLowerCase();
    return l.startsWith('happ://routing/') || l.startsWith('incy://routing/') || l.startsWith('skipit://routing/');
  }

  static RoutingDeeplink? parseDeeplink(String link) {
    const marker = '://routing/';
    final t = link.trim();
    final idx = t.toLowerCase().indexOf(marker);
    if (idx < 0) return null;
    final rest = t.substring(idx + marker.length);
    if (rest.toLowerCase().startsWith('off')) return RoutingDeeplink(off: true);
    final slash = rest.indexOf('/');
    if (slash <= 0) return null;
    final action = rest.substring(0, slash).toLowerCase();
    final json = tryBase64Decode(urlDecode(rest.substring(slash + 1)));
    if (json == null) return null;
    try {
      final map = jsonDecode(json);
      if (map is! Map<String, dynamic>) return null;
      return RoutingDeeplink(profile: RoutingProfile.fromHapp(map), activate: action == 'onadd');
    } catch (_) {
      return null;
    }
  }
}
