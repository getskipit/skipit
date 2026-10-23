import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../models/server.dart';
import '../models/settings.dart';
import 'core_manager.dart';
import 'paths.dart';
import 'site_check.dart';
import 'xray_config.dart';

/// Отмена идущей проверки задержки: проверка перестаёт брать новые серверы и останавливает тестовое ядро.
class PingCancel {
  bool cancelled = false;
  final _onCancel = <Future<void> Function()>[];
  final _done = Completer<void>();

  /// Завершается, когда проверку остановили: ожидание чего угодно можно оборвать в этот же момент.
  Future<void> get whenCancelled => _done.future;

  Future<void> cancel() async {
    if (cancelled) return;
    cancelled = true;
    _done.complete();
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
  ///
  /// [cancel] обрывает и уже начатое соединение: сервер, который не отвечает, иначе держал бы
  /// остановленную проверку до конца своего времени ожидания.
  static Future<int> tcp(ServerProfile s, {List<InternetAddress> sources = const [], PingCancel? cancel}) async {
    final sw = Stopwatch()..start();
    final tasks = <ConnectionTask<Socket>>[];
    var over = false;

    // Адрес сервера ищется один раз и только IPv4 (IPv6 — если IPv4 у сервера нет), а соединяемся с
    // карт того же типа. Раньше каждая карта искала адрес сама, в том числе IPv6: при подключённом VPN
    // такие запросы подвешивали поиск адресов Windows на десяток секунд, и с третьей проверки подряд
    // все серверы выходили «Нет».
    Future<int> work() async {
      var targets = <InternetAddress>[];
      final literal = InternetAddress.tryParse(s.address);
      if (literal != null) {
        targets = [literal];
      } else {
        try {
          targets = await InternetAddress.lookup(s.address, type: InternetAddressType.IPv4);
        } catch (_) {}
        if (targets.isEmpty) targets = await InternetAddress.lookup(s.address);
      }
      final pairs = <(InternetAddress, InternetAddress?)>[
        for (final target in targets.take(2))
          if (sources.isEmpty)
            (target, null)
          else
            for (final source in sources)
              if (source.type == target.type) (target, source),
      ];
      if (pairs.isEmpty) return -1;
      final done = Completer<int>();
      var left = pairs.length;
      for (final (target, source) in pairs) {
        unawaited(() async {
          var ms = -1;
          try {
            final task = await Socket.startConnect(target, s.port, sourceAddress: source);
            tasks.add(task);
            if (over) task.cancel();
            final socket = await task.socket;
            socket.destroy();
            if (!over) ms = sw.elapsedMilliseconds;
          } catch (_) {}
          left--;
          if (done.isCompleted) return;
          if (ms >= 0) {
            done.complete(ms);
          } else if (left == 0) {
            done.complete(-1);
          }
        }());
      }
      return done.future;
    }

    // Срок 4 с и отмена действуют на всю попытку, вместе с поиском адреса.
    try {
      final stop = cancel?.whenCancelled.then<int>((_) => -1);
      return await (stop == null ? work() : Future.any([work(), stop])).timeout(const Duration(seconds: 4));
    } catch (_) {
      return -1;
    } finally {
      over = true;
      for (final task in tasks) {
        task.cancel();
      }
    }
  }

  /// Адреса всех сетевых карт, кроме адаптеров с именами [skip] (наш адаптер VPN).
  /// Список карт запоминается на минуту, а одновременные запросы ждут один общий: Windows иногда отвечает
  /// на перечень сетевых карт по 4–10 секунд, и на столько же вставала каждая проверка задержки.
  static Future<List<InternetAddress>> physicalSources(List<String> skip) {
    final key = skip.join('\n');
    final known = _sources;
    if (known != null && known.key == key && DateTime.now().difference(known.at) < const Duration(minutes: 1)) {
      return known.list;
    }
    final list = _listSources(skip);
    _sources = (key: key, at: DateTime.now(), list: list);
    return list;
  }

  static ({String key, DateTime at, Future<List<InternetAddress>> list})? _sources;

  static Future<List<InternetAddress>> _listSources(List<String> skip) async {
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
        final ms = s.isUdpOnly ? -1 : await tcp(s, sources: sources, cancel: cancel);
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
    AppSettings? settings,
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
    final config = jsonEncode(XrayConfig.buildTest(servers, base, settings));
    try {
      final old = File(AppPaths.testConfigFile);
      if (old.existsSync()) await old.delete();
    } catch (_) {}
    final proc = CoreProcess('test', log);
    // Отмена останавливает тестовое ядро — запросы через него сразу обрываются.
    cancel?._onCancel.add(proc.stop);
    try {
      await proc.start(AppPaths.xrayExe, ['run', '-c', 'stdin:'], input: config);
      final ok = await waitForPort(base, alive: () => proc.running && !(cancel?.cancelled ?? false));
      if (cancel?.cancelled ?? false) return;
      if (!ok || !proc.running) return failAll('Xray не запустился для проверки задержки');
      // Результат каждого сервера показывается сразу, как пришёл, — не ждём самый медленный.
      var died = false;
      final indexed = List.generate(servers.length, (i) => i);
      await _pool(indexed, 12, (i) async {
        final ms = await _httpDelay(base + i, testUrl);
        if (cancel?.cancelled ?? false) return;
        // Тестовый Xray умер посреди проверки — ответ получен не от него: такому результату не верим.
        if (!proc.running) died = true;
        onResult(servers[i], died ? -1 : ms);
      }, cancel);
      if (died && !(cancel?.cancelled ?? false)) log.add('test', 'Тестовый Xray завершился во время проверки');
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

  /// Проходит ли UDP через сервер: на каждый сервер — вход временного ядра Xray, который отправляет
  /// пакеты к STUN-серверу Cloudflare через этот сервер (см. [XrayConfig.buildUdpTest]). Результат — время
  /// ответа в мс или -1: UDP через сервер не проходит. Нужно играм, голосовым чатам и звонкам.
  static Future<void> udpAll(
    List<ServerProfile> servers,
    LogBuffer log,
    void Function(ServerProfile, int) onResult, [
    PingCancel? cancel,
    AppSettings? settings,
    String host = XrayConfig.udpTestHost,
    int port = XrayConfig.udpTestPort,
  ]) async {
    if (servers.isEmpty) return;
    // Проверка не состоялась — это не «UDP не проходит»: у серверов отметка [udpFailed].
    void failAll(String why) {
      for (final s in servers) {
        onResult(s, udpFailed);
      }
      log.add('test', why);
    }

    final base = await _freeRange(servers.length);
    if (base == null) return failAll('Нет свободных портов для проверки UDP');
    final config = jsonEncode(XrayConfig.buildUdpTest(servers, base, settings, host: host, port: port));
    final proc = CoreProcess('test', log);
    cancel?._onCancel.add(proc.stop);
    try {
      await proc.start(AppPaths.xrayExe, ['run', '-c', 'stdin:'], input: config);
      final ok = await waitForPort(base, alive: () => proc.running && !(cancel?.cancelled ?? false));
      if (cancel?.cancelled ?? false) return;
      if (!ok || !proc.running) return failAll('Xray не запустился для проверки UDP');
      // Результат каждого сервера — сразу, как он готов. Если ядро проверки завершилось посреди проверки,
      // ответа и не могло быть — такие серверы отмечаются как непроверенные.
      await _pool(List.generate(servers.length, (i) => i), 12, (i) async {
        final ms = await _udpDelay(base + i);
        if (!(cancel?.cancelled ?? false)) onResult(servers[i], proc.running ? ms : udpFailed);
      }, cancel);
      if (!proc.running) log.add('test', 'Тестовый Xray завершился во время проверки UDP');
    } finally {
      await proc.stop();
    }
  }

  /// Отметка «проверить UDP не удалось» ([ServerProfile.udpMs]): ядро проверки не запустилось или завершилось.
  static const udpFailed = -2;

  /// Вывод проверки UDP словами по результатам серверов ([ServerProfile.udpMs]); null — ещё нечего сказать.
  static SiteNote? udpVerdict(List<int?> results) {
    final done = results.whereType<int>().toList();
    if (done.isEmpty || done.length < results.length) return null;
    if (done.contains(udpFailed)) {
      return (
        kind: SiteNoteKind.warn,
        text: 'Проверить UDP${done.every((ms) => ms == udpFailed) ? '' : ' у части серверов'} не удалось: '
            'проверочное ядро не запустилось или завершилось. Подробности — в «Логах»'
      );
    }
    final ok = done.where((ms) => ms >= 0).length;
    final n = done.length;
    if (ok == n) {
      return (kind: SiteNoteKind.ok, text: n == 1 ? 'UDP через сервер проходит' : 'UDP проходит через все серверы ($n)');
    }
    if (ok == 0) {
      return (
        kind: SiteNoteKind.bad,
        text: '${n == 1 ? 'UDP через сервер не проходит' : 'UDP не проходит ни через один сервер'}: в играх, голосовых '
            'чатах и звонках может не быть звука или связи. Если UDP нужен, спросите провайдера, на каких серверах он есть'
      );
    }
    return (
      kind: SiteNoteKind.warn,
      text: 'UDP проходит у $ok из $n серверов. Для игр и звонков выбирайте серверы с зелёной отметкой UDP в списке серверов'
    );
  }

  /// Запрос STUN (Binding Request) на локальный вход [port] и время ответа; -1 — ответа нет.
  /// Первый запрос открывает путь через сервер, второй — честное время; не ответил второй — берётся первый.
  static Future<int> _udpDelay(int port) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final replies = StreamController<List<int>>.broadcast();
    final sub = socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d != null) replies.add(d.data);
    });
    final random = Random();
    Future<int> once() async {
      final tx = List<int>.generate(12, (_) => random.nextInt(256));
      final request = Uint8List(20)
        ..buffer.asByteData().setUint16(0, 0x0001)
        ..buffer.asByteData().setUint32(4, 0x2112A442)
        ..setRange(8, 20, tx);
      final reply = replies.stream.firstWhere((d) =>
          d.length >= 20 &&
          d[0] == 0x01 &&
          d[1] == 0x01 &&
          List.generate(12, (i) => d[8 + i]).join(',') == tx.join(','));
      final sw = Stopwatch()..start();
      socket.send(request, InternetAddress.loopbackIPv4, port);
      await reply.timeout(const Duration(seconds: 5));
      return sw.elapsedMilliseconds;
    }

    try {
      final first = await once();
      try {
        return await once();
      } catch (_) {
        return first;
      }
    } catch (_) {
      return -1;
    } finally {
      await sub.cancel();
      await replies.close();
      socket.close();
    }
  }
}
