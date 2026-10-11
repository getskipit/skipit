import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'dns_check.dart';
import 'log_store.dart';

/// Насколько строка вывода тревожна: всё в порядке, к сведению, причина задержки, сайт не открылся.
enum SiteNoteKind { ok, info, warn, bad }

typedef SiteNote = ({SiteNoteKind kind, String text});

/// Результат проверки одного сайта: каким путём он идёт и на что уходит время.
class SiteReport {
  SiteReport(this.host);
  final String host;
  bool done = false;

  /// Каким путём ядро отправило соединение; null — в журнале ядра его не нашлось.
  ConnRoute? route;

  /// Сколько прошло до готового защищённого соединения выбранным путём: в первый раз (вместе с
  /// поиском адреса) и повторно. null — соединение не открылось.
  int? firstMs, warmMs;

  /// Сколько сайт отвечал на запрос после того, как соединение установлено.
  int? replyMs;

  /// Почему соединение не открылось.
  String? error;

  /// Сравнение с проверочным адресом, который всегда идёт через VPN: лучшее соединение с сайтом и с этим
  /// адресом одним и тем же выходом ядра. У провайдера выходов бывает несколько, и на новое соединение они
  /// тратят разное время — сравнивать сайт на одном с проверочным адресом на другом нельзя. null — общего
  /// выхода среди замеров не нашлось.
  int? vpnSiteMs, vpnBaseMs;

  /// Адрес, который называет DNS ядра (только когда трафик идёт через свой адаптер), и за сколько с ним
  /// открывается соединение мимо VPN. Меряется только у сайта, идущего напрямую.
  String? address;
  int? addressMs;

  /// Адрес того же сайта от независимого DNS, спрошенного мимо VPN, и время до него.
  String? otherAddress;
  int? otherMs;

  String get path => switch (route) {
        ConnRoute.proxy => 'через VPN',
        ConnRoute.direct => 'напрямую',
        ConnRoute.block => 'заблокирован правилом',
        _ => 'путь не определён',
      };

  /// Адрес от независимого DNS заметно ближе: больше чем в полтора раза и не меньше чем на 60 мс.
  bool get farAddress =>
      addressMs != null && otherMs != null && addressMs! - otherMs! >= 60 && addressMs! * 2 > otherMs! * 3;

  /// Вывод словами: на что ушло время.
  List<SiteNote> get notes {
    final found = <SiteNote>[];
    void add(SiteNoteKind kind, String text) => found.add((kind: kind, text: text));
    if (route == ConnRoute.block) {
      add(SiteNoteKind.bad, 'Сайт заблокирован правилом маршрутизации — поэтому он не открывается');
      return found;
    }
    // Время самой дороги — лучшее из двух соединений: ядро могло пойти к разным адресам сайта.
    final warm = firstMs == null || warmMs == null ? (warmMs ?? firstMs) : (firstMs! < warmMs! ? firstMs : warmMs);
    if (warm == null) {
      add(SiteNoteKind.bad, 'Этим путём сайт не открылся${error == null ? '' : ': $error'}');
      if (addressMs != null) add(SiteNoteKind.info, 'Сам адрес сайта при этом отвечает мимо VPN за $addressMs мс');
      return found;
    }
    // Поиск адреса — разовая задержка: дальше ядро берёт адрес из памяти, и повторная проверка её не
    // покажет. Причиной медленной работы её считаем, только когда она заметна человеку.
    if (firstMs != null && warmMs != null && firstMs! - warmMs! >= 400) {
      final lookup = firstMs! - warmMs!;
      add(lookup >= 1500 ? SiteNoteKind.warn : SiteNoteKind.info,
          'Первое соединение на $lookup мс дольше повторного: столько занял поиск адреса (DNS). '
          'Это разовая задержка — дальше адрес берётся из памяти ядра');
    }
    if (farAddress) {
      add(SiteNoteKind.warn,
          'DNS назвал далёкий адрес: до него $addressMs мс, а до адреса от независимого DNS — $otherMs мс. '
          'Посмотрите серверы в блоке «DNS» выше');
    }
    final compared = route == ConnRoute.proxy && vpnSiteMs != null && vpnBaseMs != null;
    if (compared && vpnSiteMs! - vpnBaseMs! >= 150 && vpnSiteMs! * 2 > vpnBaseMs! * 3) {
      add(SiteNoteKind.warn,
          'Сайт далеко от VPN-сервера: соединение с ним $vpnSiteMs мс, а с проверочным адресом тем же '
          'путём — $vpnBaseMs мс');
    }
    if (replyMs == null) {
      add(SiteNoteKind.warn, 'Соединение открылось, но на запрос сайт не ответил за ${SiteCheck.timeout.inSeconds} с');
    } else if (replyMs! >= 1500 && replyMs! > warm * 2) {
      add(SiteNoteKind.warn,
          'Сайт сам долго отвечает: $replyMs мс после того, как соединение уже установлено. VPN и DNS тут ни при чём');
    }
    if (!found.any((n) => n.kind == SiteNoteKind.warn)) {
      add(
          SiteNoteKind.ok,
          'Задержек по дороге не видно: соединение $warm мс'
          '${compared ? ' — обычное время пути через VPN-сервер' : ''}, '
          'ответ сайта ${replyMs ?? '—'} мс');
    }
    return found;
  }

  /// Одной строкой для журнала.
  String get summary => [
        path,
        if (firstMs != null) 'соединение $firstMs мс${warmMs == null ? '' : ', повторное $warmMs мс'}',
        if (replyMs != null) 'ответ сайта $replyMs мс',
        if (addressMs != null) 'адрес от DNS ядра мимо VPN $addressMs мс',
        if (otherMs != null) 'адрес от независимого DNS $otherMs мс',
        if (vpnBaseMs != null) 'тем же путём через VPN: сайт $vpnSiteMs мс, проверочный адрес $vpnBaseMs мс',
        if (error != null) error!,
      ].join(', ');
}

/// «Почему тормозит?»: проверка одного сайта так, как к нему ходит браузер, — через локальный
/// HTTP-порт ядра. Показывает путь (через VPN или напрямую) и на что уходит время: поиск адреса,
/// дорога, сам сайт. Правила по приложениям на проверку не действуют — её делает сама SkipIt.
class SiteCheck {
  static const timeout = Duration(seconds: 8);

  /// Имя сайта из того, что вписал человек: без `https://`, пути и порта. null — это не имя сайта.
  static String? hostOf(String input) {
    var text = input.trim().toLowerCase();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'https://$text';
    final host = Uri.tryParse(text)?.host ?? '';
    return RegExp(r'^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$').hasMatch(host) ? host : null;
  }

  /// Соединение с [host] (порт 443) через локальный HTTP-порт ядра [port]: за сколько оно готово
  /// (вместе с поиском адреса и шифрованием) и за сколько сайт ответил на запрос заголовков.
  /// [auth] — «логин:пароль» порта, если он закрыт паролем.
  /// localPort — порт, с которого шло соединение: по нему оно находится в журнале ядра.
  static Future<({int? readyMs, int? replyMs, String? error, int? localPort})> viaProxy(String host,
      {required int port, String? auth}) async {
    RawSocket? raw;
    int? localPort;
    RawSecureSocket? secure;
    final watch = Stopwatch()..start();
    try {
      final socket = raw = await RawSocket.connect(InternetAddress.loopbackIPv4, port, timeout: timeout);
      localPort = socket.port;
      final answer = Completer<String>();
      final head = BytesBuilder();
      final listening = socket.listen((event) {
        if (answer.isCompleted) return;
        if (event == RawSocketEvent.read) {
          head.add(socket.read() ?? const []);
          final text = latin1.decode(head.toBytes());
          if (text.contains('\r\n\r\n')) answer.complete(text);
        } else if (event == RawSocketEvent.closed || event == RawSocketEvent.readClosed) {
          answer.complete(latin1.decode(head.toBytes()));
        }
      }, onError: (Object e) {
        if (!answer.isCompleted) answer.complete('');
      });
      final login = auth == null ? '' : 'Proxy-Authorization: Basic ${base64.encode(utf8.encode(auth))}\r\n';
      socket.write(ascii.encode('CONNECT $host:443 HTTP/1.1\r\nHost: $host:443\r\n$login\r\n'));
      final status = (await answer.future.timeout(timeout, onTimeout: () => '')).split('\r\n').first;
      if (!status.contains(' 200')) {
        return (
          readyMs: null,
          replyMs: null,
          error: status.isEmpty ? 'ядро не ответило' : 'ядро ответило «$status»',
          localPort: localPort
        );
      }
      // Ядро отвечает «готово» сразу, ещё до соединения с сайтом: открылось ли оно, видно по шифрованию.
      final tls = secure = await RawSecureSocket.secure(socket,
              subscription: listening, host: host, onBadCertificate: (_) => true)
          .timeout(timeout);
      final readyMs = watch.elapsedMilliseconds;

      final reply = Completer<bool>();
      tls.listen((event) {
        if (reply.isCompleted) return;
        if (event == RawSocketEvent.read) {
          if ((tls.read() ?? const []).isNotEmpty) reply.complete(true);
        } else if (event == RawSocketEvent.closed || event == RawSocketEvent.readClosed) {
          reply.complete(false);
        }
      }, onError: (Object e) {
        if (!reply.isCompleted) reply.complete(false);
      });
      tls.write(ascii.encode(
          'HEAD / HTTP/1.1\r\nHost: $host\r\nUser-Agent: SkipIt\r\nAccept: */*\r\nConnection: close\r\n\r\n'));
      final got = await reply.future.timeout(timeout, onTimeout: () => false);
      return (
        readyMs: readyMs,
        replyMs: got ? watch.elapsedMilliseconds - readyMs : null,
        error: null,
        localPort: localPort
      );
    } on TimeoutException {
      return (readyMs: null, replyMs: null, error: 'нет ответа за ${timeout.inSeconds} с', localPort: localPort);
    } catch (_) {
      return (
        readyMs: null,
        replyMs: null,
        error: 'соединение закрылось, не успев установиться',
        localPort: localPort
      );
    } finally {
      await secure?.close();
      await raw?.close();
    }
  }

  /// Адрес [host] от независимого DNS (Google, по HTTPS), спрошенного мимо VPN. [sources] — адреса
  /// настоящих сетевых карт, см. [DnsCheck.reach]. Обычный запрос на порт 53 мимо адаптера закрыт
  /// защитой от утечек, поэтому вопрос идёт по HTTPS.
  static Future<InternetAddress?> askPastVpn(String host, List<InternetAddress> sources) async {
    for (final source in sources.isEmpty ? const <InternetAddress?>[null] : sources) {
      if (source != null && source.type != InternetAddressType.IPv4) continue;
      Socket? plain;
      SecureSocket? secure;
      try {
        plain = await Socket.connect('8.8.8.8', 443, sourceAddress: source, timeout: const Duration(seconds: 3));
        final s = secure = await SecureSocket.secure(plain, host: 'dns.google').timeout(const Duration(seconds: 4));
        s.write('GET /resolve?type=A&name=$host HTTP/1.1\r\nHost: dns.google\r\n'
            'Accept: application/json\r\nConnection: close\r\n\r\n');
        final body = await const Utf8Decoder(allowMalformed: true)
            .bind(s)
            .join()
            .timeout(const Duration(seconds: 4));
        final found = _answerA.firstMatch(body);
        if (found != null) return InternetAddress(found.group(1)!);
      } catch (_) {
        // Через эту карту не вышло — пробуем следующую.
      } finally {
        secure?.destroy();
        plain?.destroy();
      }
    }
    return null;
  }

  static int? _best(int? a, int? b) => a == null || b == null ? (a ?? b) : (a < b ? a : b);

  static final _answerA = RegExp(r'"type"\s*:\s*1\s*,[^}]*"data"\s*:\s*"(\d+\.\d+\.\d+\.\d+)"');

  /// Замеры для [report]. [port] и [auth] — локальный HTTP-порт ядра, [checkPort] — вход проверки связи
  /// (всегда ведёт через VPN-сервер к [checkHost]), [ownTun] — трафик идёт через свой адаптер, и системный
  /// DNS — это DNS ядра. [routeOf] отдаёт путь, которым ядро отправило соединение с сайтом.
  static Future<void> run(
    SiteReport report, {
    required int port,
    String? auth,
    int? checkPort,
    required String checkHost,
    required bool ownTun,
    List<InternetAddress> sources = const [],
    required ConnEntry? Function(int localPort) connOf,
  }) async {
    // Лучшее время соединения по каждому выходу ядра, которым шли замеры [made].
    Map<String, int> byOutbound(List<({int? readyMs, int? replyMs, String? error, int? localPort})> made) {
      final best = <String, int>{};
      for (final m in made) {
        final out = m.localPort == null ? null : connOf(m.localPort!)?.outbound;
        if (out != null && m.readyMs != null) best[out] = _best(best[out], m.readyMs)!;
      }
      return best;
    }

    try {
      final first = await viaProxy(report.host, port: port, auth: auth);
      final site = [first];
      report
        ..firstMs = first.readyMs
        ..replyMs = first.replyMs
        ..error = first.error;
      // Повторных соединений три, в счёт идёт лучшее: дорога через VPN-сервер то и дело даёт всплески,
      // и по одному замеру выводы от проверки к проверке получались разные.
      for (var i = 0; i < 3 && first.readyMs != null; i++) {
        final again = await viaProxy(report.host, port: port, auth: auth);
        site.add(again);
        report
          ..warmMs = _best(report.warmMs, again.readyMs)
          ..replyMs = _best(report.replyMs, again.replyMs);
      }
      // Строка журнала ядра о том, куда ушло соединение, приходит чуть позже него самого.
      await Future.delayed(const Duration(milliseconds: 200));
      report.route = site.map((m) => m.localPort == null ? null : connOf(m.localPort!)).nonNulls.firstOrNull?.route;

      if (report.route == ConnRoute.proxy && checkPort != null && report.firstMs != null) {
        final base = [for (var i = 0; i < 4; i++) await viaProxy(checkHost, port: checkPort)];
        await Future.delayed(const Duration(milliseconds: 200));
        // Сравниваем только то, что шло одним выходом; если общих несколько — тот, где сайт быстрее.
        final siteBy = byOutbound(site), baseBy = byOutbound(base);
        for (final out in siteBy.keys.where(baseBy.containsKey)) {
          if (report.vpnSiteMs == null || siteBy[out]! < report.vpnSiteMs!) {
            report
              ..vpnSiteMs = siteBy[out]
              ..vpnBaseMs = baseBy[out];
          }
        }
      }
      // Мимо VPN идём только к сайту, который и так идёт напрямую: адрес сайта, идущего через VPN,
      // интернет-провайдеру показывать незачем.
      if (report.route == ConnRoute.direct && ownTun) {
        try {
          final named = await InternetAddress.lookup(report.host, type: InternetAddressType.IPv4)
              .timeout(const Duration(seconds: 3));
          report.address = named.firstOrNull?.address;
          if (named.isNotEmpty) report.addressMs = await DnsCheck.reach(named.first, sources);
        } catch (_) {}
        final other = await askPastVpn(report.host, sources);
        if (other != null) {
          report
            ..otherAddress = other.address
            ..otherMs = other.address == report.address ? report.addressMs : await DnsCheck.reach(other, sources);
        }
      }
    } finally {
      report.done = true;
    }
  }
}
