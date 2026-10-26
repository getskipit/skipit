import 'dart:convert';
import 'dart:io';

import '../models/routing.dart';
import '../models/server.dart';
import 'util.dart';
import '../l10n/l10n.dart';

/// Что удалось вытащить из вставленного текста / тела подписки.
class ImportResult {
  final servers = <ServerProfile>[];
  final subscriptionUrls = <String>[];
  final routing = <RoutingDeeplink>[];
  final errors = <String>[];

  bool get isEmpty => servers.isEmpty && subscriptionUrls.isEmpty && routing.isEmpty;
}

class _Link {
  _Link(this.scheme, this.user, this.host, this.port, this.query, this.name);

  final String scheme;
  final String user;
  final String host;
  final int port;
  final Map<String, String> query;
  final String name;

  String q(String key, [String fallback = '']) {
    final v = query[key];
    return v == null || v.isEmpty ? fallback : v;
  }
}

class LinkParser {
  static const proxySchemes = ['vless', 'vmess', 'trojan', 'ss', 'socks', 'socks5', 'hysteria2', 'hy2'];
  static const appSchemes = ['happ', 'incy', 'skipit', 'v2raytun', 'v2rayng', 'streisand'];

  /// Разбирает произвольный текст: ссылки, base64-подписку, JSON Xray, URL подписки, диплинки.
  static ImportResult parseText(String text) {
    final result = ImportResult();
    final trimmed = text.trim();
    if (trimmed.isEmpty) return result;

    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      _parseJsonConfigs(trimmed, result);
      if (!result.isEmpty || result.errors.isNotEmpty) return result;
    }

    var lines = splitLines(trimmed);
    // Целиком base64 (типичная подписка v2ray).
    if (lines.length == 1 && !lines.first.contains('://')) {
      final decoded = tryBase64Decode(lines.first);
      if (decoded != null && (decoded.contains('://') || decoded.trimLeft().startsWith('['))) {
        return parseText(decoded);
      }
    }

    for (final line in lines) {
      if (line.startsWith('#') || line.startsWith('//')) continue;
      _parseLine(line, result);
    }
    return result;
  }

  static void _parseLine(String line, ImportResult result) {
    final idx = line.indexOf('://');
    if (idx <= 0) {
      final decoded = tryBase64Decode(line);
      if (decoded != null && decoded.contains('://')) {
        for (final l in splitLines(decoded)) {
          _parseLine(l, result);
        }
      } else {
        result.errors.add(tr('Не распознано: {0}', [_short(line)]));
      }
      return;
    }
    final scheme = line.substring(0, idx).toLowerCase();

    if (scheme == 'http' || scheme == 'https') {
      result.subscriptionUrls.add(line);
      return;
    }
    if (appSchemes.contains(scheme)) {
      _parseAppDeeplink(line, scheme, result);
      return;
    }
    try {
      final server = parseLink(line);
      if (server != null) {
        result.servers.add(server);
      } else {
        result.errors.add(tr('Неподдерживаемый протокол: {0}', [scheme]));
      }
    } catch (e) {
      result.errors.add(tr('Ошибка в ссылке {0}: {1}', [_short(line), e]));
    }
  }

  static void _parseAppDeeplink(String line, String scheme, ImportResult result) {
    if (RoutingProfile.isDeeplink(line) || line.toLowerCase().contains('://routing/')) {
      final r = RoutingProfile.parseDeeplink(line);
      r == null ? result.errors.add(tr('Некорректный профиль маршрутизации')) : result.routing.add(r);
      return;
    }
    final rest = line.substring(scheme.length + 3);
    final lower = rest.toLowerCase();
    if (lower.startsWith('crypt')) {
      result.errors.add(
          tr('Зашифрованные ссылки {0}://crypt… привязаны к ключам самого Happ и не могут быть открыты '
          'другими клиентами. Попросите у провайдера обычную ссылку на подписку.', [scheme]));
      return;
    }
    for (final prefix in ['add/', 'import/', 'install-config?url=', 'install-sub?url=', 'sub/', 'subscription/']) {
      if (lower.startsWith(prefix)) {
        final payload = urlDecode(rest.substring(prefix.length)).split('#').first.trim();
        if (payload.startsWith('http')) {
          result.subscriptionUrls.add(payload);
        } else {
          final nested = parseText(payload);
          result.servers.addAll(nested.servers);
          result.subscriptionUrls.addAll(nested.subscriptionUrls);
          result.errors.addAll(nested.errors);
        }
        return;
      }
    }
    result.errors.add(tr('Неизвестный диплинк: {0}', [_short(line)]));
  }

  /// Кусок строки для сообщения об ошибке. У ссылок показываем только вид (`vless://…`):
  /// дальше идут ключи доступа к серверу, им не место в сообщениях и журнале.
  static String _short(String s) {
    final scheme = RegExp(r'^[a-zA-Z][\w+.-]*://').firstMatch(s);
    if (scheme != null) return '${scheme.group(0)}…';
    return s.length > 60 ? '${s.substring(0, 60)}…' : s;
  }

  // ---------------------------------------------------------------------------
  // JSON-конфиги Xray (Happ/Remnawave отдают массив полных конфигов)
  // ---------------------------------------------------------------------------

  static void _parseJsonConfigs(String text, ImportResult result) {
    Object? data;
    try {
      data = jsonDecode(text);
    } catch (_) {
      return;
    }
    final configs = data is List ? data : [data];
    for (final c in configs) {
      if (c is! Map<String, dynamic>) continue;
      final outbounds = (c['outbounds'] as List?)?.whereType<Map<String, dynamic>>().toList();
      if (outbounds == null) {
        // Может быть одиночный outbound.
        if (c['protocol'] is String) _addOutbound(c, c['tag']?.toString() ?? 'JSON', text, result);
        continue;
      }
      final proxy = outbounds.firstWhere(
        (o) => o['tag'] == 'proxy',
        orElse: () => outbounds.firstWhere(
          (o) => !const ['freedom', 'blackhole', 'dns', 'loopback'].contains(o['protocol']),
          orElse: () => const {},
        ),
      );
      if (proxy.isEmpty) {
        result.errors.add(tr('В JSON-конфиге нет прокси-outbound'));
        continue;
      }
      _addOutbound(proxy, c['remarks']?.toString() ?? tr('JSON-конфиг'), jsonEncode(c), result);
    }
  }

  static void _addOutbound(Map<String, dynamic> o, String name, String link, ImportResult result) {
    final out = deepCopyMap(o)..remove('tag');
    final protocol = out['protocol']?.toString() ?? '';
    var address = '';
    var port = 0;
    final settings = out['settings'];
    if (settings is Map) {
      final list = (settings['vnext'] ?? settings['servers']) as List?;
      final first = list != null && list.isNotEmpty ? list.first as Map : settings;
      address = first['address']?.toString() ?? '';
      port = asInt(first['port']) ?? 0;
    }
    result.servers.add(ServerProfile(
        name: name, protocol: protocol, address: address, port: port, link: link, outbound: out));
  }

  // ---------------------------------------------------------------------------
  // Прокси-ссылки
  // ---------------------------------------------------------------------------

  static ServerProfile? parseLink(String link) {
    final scheme = link.substring(0, link.indexOf('://')).toLowerCase();
    return switch (scheme) {
      'vless' => _vless(link),
      'vmess' => _vmess(link),
      'trojan' => _trojan(link),
      'ss' => _shadowsocks(link),
      'socks' || 'socks5' => _socks(link),
      'hysteria2' || 'hy2' => _hysteria2(link),
      _ => null,
    };
  }

  static _Link _split(String link) {
    var s = link.trim();
    var name = '';
    final hash = s.indexOf('#');
    if (hash >= 0) {
      name = urlDecode(s.substring(hash + 1)).trim();
      s = s.substring(0, hash);
    }
    final schemeEnd = s.indexOf('://');
    final scheme = s.substring(0, schemeEnd).toLowerCase();
    s = s.substring(schemeEnd + 3);

    final query = <String, String>{};
    final qi = s.indexOf('?');
    if (qi >= 0) {
      for (final part in s.substring(qi + 1).split('&')) {
        if (part.isEmpty) continue;
        final eq = part.indexOf('=');
        final k = eq < 0 ? part : part.substring(0, eq);
        final v = eq < 0 ? '' : part.substring(eq + 1);
        query[urlDecode(k)] = urlDecode(v.replaceAll('+', '%20'));
      }
      s = s.substring(0, qi);
    }
    if (s.endsWith('/')) s = s.substring(0, s.length - 1);

    var user = '';
    final at = s.lastIndexOf('@');
    if (at >= 0) {
      user = urlDecode(s.substring(0, at));
      s = s.substring(at + 1);
    }

    String host;
    var port = 0;
    if (s.startsWith('[')) {
      final end = s.indexOf(']');
      host = s.substring(1, end);
      final rest = s.substring(end + 1);
      if (rest.startsWith(':')) port = int.tryParse(rest.substring(1)) ?? 0;
    } else {
      final colon = s.lastIndexOf(':');
      if (colon >= 0) {
        host = s.substring(0, colon);
        port = int.tryParse(s.substring(colon + 1).split('/').first) ?? 0;
      } else {
        host = s;
      }
    }
    if (host.isEmpty) throw FormatException(tr('нет адреса сервера'));
    if (port <= 0 || port > 65535) throw FormatException(tr('некорректный порт'));
    return _Link(scheme, user, host, port, query, name);
  }

  static String _nameOr(_Link l) => l.name.isNotEmpty ? l.name : '${l.host}:${l.port}';

  /// streamSettings для транспорта и шифрования (общие для VLESS / VMess / Trojan).
  static Map<String, dynamic> _stream({
    required String network,
    required String security,
    String host = '',
    String path = '',
    String headerType = '',
    String serviceName = '',
    String mode = '',
    String sni = '',
    String fp = '',
    String alpn = '',
    bool insecure = false,
    String pbk = '',
    String sid = '',
    String spx = '',
    String pqv = '',
    String extra = '',
    String seed = '',
    String authority = '',
    String ech = '',
    String pcs = '',
    String vcn = '',
    String fm = '',
    List<String>? warnings,
  }) {
    var net = network.toLowerCase();
    if (net.isEmpty || net == 'tcp') net = 'raw';
    if (net == 'splithttp') net = 'xhttp';
    if (net == 'h2' || net == 'http') {
      warnings?.add(tr('Транспорт HTTP/2 удалён из Xray, используется XHTTP'));
      net = 'xhttp';
    }
    final stream = <String, dynamic>{'network': net};

    switch (net) {
      case 'raw':
        if (headerType == 'http') {
          stream['rawSettings'] = {
            'header': {
              'type': 'http',
              'request': {
                'path': [path.isEmpty ? '/' : path],
                if (host.isNotEmpty) 'headers': {'Host': host.split(',').map((e) => e.trim()).toList()},
              },
            },
          };
        }
      case 'ws':
        stream['wsSettings'] = {'path': path.isEmpty ? '/' : path, if (host.isNotEmpty) 'host': host};
      case 'httpupgrade':
        stream['httpupgradeSettings'] = {'path': path.isEmpty ? '/' : path, if (host.isNotEmpty) 'host': host};
      case 'grpc':
        stream['grpcSettings'] = {
          'serviceName': serviceName.isNotEmpty ? serviceName : path,
          'multiMode': mode == 'multi',
          if (authority.isNotEmpty) 'authority': authority,
        };
      case 'xhttp':
        Map<String, dynamic>? extraMap;
        if (extra.isNotEmpty) {
          try {
            extraMap = jsonDecode(extra) as Map<String, dynamic>;
          } catch (_) {
            warnings?.add(tr('Не удалось разобрать параметр extra'));
          }
        }
        stream['xhttpSettings'] = {
          'path': path.isEmpty ? '/' : path,
          if (host.isNotEmpty) 'host': host,
          'mode': mode.isEmpty ? 'auto' : mode,
          if (extraMap != null) 'extra': extraMap,
        };
      case 'kcp' || 'mkcp':
        stream['network'] = 'kcp';
        stream['kcpSettings'] = {
          'header': {'type': headerType.isEmpty ? 'none' : headerType},
          if (seed.isNotEmpty) 'seed': seed,
        };
      default:
        warnings?.add(tr('Неизвестный транспорт: {0}', [net]));
    }

    // Finalmask — маскировка трафика поверх транспорта (параметр fm, JSON).
    if (fm.isNotEmpty) {
      try {
        stream['finalmask'] = jsonDecode(fm) as Map<String, dynamic>;
      } catch (_) {
        warnings?.add(tr('Не удалось разобрать параметр fm'));
      }
    }

    final alpnList = alpn.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    switch (security.toLowerCase()) {
      case 'tls':
        stream['security'] = 'tls';
        stream['tlsSettings'] = {
          if (sni.isNotEmpty) 'serverName': sni,
          'fingerprint': fp.isEmpty ? 'chrome' : fp,
          if (alpnList.isNotEmpty) 'alpn': alpnList,
          if (ech.isNotEmpty) 'echConfigList': ech,
          ...tlsTrust(insecure: insecure, pcs: pcs, vcn: vcn, warnings: warnings),
        };
      case 'reality':
        stream['security'] = 'reality';
        stream['realitySettings'] = {
          'serverName': sni,
          'fingerprint': fp.isEmpty ? 'chrome' : fp,
          'publicKey': pbk,
          'shortId': sid,
          if (spx.isNotEmpty) 'spiderX': spx,
          if (pqv.isNotEmpty) 'mldsa65Verify': pqv,
        };
      default:
        stream['security'] = 'none';
    }
    return stream;
  }

  /// Проверка сертификата сервера. Xray 26 убрал `allowInsecure` (с ним ядро не запускается):
  /// вместо отключения проверки сертификат закрепляют по отпечатку (pcs) или имени (vcn).
  static Map<String, dynamic> tlsTrust({required bool insecure, String pcs = '', String vcn = '', List<String>? warnings}) {
    if (insecure && pcs.isEmpty && vcn.isEmpty) {
      warnings?.add(tr('Ссылка просит не проверять сертификат (allowInsecure) — Xray это больше не поддерживает. '
          'Если у сервера самоподписанный сертификат, подключиться не получится: попросите у провайдера новую ссылку'));
    }
    return {
      if (pcs.isNotEmpty) 'pinnedPeerCertSha256': pcs,
      if (vcn.isNotEmpty) 'verifyPeerCertByName': vcn,
    };
  }

  static Map<String, dynamic> _streamFromQuery(_Link l, String defaultSecurity, List<String> warnings) => _stream(
        network: l.q('type', 'tcp'),
        security: l.q('security', defaultSecurity),
        host: l.q('host'),
        path: l.q('path'),
        headerType: l.q('headerType'),
        serviceName: l.q('serviceName'),
        mode: l.q('mode'),
        sni: l.q('sni', l.q('peer')),
        fp: l.q('fp'),
        alpn: l.q('alpn'),
        insecure: parseBool(l.q('allowInsecure', l.q('insecure'))),
        pbk: l.q('pbk'),
        sid: l.q('sid'),
        spx: l.q('spx'),
        pqv: l.q('pqv'),
        extra: l.q('extra'),
        seed: l.q('seed'),
        authority: l.q('authority'),
        ech: l.q('ech'),
        pcs: l.q('pcs'),
        vcn: l.q('vcn'),
        fm: l.q('fm'),
        warnings: warnings,
      );

  static ServerProfile _vless(String link) {
    final l = _split(link);
    final warnings = <String>[];
    final flow = l.q('flow');
    final stream = _streamFromQuery(l, 'none', warnings);
    if (stream['security'] == 'none' && l.q('encryption', 'none') == 'none' && !_isPrivateHost(l.host)) {
      warnings.add(tr('VLESS без шифрования (TLS/REALITY) — Xray запрещает такие подключения к серверам в интернете'));
    }
    return ServerProfile(
      name: _nameOr(l),
      protocol: 'vless',
      address: l.host,
      port: l.port,
      link: link,
      warning: warnings.isEmpty ? null : warnings.join('; '),
      outbound: {
        'protocol': 'vless',
        'settings': {
          'vnext': [
            {
              'address': l.host,
              'port': l.port,
              'users': [
                {'id': l.user, 'encryption': l.q('encryption', 'none'), if (flow.isNotEmpty) 'flow': flow},
              ],
            },
          ],
        },
        'streamSettings': stream,
      },
    );
  }

  /// Адрес в локальной сети (для него Xray разрешает VLESS без шифрования).
  static bool _isPrivateHost(String host) {
    final ip = InternetAddress.tryParse(host);
    if (ip == null) return host == 'localhost' || !host.contains('.');
    if (ip.isLoopback || ip.isLinkLocal) return true;
    final b = ip.rawAddress;
    if (b.length != 4) return b[0] & 0xfe == 0xfc;
    return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] < 32) || (b[0] == 192 && b[1] == 168);
  }

  static ServerProfile _vmess(String link) {
    final body = link.substring(8).split('#').first;
    final decoded = tryBase64Decode(body);
    if (decoded == null || !decoded.trimLeft().startsWith('{')) {
      // Формат в стиле VLESS: vmess://uuid@host:port?...
      final l = _split(link);
      final warnings = <String>[];
      return ServerProfile(
        name: _nameOr(l),
        protocol: 'vmess',
        address: l.host,
        port: l.port,
        link: link,
        outbound: {
          'protocol': 'vmess',
          'settings': {
            'vnext': [
              {
                'address': l.host,
                'port': l.port,
                'users': [
                  {'id': l.user, 'security': l.q('encryption', 'auto')}
                ],
              },
            ],
          },
          'streamSettings': _streamFromQuery(l, 'none', warnings),
        },
      );
    }
    final j = jsonDecode(decoded) as Map<String, dynamic>;
    String s(String k) => j[k]?.toString().trim() ?? '';
    final warnings = <String>[];
    final host = s('add');
    final port = asInt(j['port']) ?? 0;
    final net = s('net');
    return ServerProfile(
      name: s('ps').isNotEmpty ? s('ps') : '$host:$port',
      protocol: 'vmess',
      address: host,
      port: port,
      link: link,
      outbound: {
        'protocol': 'vmess',
        'settings': {
          'vnext': [
            {
              'address': host,
              'port': port,
              'users': [
                {'id': s('id'), 'security': s('scy').isEmpty ? 'auto' : s('scy')}
              ],
            },
          ],
        },
        'streamSettings': _stream(
          network: net,
          security: s('tls'),
          host: s('host'),
          path: s('path'),
          headerType: s('type'),
          serviceName: net == 'grpc' ? s('path') : '',
          mode: net == 'grpc' ? s('type') : s('mode'),
          sni: s('sni'),
          fp: s('fp'),
          alpn: s('alpn'),
          insecure: parseBool(j['allowInsecure'] ?? j['insecure']),
          seed: net == 'kcp' ? s('path') : '',
          warnings: warnings,
        ),
      },
      warning: warnings.isEmpty ? null : warnings.join('; '),
    );
  }

  static ServerProfile _trojan(String link) {
    final l = _split(link);
    final warnings = <String>[];
    return ServerProfile(
      name: _nameOr(l),
      protocol: 'trojan',
      address: l.host,
      port: l.port,
      link: link,
      outbound: {
        'protocol': 'trojan',
        'settings': {
          'servers': [
            {'address': l.host, 'port': l.port, 'password': l.user}
          ],
        },
        'streamSettings': _streamFromQuery(l, 'tls', warnings),
      },
      warning: warnings.isEmpty ? null : warnings.join('; '),
    );
  }

  static ServerProfile _shadowsocks(String link) {
    var body = link.substring(5);
    var name = '';
    final hash = body.indexOf('#');
    if (hash >= 0) {
      name = urlDecode(body.substring(hash + 1));
      body = body.substring(0, hash);
    }
    String? warning;
    final qi = body.indexOf('?');
    if (qi >= 0) {
      if (body.substring(qi).contains('plugin=')) warning = tr('Плагины Shadowsocks не поддерживаются');
      body = body.substring(0, qi);
    }
    if (body.endsWith('/')) body = body.substring(0, body.length - 1);

    // Старый формат: base64(method:password@host:port)
    if (!body.contains('@')) {
      final d = tryBase64Decode(body);
      if (d == null) throw FormatException(tr('некорректный ss://'));
      body = d;
      final at = body.lastIndexOf('@');
      body = '${base64Url.encode(utf8.encode(body.substring(0, at)))}@${body.substring(at + 1)}';
    }
    final l = _split('ss://$body');
    var userInfo = l.user;
    if (!userInfo.contains(':')) userInfo = tryBase64Decode(userInfo) ?? userInfo;
    final colon = userInfo.indexOf(':');
    if (colon < 0) throw FormatException(tr('нет метода шифрования'));
    final method = userInfo.substring(0, colon);
    final password = userInfo.substring(colon + 1);
    return ServerProfile(
      name: name.isNotEmpty ? name : '${l.host}:${l.port}',
      protocol: 'shadowsocks',
      address: l.host,
      port: l.port,
      link: link,
      warning: warning,
      outbound: {
        'protocol': 'shadowsocks',
        'settings': {
          'servers': [
            {'address': l.host, 'port': l.port, 'method': method, 'password': password}
          ],
        },
      },
    );
  }

  static ServerProfile _socks(String link) {
    final l = _split(link);
    var user = l.user;
    if (user.isNotEmpty && !user.contains(':')) user = tryBase64Decode(user) ?? user;
    final parts = user.split(':');
    return ServerProfile(
      name: _nameOr(l),
      protocol: 'socks',
      address: l.host,
      port: l.port,
      link: link,
      outbound: {
        'protocol': 'socks',
        'settings': {
          'servers': [
            {
              'address': l.host,
              'port': l.port,
              if (user.isNotEmpty)
                'users': [
                  {'user': parts.first, 'pass': parts.length > 1 ? parts.sublist(1).join(':') : ''}
                ],
            },
          ],
        },
      },
    );
  }

  /// Hysteria2 в Xray-core (протокол `hysteria`, версия 2) — требуется свежее ядро.
  static ServerProfile _hysteria2(String link) {
    final l = _split(link);
    final warnings = <String>[];
    if (l.q('obfs').isNotEmpty) warnings.add(tr('Обфускация {0} может не поддерживаться ядром', [l.q('obfs')]));
    final sni = l.q('sni', l.q('peer'));
    // В ссылках Hysteria отпечаток пишут как pinSHA256, часто с двоеточиями.
    final pin = l.q('pcs', l.q('pinSHA256')).replaceAll(':', '');
    return ServerProfile(
      name: _nameOr(l),
      protocol: 'hysteria',
      address: l.host,
      port: l.port,
      link: link,
      warning: warnings.isEmpty ? null : warnings.join('; '),
      outbound: {
        'protocol': 'hysteria',
        'settings': {'version': 2, 'address': l.host, 'port': l.port},
        'streamSettings': {
          'network': 'hysteria',
          'hysteriaSettings': {'version': 2, 'auth': l.user},
          'security': 'tls',
          'tlsSettings': {
            'serverName': sni.isNotEmpty ? sni : l.host,
            'alpn': ['h3'],
            ...tlsTrust(insecure: parseBool(l.q('insecure')), pcs: pin, vcn: l.q('vcn'), warnings: warnings),
          },
        },
      },
    );
  }
}
