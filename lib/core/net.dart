import 'dart:convert';
import 'dart:io';

import '../models/settings.dart';
import 'link_parser.dart';
import 'util.dart';

class FetchedSubscription {
  FetchedSubscription(this.result, this.meta);
  final ImportResult result;
  final Map<String, String> meta;
}

class Net {
  static HttpClient _client(int? proxyPort) {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 5);
    if (proxyPort != null) c.findProxy = (_) => 'PROXY ${proxyAuth == null ? '' : '$proxyAuth@'}127.0.0.1:$proxyPort';
    return c;
  }

  /// «логин:пароль» локального HTTP-порта, когда он закрыт паролем (см. AppSettings.httpAuth).
  static String? proxyAuth;

  /// Загружает подписку. Если пришли простые ссылки, а включено «предпочитать JSON», пробует
  /// тот же адрес с `/json` (так Remnawave-панели отдают полный Xray-конфиг с правилами провайдера).
  static Future<FetchedSubscription> fetchSubscription(
    String url,
    AppSettings settings, {
    int? proxyPort,
  }) async {
    final plain = await _fetch(url, settings, proxyPort: proxyPort);
    final gotJson = plain.result.servers.any((s) => s.isJson);
    if (!settings.preferJson || gotJson || plain.result.servers.isEmpty) return plain;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.path.endsWith('/json')) return plain;
    try {
      final jsonUrl = uri.replace(path: '${uri.path.replaceFirst(RegExp(r'/+$'), '')}/json').toString();
      final json = await _fetch(jsonUrl, settings, proxyPort: proxyPort);
      if (json.result.servers.isNotEmpty && json.result.servers.every((s) => s.isJson)) {
        // Метаданные (трафик, срок, объявление) берём из основного ответа, если в JSON их нет.
        return FetchedSubscription(json.result, {...plain.meta, ...json.meta});
      }
    } catch (_) {
      // Провайдер не поддерживает /json — остаёмся на обычных ссылках.
    }
    return plain;
  }

  static Future<FetchedSubscription> _fetch(
    String url,
    AppSettings settings, {
    int? proxyPort,
  }) async {
    final client = _client(proxyPort);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, settings.userAgent);
      req.headers.set(HttpHeaders.acceptHeader, '*/*');
      if (settings.sendHwid) {
        // Эти заголовки понимают Remnawave/Marzban-подобные панели (лимит устройств).
        req.headers.set('x-hwid', settings.hwid);
        req.headers.set('x-device-os', 'Windows');
        req.headers.set('x-ver-os', Platform.operatingSystemVersion);
        req.headers.set('x-device-model', Platform.localHostname);
      }
      final res = await req.close().timeout(const Duration(seconds: 30));
      // Тело читаем тоже с ограничением: оборвавшееся соединение иначе «висело» бы бесконечно.
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
      if (res.statusCode >= 400) throw ServerRefused(res.statusCode);

      final meta = <String, String>{};
      res.headers.forEach((name, values) => meta[name.toLowerCase()] = values.join(','));

      var text = body.trim();
      if (!text.contains('://') && !text.startsWith('[') && !text.startsWith('{')) {
        text = tryBase64Decode(text) ?? text;
      }
      // Метаданные внутри тела: `#profile-title: Name`, `#announce: ...` и т.п.
      for (final line in splitLines(text)) {
        if (!line.startsWith('#')) continue;
        final m = RegExp(r'^#\s*([\w-]+)\s*:\s*(.*)$').firstMatch(line);
        if (m != null) meta.putIfAbsent(m.group(1)!.toLowerCase(), () => m.group(2)!.trim());
      }
      return FetchedSubscription(LinkParser.parseText(text), meta);
    } finally {
      client.close(force: true);
    }
  }

  /// Проверка связи через VPN: запрашивает служебную страницу Cloudflare через локальный вход ядра
  /// и возвращает код страны, откуда пришёл запрос (`fi`), или null, если страна в ответе не указана.
  /// Нет ответа — исключение.
  static Future<String?> exitCountry(String host, int proxyPort) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
    try {
      final req = await client.getUrl(Uri.parse('https://$host/cdn-cgi/trace')).timeout(const Duration(seconds: 5));
      final res = await req.close().timeout(const Duration(seconds: 5));
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 5));
      if (res.statusCode >= 400) throw HttpException('Сервер ответил ${res.statusCode}');
      return RegExp(r'^loc=([A-Za-z]{2})\s*$', multiLine: true).firstMatch(body)?.group(1)?.toLowerCase();
    } finally {
      client.close(force: true);
    }
  }

  /// [onProgress] — сколько байт уже получено и сколько всего (-1, если сервер не сообщил размер).
  static Future<void> download(String url, String path,
      {int? proxyPort, void Function(int received, int total)? onProgress}) async {
    final client = _client(proxyPort);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode >= 400) throw HttpException('HTTP ${res.statusCode} при загрузке $url');
      final tmp = File('$path.part');
      final sink = tmp.openWrite();
      var received = 0;
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, res.contentLength);
        }
      } finally {
        await sink.close();
      }
      await tmp.rename(path);
    } finally {
      client.close(force: true);
    }
  }
}
