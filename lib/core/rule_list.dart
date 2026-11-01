import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/routing.dart';
import 'net.dart';
import 'paths.dart';

class ParsedRuleList {
  ParsedRuleList({required this.domains, required this.ips, required this.skipped, required this.overLimit});
  final List<String> domains, ips;
  final int skipped;
  final bool overLimit;
  String get text => [...domains, ...ips].join('\n');
}

class RuleList {
  static const maxLines = 200000;
  static const maxBytes = 10 * 1024 * 1024;
  static const maxAge = Duration(days: 7);

  static bool validUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && const ['http', 'https'].contains(uri.scheme) && uri.host.isNotEmpty &&
        uri.userInfo.isEmpty && uri.fragment.isEmpty;
  }

  static bool updateDue(RuleListSource s, {required bool cacheExists, required DateTime now}) =>
      !cacheExists || s.updatedAt == null || now.difference(s.updatedAt!) >= maxAge;

  static bool _ip(String s) => InternetAddress.tryParse(s) != null;
  static bool _cidr(String s) {
    final parts = s.split('/');
    if (parts.length != 2) return false;
    final ip = InternetAddress.tryParse(parts.first);
    final bits = int.tryParse(parts.last);
    return ip != null && bits != null && bits >= 0 && bits <= (ip.type == InternetAddressType.IPv4 ? 32 : 128);
  }

  static bool _domain(String s) => s.length <= 253 && s.contains('.') && s.split('.').every((label) =>
      label.isNotEmpty && label.length <= 63 && !label.startsWith('-') && !label.endsWith('-') &&
      RegExp(r'^[a-zA-Z0-9а-яА-ЯёЁ_-]+$').hasMatch(label));

  static String? _entry(String raw) {
    var s = raw.trim();
    if (_ip(s) || _cidr(s)) return s;
    if (s.startsWith('*.') || s.startsWith('+.')) s = s.substring(2);
    final colon = s.indexOf(':');
    if (colon >= 0) {
      final type = s.substring(0, colon).toLowerCase();
      final value = s.substring(colon + 1);
      if (type == 'domain' || type == 'full') return _domain(value) ? '$type:${value.toLowerCase()}' : null;
      if (type == 'geoip' || type == 'geosite') {
        return RegExp(r'^[a-zA-Z0-9_-]+(?:@[a-zA-Z0-9_-]+)?$').hasMatch(value) ? '$type:$value' : null;
      }
      // Синтаксис выражений Dart и Xray (RE2) различается. Не принимаем удалённые regexp,
      // чтобы одна несовместимая запись не мешала запустить VPN.
      return null;
    }
    return _domain(s) && !RegExp(r'^[0-9.]+$').hasMatch(s) ? 'domain:${s.toLowerCase()}' : null;
  }

  static String? _payload(String s) {
    if ((s.startsWith("'") && s.endsWith("'")) || (s.startsWith('"') && s.endsWith('"'))) {
      s = s.substring(1, s.length - 1);
    }
    final fields = s.split(',').map((e) => e.trim()).toList();
    if (fields.length == 1) return _entry(s);
    if (fields.length > 3 || (fields.length == 3 && fields.last != 'no-resolve')) return null;
    final value = fields[1];
    switch (fields.first.toUpperCase()) {
      case 'DOMAIN': return _entry('full:$value');
      case 'DOMAIN-SUFFIX': return _entry('domain:$value');
      case 'IP-CIDR':
      case 'IP-CIDR6': return _cidr(value) ? value : null;
      case 'GEOIP': return _entry('geoip:${value.toLowerCase()}');
      case 'GEOSITE': return _entry('geosite:$value');
      default: return null;
    }
  }

  static ParsedRuleList parse(String text) {
    final domains = <String>{}, ips = <String>{};
    var skipped = 0, count = 0;
    var payload = false, inPayload = false;
    final lines = const LineSplitter().convert(text.replaceFirst('\uFEFF', ''));
    payload = lines.any((line) => RegExp(r'^payload\s*:\s*(?:#.*)?$').hasMatch(line));
    for (final line in lines) {
      var s = line.trim();
      if (s.isEmpty || s.startsWith('#')) continue;
      if (payload) {
        if (RegExp(r'^payload\s*:').hasMatch(line)) { inPayload = true; continue; }
        if (!inPayload) continue;
        if (!s.startsWith('- ')) { if (!line.startsWith(' ')) inPayload = false; continue; }
        s = s.substring(2).trim();
      }
      s = s.replaceFirst(RegExp(r'\s+#.*$'), '').trim();
      if (++count > maxLines) {
        return ParsedRuleList(domains: domains.toList(), ips: ips.toList(), skipped: skipped, overLimit: true);
      }
      final entry = payload ? _payload(s) : _entry(s);
      if (entry == null) { skipped++; continue; }
      if (_ip(entry) || _cidr(entry) || entry.startsWith('geoip:')) { ips.add(entry); } else { domains.add(entry); }
    }
    return ParsedRuleList(domains: domains.toList(), ips: ips.toList(), skipped: skipped, overLimit: false);
  }

  // Ни адрес, ни id импортированного профиля не используются как путь.
  static String cacheFile(String profileId, String url) {
    var h = BigInt.parse('cbf29ce484222325', radix: 16);
    final mask = (BigInt.one << 64) - BigInt.one;
    for (final byte in utf8.encode('$profileId\u0000$url')) {
      h = ((h ^ BigInt.from(byte)) * BigInt.parse('100000001b3', radix: 16)) & mask;
    }
    return '${h.toRadixString(16).padLeft(16, '0')}.txt';
  }

  static String path(String profileId, String url, {String? dir}) =>
      '${dir ?? AppPaths.ruleListsDir}${Platform.pathSeparator}${cacheFile(profileId, url)}';

  static Future<ParsedRuleList> _parseBytes(Uint8List data) => Isolate.run(() {
    final text = utf8.decode(data).replaceFirst('\uFEFF', '').trimLeft();
    if (text.startsWith('<') || text.startsWith('{') || text.startsWith('[')) {
      throw const FormatException('В ответе нет доменов или IP');
    }
    return parse(text);
  });

  static Future<ParsedRuleList> fetch(String url, {int? proxyPort}) async {
    if (!validUrl(url)) throw const FormatException('Некорректный адрес');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    if (proxyPort != null) {
      client.findProxy = (_) => 'PROXY ${Net.proxyAuth == null ? '' : '${Net.proxyAuth}@'}127.0.0.1:$proxyPort';
    }
    try {
      return await (() async {
        var uri = Uri.parse(url);
        HttpClientResponse? response;
        for (var hop = 0; hop <= 5; hop++) {
          final request = await client.getUrl(uri);
          request.followRedirects = false;
          response = await request.close();
          if (![301, 302, 303, 307, 308].contains(response.statusCode)) break;
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (hop == 5 || location == null) throw const HttpException('Слишком много перенаправлений');
          final next = uri.resolve(location);
          if (!validUrl(next.toString()) || (uri.scheme == 'https' && next.scheme != 'https')) {
            throw const HttpException('Недопустимое перенаправление');
          }
          await response.drain<void>();
          uri = next;
        }
        final res = response!;
        if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
        if (res.contentLength > maxBytes) throw const FormatException('Список больше 10 МБ');
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in res) {
          if (bytes.length + chunk.length > maxBytes) throw const FormatException('Список больше 10 МБ');
          bytes.add(chunk);
        }
        // При автоматической распаковке Content-Length относится к сжатому телу.
        if (res.compressionState != HttpClientResponseCompressionState.decompressed &&
            res.contentLength >= 0 && bytes.length != res.contentLength) {
          throw const HttpException('Файл скачался не полностью');
        }
        final data = bytes.takeBytes();
        final parsed = await _parseBytes(data);
        if (parsed.overLimit) throw const FormatException('В списке больше 200000 строк');
        if (parsed.domains.isEmpty && parsed.ips.isEmpty) throw const FormatException('В ответе нет доменов или IP');
        return parsed;
      })().timeout(const Duration(seconds: 30));
    } finally {
      client.close(force: true);
    }
  }

  static RuleListEntries readEntries(RoutingProfile p, {String? dir, bool strict = false}) {
    final result = RuleListEntries();
    for (final source in p.ruleLists) {
      if (!const ['proxy', 'direct', 'block'].contains(source.action)) continue;
      try {
        final file = File(path(p.id, source.url, dir: dir));
        if (!file.existsSync() || file.lengthSync() > maxBytes) {
          if (strict) throw const FormatException('Сначала загрузите списки в редакторе профиля');
          continue;
        }
        final parsed = parse(file.readAsStringSync());
        if (parsed.overLimit || (parsed.domains.isEmpty && parsed.ips.isEmpty)) {
          if (strict) throw const FormatException('Сначала загрузите списки в редакторе профиля');
          continue;
        }
        switch (source.action) {
          case 'proxy': result.proxyDomains.addAll(parsed.domains); result.proxyIps.addAll(parsed.ips);
          case 'direct': result.directDomains.addAll(parsed.domains); result.directIps.addAll(parsed.ips);
          case 'block': result.blockDomains.addAll(parsed.domains); result.blockIps.addAll(parsed.ips);
        }
      } on FileSystemException { if (strict) rethrow; continue; } on FormatException { if (strict) rethrow; continue; }
    }
    return result;
  }

  static Future<RuleListEntries> readEntriesAsync(RoutingProfile p) {
    final dir = AppPaths.ruleListsDir;
    final json = p.toJson();
    return Isolate.run(() => readEntries(RoutingProfile.fromJson(json), dir: dir, strict: true));
  }

  static bool needsGeo(RoutingProfile p, {String? dir}) => readEntries(p, dir: dir).needsGeo;

  static void cleanOrphans(List<RoutingProfile> profiles, {String? dir}) {
    final directory = Directory(dir ?? AppPaths.ruleListsDir);
    if (!directory.existsSync()) return;
    final live = {for (final p in profiles) for (final s in p.ruleLists) cacheFile(p.id, s.url)};
    for (final file in directory.listSync().whereType<File>()) {
      final name = file.uri.pathSegments.last;
      if (name.endsWith('.txt') && !live.contains(name)) {
        try { file.deleteSync(); } on FileSystemException { /* Повторим при следующей уборке. */ }
      }
    }
  }
}

class RuleListEntries {
  final List<String> proxyDomains = [], proxyIps = [], directDomains = [], directIps = [], blockDomains = [], blockIps = [];
  bool get isEmpty => [proxyDomains, proxyIps, directDomains, directIps, blockDomains, blockIps].every((e) => e.isEmpty);
  bool get needsGeo => [proxyDomains, proxyIps, directDomains, directIps, blockDomains, blockIps]
      .expand((e) => e).any((e) => e.startsWith('geosite:') || e.startsWith('geoip:'));
}
