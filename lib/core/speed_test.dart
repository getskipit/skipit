import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'site_check.dart';

typedef SpeedResult = ({double? mbit, String? error});
typedef SpeedProgress = void Function(double mbit, double done);

/// Замер скорости скачивания: один и тот же файл через VPN и напрямую.
class SpeedReport {
  bool done = false;

  /// Что идёт сейчас — для подписи у кнопки.
  String stage = '';

  /// Какой путь меряется сейчас: 0 — через VPN, 1 — напрямую; null — замер не идёт.
  int? running;

  /// Какая часть времени замера этого пути прошла, от 0 до 1.
  double progress = 0;

  /// Скорость по ходу замера, четыре раза в секунду: по ней окно рисует столбики.
  final vpnSamples = <double>[], directSamples = <double>[];
  double? vpnMbit, directMbit;
  String? vpnError, directError;

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
    } else {
      add(SiteNoteKind.ok, 'VPN скорость заметно не режет: ${show(vpn)} против ${show(direct)} напрямую');
    }
    return found;
  }

  String get copyText => [
        'Скорость скачивания — через VPN: ${vpnMbit == null ? (vpnError ?? '—') : show(vpnMbit)}; '
            'напрямую: ${directMbit == null ? (directError ?? '—') : show(directMbit)}',
        for (final n in notes) '  • ${n.text}',
      ].join('\n');
}

/// Замер скорости: несколько секунд качается проверочный файл, скачанное никуда не сохраняется.
/// Через VPN — через вход проверки связи ядра (он всегда ведёт через VPN-сервер), напрямую — через
/// настоящую сетевую карту. Файл и сервер одни и те же, так что разница — это сам VPN.
class SpeedTest {
  /// Открытый сервер замера скорости и файл на нём.
  static const host = 'speedtest.selectel.ru', path = '/100MB';

  /// Сколько длится один замер и сколько из этого идёт на разгон (в счёт не идёт).
  static const duration = Duration(seconds: 6), warmup = Duration(seconds: 1);
  static const _timeout = Duration(seconds: 8);

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

  /// Качает файл по готовому защищённому соединению и считает скорость. [onProgress] раз в [tick]
  /// получает скорость за последний отрезок и долю прошедшего времени.
  static Future<SpeedResult> _download(RawSecureSocket tls, SpeedProgress? onProgress) async {
    final done = Completer<void>();
    final watch = Stopwatch()..start();
    var total = 0;
    int? atWarmup;
    String? status;
    // Сколько байт придёт всего (заголовки и файл) и когда пришли последние: файл может кончиться
    // раньше срока замера, и время после него в счёт идти не должно.
    int? fileEnd;
    Duration? lastDataAt;
    var seenBytes = 0, seenAt = Duration.zero;
    final ticker = Timer.periodic(tick, (_) {
      if (done.isCompleted) return;
      final now = watch.elapsed, ms = (now - seenAt).inMilliseconds;
      // Секунду ничего не приходит, хотя файл уже шёл, — он кончился или соединение встало.
      if (lastDataAt != null && total > 1024 * 1024 && now - lastDataAt! >= const Duration(seconds: 1)) {
        done.complete();
        return;
      }
      if (ms > 0) {
        onProgress?.call((total - seenBytes) * 8 / 1000 / ms, (now.inMilliseconds / duration.inMilliseconds).clamp(0, 1).toDouble());
      }
      seenBytes = total;
      seenAt = now;
      // Данные могли перестать идти — тогда замер заканчивает не чтение, а время.
      if (now >= duration && !done.isCompleted) done.complete();
    });
    tls.listen((event) {
      if (event == RawSocketEvent.read) {
        for (var chunk = tls.read(); chunk != null && chunk.isNotEmpty; chunk = tls.read()) {
          if (status == null) {
            final head = latin1.decode(chunk.sublist(0, chunk.length < 2048 ? chunk.length : 2048));
            status = head.split('\r\n').first;
            final end = head.indexOf('\r\n\r\n');
            final length = RegExp(r'content-length:\s*(\d+)', caseSensitive: false).firstMatch(head)?.group(1);
            if (end >= 0 && length != null) fileEnd = end + 4 + int.parse(length);
          }
          total += chunk.length;
        }
        lastDataAt = watch.elapsed;
        if (atWarmup == null && watch.elapsed >= warmup) atWarmup = total;
        final whole = fileEnd != null && total >= fileEnd!;
        if ((whole || watch.elapsed >= duration) && !done.isCompleted) done.complete();
      } else if (event == RawSocketEvent.closed || event == RawSocketEvent.readClosed) {
        if (!done.isCompleted) done.complete();
      }
    }, onError: (Object e) {
      if (!done.isCompleted) done.complete();
    });
    tls.write(ascii.encode('GET $path HTTP/1.1\r\nHost: $host\r\nUser-Agent: SkipIt\r\nAccept: */*\r\n'
        'Connection: close\r\n\r\n'));
    await done.future.timeout(duration + _timeout, onTimeout: () {});
    ticker.cancel();
    final elapsed = lastDataAt ?? watch.elapsed;
    if (status == null) return (mbit: null, error: 'сервер замера не ответил');
    if (!status!.contains(' 200')) return (mbit: null, error: 'сервер замера ответил «$status»');
    if (total < 200 * 1024) return (mbit: null, error: 'сервер замера не отдал файл');
    return (mbit: mbit(total: total, atWarmup: atWarmup, elapsed: elapsed), error: null);
  }

  /// Через VPN: соединение с сервером замера через вход проверки связи ядра на порту [port].
  static Future<SpeedResult> viaVpn({required int port, SpeedProgress? onProgress}) async {
    RawSocket? raw;
    RawSecureSocket? tls;
    try {
      final socket = raw = await RawSocket.connect(InternetAddress.loopbackIPv4, port, timeout: _timeout);
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
      if (!status.contains(' 200')) return (mbit: null, error: 'ядро не открыло соединение');
      tls = await RawSecureSocket.secure(socket, subscription: listening, host: host).timeout(_timeout);
      return await _download(tls, onProgress);
    } on TimeoutException {
      return (mbit: null, error: 'нет ответа за ${_timeout.inSeconds} с');
    } catch (_) {
      return (mbit: null, error: 'соединение с сервером замера не установилось');
    } finally {
      await tls?.close();
      await raw?.close();
    }
  }

  /// Напрямую: соединение с адресом [address] сервера замера через сетевую карту с адресом [source]
  /// (null — обычным маршрутом: так в режимах без адаптера).
  static Future<SpeedResult> direct(InternetAddress address, InternetAddress? source,
      {SpeedProgress? onProgress}) async {
    RawSocket? raw;
    RawSecureSocket? tls;
    try {
      raw = await RawSocket.connect(address, 443, sourceAddress: source, timeout: _timeout);
      tls = await RawSecureSocket.secure(raw, host: host).timeout(_timeout);
      return await _download(tls, onProgress);
    } on TimeoutException {
      return (mbit: null, error: 'нет ответа за ${_timeout.inSeconds} с');
    } catch (_) {
      return (mbit: null, error: 'соединение с сервером замера не установилось');
    } finally {
      await tls?.close();
      await raw?.close();
    }
  }
}
