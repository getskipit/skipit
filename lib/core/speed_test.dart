import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'site_check.dart';

typedef SpeedResult = ({double? mbit, String? error});

/// Замер скорости скачивания: один и тот же файл через VPN и мимо него.
class SpeedReport {
  bool done = false;

  /// Что идёт сейчас — для подписи у кнопки.
  String stage = '';
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
      add(SiteNoteKind.info, 'Через VPN — ${show(vpn)}. Мимо VPN не измерялось${directError == null ? '' : ': $directError'}');
    } else if (vpn * 2 < direct) {
      add(SiteNoteKind.warn,
          'Через VPN скорость меньше половины той, что мимо него (${show(vpn)} против ${show(direct)}): '
          'её ограничивает VPN-сервер или путь до него');
    } else {
      add(SiteNoteKind.ok, 'VPN скорость заметно не режет: ${show(vpn)} против ${show(direct)} мимо него');
    }
    return found;
  }

  String get copyText => [
        'Скорость скачивания — через VPN: ${vpnMbit == null ? (vpnError ?? '—') : show(vpnMbit)}; '
            'мимо VPN: ${directMbit == null ? (directError ?? '—') : show(directMbit)}',
        for (final n in notes) '  • ${n.text}',
      ].join('\n');
}

/// Замер скорости: несколько секунд качается проверочный файл, скачанное никуда не сохраняется.
/// Через VPN — через вход проверки связи ядра (он всегда ведёт через VPN-сервер), мимо VPN — через
/// настоящую сетевую карту. Файл и сервер одни и те же, так что разница — это сам VPN.
class SpeedTest {
  /// Открытый сервер замера скорости и файл на нём.
  static const host = 'speedtest.selectel.ru', path = '/100MB';

  /// Сколько длится один замер и сколько из этого идёт на разгон (в счёт не идёт).
  static const duration = Duration(seconds: 6), warmup = Duration(seconds: 1);
  static const _timeout = Duration(seconds: 8);

  /// Скорость по счётчику байт: [atWarmup] — сколько было скачано к концу разгона (null — до него не
  /// дошло), [total] — всего, [elapsed] — сколько шёл замер.
  static double mbit({required int total, int? atWarmup, required Duration elapsed}) {
    final counted = atWarmup == null ? total : total - atWarmup;
    final time = atWarmup == null ? elapsed : elapsed - warmup;
    return time.inMilliseconds <= 0 ? 0 : counted * 8 / 1000 / time.inMilliseconds;
  }

  /// Качает файл по готовому защищённому соединению и считает скорость.
  static Future<SpeedResult> _download(RawSecureSocket tls) async {
    final done = Completer<void>();
    final watch = Stopwatch()..start();
    var total = 0;
    int? atWarmup;
    String? status;
    tls.listen((event) {
      if (event == RawSocketEvent.read) {
        for (var chunk = tls.read(); chunk != null && chunk.isNotEmpty; chunk = tls.read()) {
          status ??= latin1.decode(chunk.sublist(0, chunk.length < 60 ? chunk.length : 60)).split('\r\n').first;
          total += chunk.length;
        }
        if (atWarmup == null && watch.elapsed >= warmup) atWarmup = total;
        if (watch.elapsed >= duration && !done.isCompleted) done.complete();
      } else if (event == RawSocketEvent.closed || event == RawSocketEvent.readClosed) {
        if (!done.isCompleted) done.complete();
      }
    }, onError: (Object e) {
      if (!done.isCompleted) done.complete();
    });
    tls.write(ascii.encode('GET $path HTTP/1.1\r\nHost: $host\r\nUser-Agent: SkipIt\r\nAccept: */*\r\n'
        'Connection: close\r\n\r\n'));
    await done.future.timeout(duration + _timeout, onTimeout: () {});
    final elapsed = watch.elapsed;
    if (status == null) return (mbit: null, error: 'сервер замера не ответил');
    if (!status!.contains(' 200')) return (mbit: null, error: 'сервер замера ответил «$status»');
    if (total < 200 * 1024) return (mbit: null, error: 'сервер замера не отдал файл');
    return (mbit: mbit(total: total, atWarmup: atWarmup, elapsed: elapsed), error: null);
  }

  /// Через VPN: соединение с сервером замера через вход проверки связи ядра на порту [port].
  static Future<SpeedResult> viaVpn({required int port}) async {
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
      return await _download(tls);
    } on TimeoutException {
      return (mbit: null, error: 'нет ответа за ${_timeout.inSeconds} с');
    } catch (_) {
      return (mbit: null, error: 'соединение с сервером замера не установилось');
    } finally {
      await tls?.close();
      await raw?.close();
    }
  }

  /// Мимо VPN: соединение с адресом [address] сервера замера через сетевую карту с адресом [source]
  /// (null — обычным маршрутом: так в режимах без адаптера).
  static Future<SpeedResult> direct(InternetAddress address, InternetAddress? source) async {
    RawSocket? raw;
    RawSecureSocket? tls;
    try {
      raw = await RawSocket.connect(address, 443, sourceAddress: source, timeout: _timeout);
      tls = await RawSecureSocket.secure(raw, host: host).timeout(_timeout);
      return await _download(tls);
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
