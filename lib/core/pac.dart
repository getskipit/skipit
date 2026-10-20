import 'dart:convert';
import 'dart:io';

import 'windows.dart';

/// Файл автонастройки прокси (PAC) для режима «Смешанный». В Windows записывается только его адрес, а
/// «ручной» прокси остаётся выключенным: браузеры и программы на WinINET / WinHTTP берут прокси из файла, а
/// программы, которые читают только «ручной» прокси (например, игры на Python — Мир танков), его не видят и
/// идут через адаптер, где действуют правила по программам. Если SkipIt закрылась аварийно, файла нет —
/// Windows идёт напрямую, а не в мёртвый прокси.
class PacServer {
  PacServer._(this._server, this.url);

  final HttpServer _server;

  /// Адрес файла для настроек Windows (AutoConfigURL).
  final String url;

  static const path = '/skipit.pac';

  /// Свой файл в настройках Windows: адрес на этом компьютере с нашим именем файла.
  static bool isOwn(String url) => RegExp('^http://127\\.0\\.0\\.1:\\d+${RegExp.escape(path)}').hasMatch(url);

  /// Порт сервера из адреса нашего файла; null — адрес не наш.
  static int? portOf(String url) =>
      isOwn(url) ? int.tryParse(RegExp(r'^http://127\.0\.0\.1:(\d+)').firstMatch(url)!.group(1)!) : null;

  /// Сервер на свободном порту 127.0.0.1, отдаёт [script] на любой запрос.
  static Future<PacServer> start(String script) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) {
      r.response.headers.contentType = ContentType('application', 'x-ns-proxy-autoconfig', charset: 'utf-8');
      r.response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      r.response.write(script);
      r.response.close();
    });
    // Windows и браузеры запоминают файл по адресу — у каждого подключения он свой.
    final tag = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    return PacServer._(server, 'http://127.0.0.1:${server.port}$path?$tag');
  }

  Future<void> stop() => _server.close(force: true);

  /// Текст файла: всё через HTTP-порт ядра [httpPort], кроме «Исключений системного прокси» [bypass]
  /// (пусто — стандартный список). Исключения — в том же виде, что у Windows: «*.example;192.168.*;<local>».
  static String script(int httpPort, String bypass) {
    final conditions = <String>[];
    for (final raw in (bypass.isEmpty ? WinSys.defaultProxyBypass : bypass).split(RegExp(r'[;,\s]+'))) {
      final item = raw.trim().toLowerCase();
      if (item.isEmpty) continue;
      conditions.add(item == '<local>' ? 'isPlainHostName(host)' : 'shExpMatch(host, ${jsonEncode(item)})');
    }
    final direct = conditions.isEmpty ? '' : '  if (${conditions.join(' ||\n      ')}) return "DIRECT";\n';
    return 'function FindProxyForURL(url, host) {\n'
        '  host = host.toLowerCase();\n'
        '$direct'
        '  return "PROXY 127.0.0.1:$httpPort";\n'
        '}\n';
  }
}
