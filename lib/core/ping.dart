import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/server.dart';
import 'core_manager.dart';
import 'paths.dart';
import 'xray_config.dart';

/// Отмена идущей проверки задержки: проверка перестаёт брать новые серверы и останавливает тестовое ядро.
class PingCancel {
  bool cancelled = false;
  final _onCancel = <Future<void> Function()>[];

  Future<void> cancel() async {
    if (cancelled) return;
    cancelled = true;
    for (final f in _onCancel) {
      await f();
    }
  }
}

class Pinger {
  static const _basePort = 20800;
  static const _timeout = Duration(seconds: 6);

  /// TCP-рукопожатие с сервером. -1 — недоступен.
  ///
  /// [sources] — адреса настоящих сетевых карт (см. [physicalSources]). Нужны, пока подключён VPN с
  /// адаптером: обычное соединение ушло бы в адаптер, а он отвечает на рукопожатие сам и мгновенно —
  /// получилось бы «0 мс» у любого сервера. Соединение, привязанное к адресу сетевой карты, Windows
  /// отправляет через неё. Карт может быть несколько — берётся первая, через которую сервер ответил.
  static Future<int> tcp(ServerProfile s, {List<InternetAddress> sources = const []}) async {
    Future<int> attempt(InternetAddress? source) async {
      final sw = Stopwatch()..start();
      try {
        final socket =
            await Socket.connect(s.address, s.port, sourceAddress: source, timeout: const Duration(seconds: 4));
        socket.destroy();
        return sw.elapsedMilliseconds;
      } catch (_) {
        return -1;
      }
    }

    if (sources.isEmpty) return attempt(null);
    final done = Completer<int>();
    var left = sources.length;
    for (final source in sources) {
      unawaited(attempt(source).then((ms) {
        left--;
        if (done.isCompleted) return;
        if (ms >= 0) {
          done.complete(ms);
        } else if (left == 0) {
          done.complete(-1);
        }
      }));
    }
    return done.future;
  }

  /// Адреса всех сетевых карт, кроме адаптеров с именами [skip] (наш адаптер VPN).
  static Future<List<InternetAddress>> physicalSources(List<String> skip) async {
    try {
      final all = await NetworkInterface.list(type: InternetAddressType.any);
      return [
        for (final i in all)
          if (!skip.contains(i.name)) ...i.addresses.where((a) => !a.isLoopback && !a.isLinkLocal),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _pool<T>(List<T> items, int concurrency, Future<void> Function(T) fn, [PingCancel? cancel]) async {
    var index = 0;
    Future<void> worker() async {
      while (index < items.length && !(cancel?.cancelled ?? false)) {
        final item = items[index++];
        await fn(item);
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
  }

  static Future<void> tcpAll(List<ServerProfile> servers, void Function(ServerProfile, int) onResult,
          [PingCancel? cancel, List<InternetAddress> sources = const []]) =>
      _pool(servers, 24, (s) async {
        final ms = s.isUdpOnly ? -1 : await tcp(s, sources: sources);
        if (!(cancel?.cancelled ?? false)) onResult(s, ms);
      }, cancel);

  /// Реальная задержка: запрос testUrl через каждый сервер (отдельный процесс Xray на время теста).
  /// Ищет диапазон из [count] свободных локальных портов, чтобы не попасть в чужой процесс
  /// (например, в зависший тестовый Xray с прошлого раза).
  static Future<int?> _freeRange(int count) async {
    for (var base = _basePort; base < _basePort + 2000; base += count + 7) {
      final taken = <ServerSocket>[];
      var ok = true;
      for (var p = base; p < base + count; p++) {
        try {
          taken.add(await ServerSocket.bind(InternetAddress.loopbackIPv4, p));
        } catch (_) {
          ok = false;
          break;
        }
      }
      for (final s in taken) {
        await s.close();
      }
      if (ok) return base;
    }
    return null;
  }

  static Future<void> realDelayAll(
    List<ServerProfile> servers,
    String testUrl,
    LogBuffer log,
    void Function(ServerProfile, int) onResult, [
    PingCancel? cancel,
  ]) async {
    if (servers.isEmpty) return;
    void failAll(String why) {
      for (final s in servers) {
        onResult(s, -1);
      }
      log.add('test', why);
    }

    final base = await _freeRange(servers.length);
    if (base == null) return failAll('Нет свободных портов для проверки задержки');
    // Конфиг проверки (в нём адреса и ключи серверов) ядро получает напрямую, без файла на диске.
    final config = jsonEncode(XrayConfig.buildTest(servers, base));
    try {
      final old = File(AppPaths.testConfigFile);
      if (old.existsSync()) await old.delete();
    } catch (_) {}
    final proc = CoreProcess('test', log);
    // Отмена останавливает тестовое ядро — запросы через него сразу обрываются.
    cancel?._onCancel.add(proc.stop);
    try {
      await proc.start(AppPaths.xrayExe, ['run', '-c', 'stdin:'], input: config);
      final ok = await waitForPort(base, alive: () => proc.running);
      if (cancel?.cancelled ?? false) return;
      if (!ok || !proc.running) return failAll('Xray не запустился для проверки задержки');
      final results = List<int>.filled(servers.length, -1);
      final indexed = List.generate(servers.length, (i) => i);
      await _pool(indexed, 12, (i) async {
        results[i] = await _httpDelay(base + i, testUrl);
      }, cancel);
      if (cancel?.cancelled ?? false) return;
      // Если тестовый Xray умер посреди проверки, ответы получены не от него — результатам не верим.
      if (!proc.running) return failAll('Тестовый Xray завершился во время проверки');
      for (var i = 0; i < servers.length; i++) {
        onResult(servers[i], results[i]);
      }
    } finally {
      await proc.stop();
    }
  }

  static Future<int> _httpDelay(int port, String url) async {
    final client = HttpClient()
      ..findProxy = ((_) => 'PROXY 127.0.0.1:$port')
      ..connectionTimeout = _timeout;
    try {
      Future<int> once() async {
        final sw = Stopwatch()..start();
        final req = await client.getUrl(Uri.parse(url));
        final res = await req.close();
        await res.drain<void>();
        // Ответ с ошибкой (например, прокси сразу вернул 5xx) — это не «быстрый сервер», а недоступность.
        if (res.statusCode >= 400) throw HttpException('HTTP ${res.statusCode}');
        return sw.elapsedMilliseconds;
      }

      // Первый запрос прогревает соединение (TLS/Reality-рукопожатие), второй — честная задержка.
      final first = await once().timeout(_timeout);
      try {
        return await once().timeout(_timeout);
      } catch (_) {
        return first;
      }
    } catch (_) {
      return -1;
    } finally {
      client.close(force: true);
    }
  }
}
