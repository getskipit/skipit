import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'site_check.dart';

/// Замер одного пути: сколько пробных пакетов ушло и за сколько миллисекунд пришёл каждый ответ.
class LinePath {
  LinePath({this.sent = 0, List<int>? replies, this.longestGap = 0}) : replies = replies ?? [];
  final int sent;
  final List<int> replies;

  /// Самая длинная череда пакетов подряд, оставшихся без ответа.
  final int longestGap;

  bool get measured => sent > 0;

  /// Ответов нет вовсе: путь такие пакеты не пропускает, и о его ровности замер ничего не говорит.
  bool get silent => measured && replies.isEmpty;

  int get lost => sent - replies.length;
  double get lossPercent => sent == 0 ? 0 : lost * 100 / sent;

  /// Обычный ответ (половина ответов не дольше) и худший.
  int? get usual => replies.isEmpty ? null : (replies.toList()..sort())[replies.length ~/ 2];
  int? get worst => replies.isEmpty ? null : replies.reduce((a, b) => a > b ? a : b);

  /// Всплески: ответы, пришедшие заметно позже обычного.
  int get spikes {
    final base = usual;
    return base == null ? 0 : replies.where((ms) => ms > base + LineCheck.spikeOver).length;
  }

  /// Путь неровный: теряется от 1 % пакетов или всплеском приходит каждый пятидесятый ответ.
  bool get rough => !silent && measured && (lossPercent >= 1 || (spikes >= 3 && spikes * 50 >= replies.length));

  String get summary => !measured
      ? 'не измерялось'
      : silent
          ? 'ответов нет'
          : 'потери ${lossText()}, обычный ответ $usual мс, худший $worst мс, всплесков $spikes';

  String lossText() => lost == 0 ? '0 %' : '${lossPercent < 10 ? lossPercent.toStringAsFixed(1) : lossPercent.round()} %';
}

/// Стабильность связи: один и тот же поток пробных пакетов через VPN и мимо него.
class LineReport {
  bool done = false;

  /// Сколько секунд замера осталось.
  int left = LineCheck.seconds;
  LinePath vpn = LinePath(), direct = LinePath();

  /// Почему путь не измерялся.
  String? vpnSkipped, directSkipped;
  String? error;

  List<SiteNote> get notes {
    final found = <SiteNote>[];
    void add(SiteNoteKind kind, String text) => found.add((kind: kind, text: text));
    if (error != null) {
      add(SiteNoteKind.bad, error!);
      return found;
    }
    String detail(LinePath p) => 'потери ${p.lossText()}, всплесков ${p.spikes}, худший ответ ${p.worst} мс';
    if (vpn.silent) {
      add(SiteNoteKind.info, 'Через VPN ответы на пробные пакеты не пришли: сервер может такие пакеты не пропускать. '
          'О ровности пути через VPN этот замер ничего не говорит');
    }
    if (direct.silent) {
      add(SiteNoteKind.info, 'Мимо VPN ответы на пробные пакеты не пришли — этот путь остался неизмеренным');
    }
    final vpnOk = vpn.measured && !vpn.silent, directOk = direct.measured && !direct.silent;
    if (directOk && direct.rough) {
      add(SiteNoteKind.warn,
          'Связь неровная уже мимо VPN (${detail(direct)}): дело в вашей линии или интернет-провайдере, а не в VPN');
    }
    if (vpnOk && vpn.rough) {
      if (directOk && !direct.rough) {
        add(SiteNoteKind.warn,
            'Мимо VPN связь ровная, а через VPN — ${detail(vpn)}: неровность даёт путь до VPN-сервера или сам сервер');
      } else if (!directOk) {
        add(SiteNoteKind.warn, 'Через VPN — ${detail(vpn)}. Мимо VPN не измерялось, поэтому чья это неровность, не видно');
      }
    }
    if (!found.any((n) => n.kind == SiteNoteKind.warn) && (vpnOk || directOk)) {
      add(
          SiteNoteKind.ok,
          vpnOk && directOk
              ? 'Связь ровная и через VPN, и мимо него'
              : 'Связь ровная ${vpnOk ? 'через VPN' : 'мимо VPN'}; другой путь не измерялся');
    }
    return found;
  }

  String get copyText => [
        'Стабильность связи — через VPN: ${vpnSkipped ?? vpn.summary}; мимо VPN: ${directSkipped ?? direct.summary}',
        for (final n in notes) '  • ${n.text}',
      ].join('\n');
}

/// Замер стабильности: раз в [interval] уходит маленький пробный пакет (запрос STUN) — через VPN и
/// через настоящую сетевую карту, — и на каждый ждётся ответ. По потерям и разбросу времени ответа
/// видно, ровная ли связь и на каком пути она портится.
class LineCheck {
  static const host = 'stun.cloudflare.com', port = 3478;
  static const seconds = 20;
  static const interval = Duration(milliseconds: 40);
  static int get packets => seconds * 1000 ~/ interval.inMilliseconds;

  /// На сколько миллисекунд позже обычного должен прийти ответ, чтобы считаться всплеском.
  static const spikeOver = 50;

  /// Пробный пакет номер [n]: запрос STUN, номер — в конце его идентификатора.
  static Uint8List request(int n) {
    final p = ByteData(20)
      ..setUint16(0, 1)
      ..setUint32(4, 0x2112A442)
      ..setUint32(8, 0x536b6970)
      ..setUint32(16, n);
    return p.buffer.asUint8List();
  }

  /// Номер пакета, на который это ответ; null — пришло что-то другое.
  static int? replyNumber(Uint8List data) {
    if (data.length < 20) return null;
    final p = ByteData.sublistView(data);
    return p.getUint32(4) == 0x2112A442 && p.getUint32(8) == 0x536b6970 ? p.getUint32(16) : null;
  }

  /// Итог пути по времени ответа на каждый пакет ([rtt]: null — ответа не было).
  static LinePath path(List<int?> rtt) {
    var gap = 0, longest = 0;
    for (final ms in rtt) {
      gap = ms == null ? gap + 1 : 0;
      if (gap > longest) longest = gap;
    }
    return LinePath(sent: rtt.length, replies: rtt.nonNulls.toList(), longestGap: longest);
  }

  /// Замер. [server] — адрес проверочного сервера. [viaVpn] — слать ли обычным маршрутом (он ведёт в
  /// адаптер VPN); [source] — адрес настоящей сетевой карты для пути мимо VPN, null — этот путь не
  /// меряется. [onStart] получает порт, с которого идут пакеты через VPN, — по нему соединение находится
  /// в журнале ядра; [onTick] вызывается раз в секунду.
  static Future<void> run(
    LineReport report, {
    required InternetAddress server,
    required bool viaVpn,
    InternetAddress? source,
    void Function(int vpnPort)? onStart,
    void Function()? onTick,
    int? count,
  }) async {
    final total = count ?? packets;
    final sockets = <RawDatagramSocket?>[null, null];
    try {
      if (viaVpn) sockets[0] = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      if (source != null) sockets[1] = await RawDatagramSocket.bind(source, 0);
      final vpnSocket = sockets[0];
      if (vpnSocket != null) onStart?.call(vpnSocket.port);
      final watch = Stopwatch()..start();
      final sentAt = [List<int?>.filled(total, null), List<int?>.filled(total, null)];
      final rtt = [List<int?>.filled(total, null), List<int?>.filled(total, null)];
      for (var i = 0; i < 2; i++) {
        final socket = sockets[i];
        socket?.listen((event) {
          if (event != RawSocketEvent.read) return;
          for (var d = socket.receive(); d != null; d = socket.receive()) {
            final n = replyNumber(d.data);
            final at = n == null || n >= total ? null : sentAt[i][n];
            if (at != null && rtt[i][n!] == null) rtt[i][n] = ((watch.elapsedMicroseconds - at) / 1000).round();
          }
        }, onError: (_) {});
      }
      var n = 0;
      final sending = Completer<void>();
      Timer.periodic(interval, (timer) {
        if (n >= total) {
          timer.cancel();
          sending.complete();
          return;
        }
        final packet = request(n);
        for (var i = 0; i < 2; i++) {
          try {
            if (sockets[i] != null && sockets[i]!.send(packet, server, port) > 0) sentAt[i][n] = watch.elapsedMicroseconds;
          } catch (_) {
            // Пакет не ушёл — он останется без времени отправки и будет считаться потерянным.
          }
        }
        n++;
        final left = ((total - n) * interval.inMilliseconds / 1000).ceil();
        if (left != report.left) {
          report.left = left;
          onTick?.call();
        }
      });
      await sending.future;
      // Опоздавшие ответы ещё могут прийти.
      await Future.delayed(const Duration(milliseconds: 1500));
      if (sockets[0] != null) report.vpn = path(rtt[0]);
      if (sockets[1] != null) report.direct = path(rtt[1]);
    } catch (e) {
      report.error = 'Не удалось начать замер: $e';
    } finally {
      for (final s in sockets) {
        s?.close();
      }
      report
        ..left = 0
        ..done = true;
    }
  }
}
