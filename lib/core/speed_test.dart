import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'site_check.dart';

/// Итог замера: скорость или ошибка; [unreachable] — сервер замера не ответил (тогда берётся
/// следующий из [SpeedTest.servers]); [host] — с какого сервера качался файл.
typedef SpeedResult = ({double? mbit, String? error, bool unreachable, String host});
typedef SpeedServer = ({String host, String path});
typedef SpeedProgress = void Function(double mbit, double done);

/// Замер скорости скачивания: один и тот же файл через VPN и напрямую.
class SpeedReport {
  bool done = false;

  /// Что идёт сейчас — для подписи у кнопки: какой путь меряется ([stage]) и что именно происходит
  /// ([step]: соединение с сервером, переход на запасной, скачивание).
  String stage = '';
  String step = '';

  /// Подпись у кнопки во время замера.
  String get status => step.isEmpty ? 'Идёт замер $stage' : 'Идёт замер ${stage.replaceAll('…', '')}: $step';

  /// Какой путь меряется сейчас: 0 — через VPN, 1 — напрямую; null — замер не идёт.
  int? running;

  /// Какая часть времени замера этого пути прошла, от 0 до 1.
  double progress = 0;

  /// Скорость по ходу замера, четыре раза в секунду: по ней окно рисует столбики.
  final vpnSamples = <double>[], directSamples = <double>[];
  double? vpnMbit, directMbit;
  String? vpnError, directError;

  /// С какого сервера качался файл через VPN и напрямую (null — замер до сервера не дошёл).
  String? vpnHost, directHost;

  static String show(double? mbit) =>
      mbit == null ? '—' : '${mbit >= 10 ? mbit.round() : mbit.toStringAsFixed(1)} Мбит/с';

  List<SiteNote> get notes {
    final found = <SiteNote>[];
    void add(SiteNoteKind kind, String text) => found.add((kind: kind, text: text));
    final vpn = vpnMbit, direct = directMbit;
    if (vpn == null) {
      add(SiteNoteKind.bad, 'Через VPN замер не удался${vpnError == null ? '' : ': $vpnError'}');
    } else if (direct == null) {
      add(SiteNoteKind.info, 'Через VPN — ${show(vpn)}. Напрямую не измерялось${directError == null ? '' : ': $directError'}');
    } else if (vpn * 2 < direct) {
      add(SiteNoteKind.warn,
          'Через VPN скорость меньше половины той, что напрямую (${show(vpn)} против ${show(direct)}): '
          'её ограничивает VPN-сервер или путь до него');
    } else if (vpn > direct * 1.3) {
      // Так бывает: замер идёт до одного сервера, и напрямую до него может быть медленнее, чем через VPN.
      add(SiteNoteKind.ok,
          'VPN скорость не режет: через него вышло даже быстрее (${show(vpn)} против ${show(direct)} напрямую)');
    } else {
      add(SiteNoteKind.ok, 'VPN скорость заметно не режет: ${show(vpn)} против ${show(direct)} напрямую');
    }
    return found;
  }

  String get copyText => [
        'Скорость скачивания — через VPN: ${vpnMbit == null ? (vpnError ?? '—') : show(vpnMbit)}; '
            'напрямую: ${directMbit == null ? (directError ?? '—') : show(directMbit)}'
            '${_hosts.isEmpty ? '' : ' (сервер замера: ${_hosts.join(', ')})'}',
        for (final n in notes) '  • ${n.text}',
      ].join('\n');

  List<String> get _hosts => {for (final h in [vpnHost, directHost]) if (h != null) h}.toList();
}

/// Замер скорости: несколько секунд проверочный файл качается сразу в несколько соединений, скачанное
/// никуда не сохраняется. Через VPN — через вход проверки связи ядра (он всегда ведёт через VPN-сервер),
/// напрямую — через настоящую сетевую карту. Файл и сервер одни и те же, так что разница — это сам VPN.
/// Одно соединение упирается в собственный потолок задолго до быстрой линии, поэтому их несколько,
/// а скорость — их сумма.
class SpeedTest {
  /// Открытые серверы замера скорости и файл на каждом: первый — основной (в России), остальные —
  /// запасные, если он не отвечает. Все отдают файл по https в четыре соединения сразу (Hetzner,
  /// например, на третье отвечает 429 — не подходит).
  static const List<SpeedServer> servers = [
    (host: 'speedtest.selectel.ru', path: '/100MB'),
    (host: 'proof.ovh.net', path: '/files/100Mb.dat'),
    (host: 'fra-de-ping.vultr.com', path: '/vultr.com.100MB.bin'),
  ];

  /// Замер по серверам из [list] по очереди, пока какой-то не ответит. Следующий берётся, только если
  /// сервер не ответил вовсе; оборванный или прерванный замер не повторяется.
  static Future<SpeedResult> firstReachable(
      List<SpeedServer> list, Future<SpeedResult> Function(SpeedServer server) run, bool Function()? keepGoing) async {
    late SpeedResult result;
    for (final server in list) {
      result = await run(server);
      if (!result.unreachable || !(keepGoing?.call() ?? true)) break;
    }
    return result;
  }

  /// Сколько соединений качают файл одновременно.
  static const streams = 4;

  /// Сколько длится один замер и сколько из этого идёт на разгон (в счёт не идёт).
  static const duration = Duration(seconds: 6), warmup = Duration(seconds: 1);
  static const _timeout = Duration(seconds: 8);

  /// Сколько ждать ответа сервера замера, прежде чем перейти к следующему.
  static int get timeoutSeconds => _timeout.inSeconds;

  /// Как часто замер сообщает скорость по ходу дела и сколько таких сообщений выходит за замер.
  static const tick = Duration(milliseconds: 250);
  static int get ticks => duration.inMilliseconds ~/ tick.inMilliseconds;

  /// Скорость по счётчику байт: [atWarmup] — сколько было скачано к концу разгона (null — до него не
  /// дошло), [total] — всего, [elapsed] — сколько шёл замер.
  static double mbit({required int total, int? atWarmup, required Duration elapsed}) {
    final counted = atWarmup == null ? total : total - atWarmup;
    final time = atWarmup == null ? elapsed : elapsed - warmup;
    return time.inMilliseconds <= 0 ? 0 : counted * 8 / 1000 / time.inMilliseconds;
  }

  /// Открывает [streams] соединений способом [open] и качает файл по всем сразу; скорость — сумма.
  /// [onProgress] раз в [tick] получает скорость за последний отрезок и долю прошедшего времени.
  /// [keepGoing] отвечает, то ли ещё подключение: после отключения VPN замер останавливается.
  static Future<SpeedResult> _measure(SpeedServer server, Future<_Link> Function() open, SpeedProgress? onProgress,
      bool Function()? keepGoing) async {
    final host = server.host;
    SpeedResult fail(String error, {bool unreachable = false}) =>
        (mbit: null, error: error, unreachable: unreachable, host: host);
    final links = <_Link>[];
    String? openError;
    await Future.wait([
      for (var i = 0; i < streams; i++)
        () async {
          try {
            links.add(await open());
          } on TimeoutException {
            openError = 'нет ответа за ${_timeout.inSeconds} с';
          } catch (_) {
            openError = 'соединение с сервером замера не установилось';
          }
        }(),
    ]);
    if (links.isEmpty) return fail(openError ?? 'соединение с сервером замера не установилось', unreachable: true);
    try {
      final done = Completer<void>();
      final watch = Stopwatch()..start();
      var total = 0, alive = links.length;
      int? atWarmup;
      String? status;
      // Когда пришли последние байты: файлы могут кончиться раньше срока, и простой после них в счёт
      // идти не должен.
      Duration? lastDataAt;
      void finish() {
        if (!done.isCompleted) done.complete();
      }

      for (final link in links) {
        final tls = link.tls;
        // Сколько байт придёт по этому соединению (размер файла из заголовков ответа; сами заголовки
        // к нему не прибавляем — на счёт скорости такая малость не влияет) и сколько уже пришло.
        int? fileEnd;
        var got = 0, closed = false;
        void close() {
          if (closed) return;
          closed = true;
          if (--alive == 0) finish();
        }

        tls.listen((event) {
          if (event == RawSocketEvent.read) {
            for (var chunk = tls.read(); chunk != null && chunk.isNotEmpty; chunk = tls.read()) {
              if (got == 0) {
                final head = latin1.decode(chunk.sublist(0, chunk.length < 2048 ? chunk.length : 2048));
                final line = head.split('\r\n').first;
                if (status == null || line.contains(' 200')) status = line;
                final length = RegExp(r'content-length:\s*(\d+)', caseSensitive: false).firstMatch(head)?.group(1);
                if (length != null) fileEnd = int.parse(length);
              }
              got += chunk.length;
              total += chunk.length;
            }
            lastDataAt = watch.elapsed;
            if (atWarmup == null && watch.elapsed >= warmup) atWarmup = total;
            if (fileEnd != null && got >= fileEnd!) close();
            if (watch.elapsed >= duration) finish();
          } else if (event == RawSocketEvent.closed || event == RawSocketEvent.readClosed) {
            close();
          }
        }, onError: (Object e) => close());
        tls.write(ascii.encode('GET ${server.path} HTTP/1.1\r\nHost: $host\r\nUser-Agent: SkipIt\r\nAccept: */*\r\n'
            'Connection: close\r\n\r\n'));
      }

      var seenBytes = 0, seenAt = Duration.zero;
      var stopped = false;
      final ticker = Timer.periodic(tick, (_) {
        if (done.isCompleted) return;
        if (!(keepGoing?.call() ?? true)) {
          stopped = true;
          finish();
          return;
        }
        final now = watch.elapsed, ms = (now - seenAt).inMilliseconds;
        if (atWarmup == null && now >= warmup) atWarmup = total;
        // Секунду ничего не приходит, хотя файл уже шёл, — соединения встали.
        if (lastDataAt != null && total > 1024 * 1024 && now - lastDataAt! >= const Duration(seconds: 1)) {
          finish();
          return;
        }
        if (ms > 0) {
          onProgress?.call(
              (total - seenBytes) * 8 / 1000 / ms, (now.inMilliseconds / duration.inMilliseconds).clamp(0, 1).toDouble());
        }
        seenBytes = total;
        seenAt = now;
        if (now >= duration) finish();
      });
      await done.future.timeout(duration + _timeout, onTimeout: () {});
      ticker.cancel();
      if (stopped) return fail('замер прерван: VPN отключился или переподключился');
      final elapsed = lastDataAt ?? watch.elapsed;
      if (status == null) return fail('сервер замера не ответил', unreachable: true);
      if (!status!.contains(' 200')) return fail('сервер замера ответил «$status»');
      if (total < 200 * 1024) return fail('сервер замера не отдал файл');
      return (mbit: mbit(total: total, atWarmup: atWarmup, elapsed: elapsed), error: null, unreachable: false, host: host);
    } finally {
      for (final link in links) {
        unawaited(link.tls.close().catchError((Object _) => link.tls));
        unawaited(link.raw.close().catchError((Object _) => link.raw));
      }
    }
  }

  /// Через VPN: соединения с сервером замера через вход проверки связи ядра на порту [port].
  static Future<SpeedResult> viaVpn(SpeedServer server,
          {required int port, SpeedProgress? onProgress, bool Function()? keepGoing}) =>
      _measure(server, () async {
        final host = server.host;
        final socket = await RawSocket.connect(InternetAddress.loopbackIPv4, port, timeout: _timeout);
        try {
          final answer = Completer<String>();
          final head = BytesBuilder();
          final listening = socket.listen((event) {
            if (answer.isCompleted) return;
            if (event == RawSocketEvent.read) {
              head.add(socket.read() ?? const []);
              final text = latin1.decode(head.toBytes());
              if (text.contains('\r\n\r\n')) answer.complete(text);
            } else if (event == RawSocketEvent.closed || event == RawSocketEvent.readClosed) {
              answer.complete('');
            }
          }, onError: (Object e) {
            if (!answer.isCompleted) answer.complete('');
          });
          socket.write(ascii.encode('CONNECT $host:443 HTTP/1.1\r\nHost: $host:443\r\n\r\n'));
          final status = (await answer.future.timeout(_timeout, onTimeout: () => '')).split('\r\n').first;
          if (!status.contains(' 200')) throw const SocketException('ядро не открыло соединение');
          final tls =
              await RawSecureSocket.secure(socket, subscription: listening, host: host).timeout(_timeout);
          return (raw: socket, tls: tls);
        } catch (_) {
          unawaited(socket.close().catchError((Object _) => socket));
          rethrow;
        }
      }, onProgress, keepGoing);

  /// Напрямую: соединения с адресом [address] сервера замера через сетевую карту с адресом [source]
  /// (null — обычным маршрутом: так в режимах без адаптера).
  static Future<SpeedResult> direct(SpeedServer server, InternetAddress address, InternetAddress? source,
          {SpeedProgress? onProgress, bool Function()? keepGoing}) =>
      _measure(server, () async {
        final raw = await RawSocket.connect(address, 443, sourceAddress: source, timeout: _timeout);
        try {
          return (raw: raw, tls: await RawSecureSocket.secure(raw, host: server.host).timeout(_timeout));
        } catch (_) {
          unawaited(raw.close().catchError((Object _) => raw));
          rethrow;
        }
      }, onProgress, keepGoing);
}

/// Одно соединение замера: само соединение и защищённый канал поверх него.
typedef _Link = ({RawSocket raw, RawSecureSocket tls});
