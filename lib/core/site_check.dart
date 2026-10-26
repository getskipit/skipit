import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'dns_check.dart';
import 'log_store.dart';
import '../l10n/l10n.dart';

/// Насколько строка вывода тревожна: всё в порядке, к сведению, причина задержки, сайт не открылся.
enum SiteNoteKind { ok, info, warn, bad }

typedef SiteNote = ({SiteNoteKind kind, String text});

/// Когда и на каком сервере сделана проверка — подпись под результатом и в тексте для копирования.
typedef CheckStamp = ({DateTime at, String server});

/// Имя сайта для проверки: [host] — как оно уходит в сеть, [shown] — как его вписали и как показывать.
typedef SiteName = ({String host, String shown});

/// Результат проверки одного сайта: каким путём он идёт и на что уходит время.
class SiteReport {
  SiteReport(this.host, {String? shown}) : shown = shown ?? host;
  final String host;

  /// Имя, как его вписали: у кириллического сайта оно отличается от [host].
  final String shown;
  bool done = false;

  /// Каким путём ядро отправило соединение; null — в журнале ядра его не нашлось.
  ConnRoute? route;

  /// Сколько прошло до готового защищённого соединения выбранным путём: в первый раз (вместе с
  /// поиском адреса) и повторно. null — соединение не открылось.
  int? firstMs, warmMs;

  /// Лучшее из повторных соединений, прошедших тем же выходом ядра, что и первое; null — таких не было
  /// или выход неизвестен. Только с ним первое соединение сравнимо: у провайдера выходов бывает
  /// несколько, и разница между ними — не «первый раз».
  int? sameWayMs;

  /// Сколько сайт отвечал на запрос после того, как соединение установлено.
  int? replyMs;

  /// Почему соединение не открылось.
  String? error;

  /// Проверку прервало отключение или переподключение VPN: её замеры уже не про это подключение.
  bool stopped = false;

  /// Сравнение с проверочным адресом, который всегда идёт через VPN: лучшее соединение с сайтом и с этим
  /// адресом одним и тем же выходом ядра. У провайдера выходов бывает несколько, и на новое соединение они
  /// тратят разное время — сравнивать сайт на одном с проверочным адресом на другом нельзя. null — общего
  /// выхода среди замеров не нашлось.
  int? vpnSiteMs, vpnBaseMs;

  /// Адрес, который называет DNS ядра (только когда трафик идёт через свой адаптер), и за сколько с ним
  /// открывается соединение напрямую. Меряется только у сайта, идущего напрямую.
  String? address;
  int? addressMs;

  /// Адрес того же сайта от Google DNS, спрошенного напрямую, и время до него.
  String? otherAddress;
  int? otherMs;

  String get path => switch (route) {
        ConnRoute.proxy => tr('через VPN'),
        ConnRoute.direct => tr('напрямую'),
        ConnRoute.block => tr('заблокирован правилом'),
        _ => tr('путь не определён'),
      };

  /// Адрес от Google DNS заметно ближе: больше чем в полтора раза и не меньше чем на 60 мс.
  bool get farAddress =>
      addressMs != null && otherMs != null && addressMs! - otherMs! >= 60 && addressMs! * 2 > otherMs! * 3;

  /// Вывод словами: на что ушло время.
  List<SiteNote> get notes {
    final found = <SiteNote>[];
    void add(SiteNoteKind kind, String text) => found.add((kind: kind, text: text));
    if (stopped) {
      add(SiteNoteKind.bad, tr('Проверка прервана: VPN отключился или переподключился'));
      return found;
    }
    if (route == ConnRoute.block) {
      add(SiteNoteKind.bad, tr('Сайт заблокирован правилом маршрутизации — поэтому он не открывается'));
      return found;
    }
    // Время самой дороги — лучшее из двух соединений: ядро могло пойти к разным адресам сайта.
    final warm = firstMs == null || warmMs == null ? (warmMs ?? firstMs) : (firstMs! < warmMs! ? firstMs : warmMs);
    if (warm == null) {
      add(SiteNoteKind.bad, tr('Этим путём сайт не открылся{0}', [error == null ? '' : ': $error']));
      if (addressMs != null) add(SiteNoteKind.info, tr('Сам адрес сайта при этом отвечает напрямую за {0} мс', [addressMs]));
      return found;
    }
    // Первое обращение дольше повторных: на него уходят поиск адреса и установка связи. Говорим об этом,
    // только когда причина известна — первое и повторное соединения шли одним выходом ядра; иначе разницу
    // мог дать другой выход. Это разовая задержка, повторная проверка её не покажет, поэтому причиной
    // медленной работы её считаем, только когда она заметна человеку.
    if (firstMs != null && sameWayMs != null && firstMs! - sameWayMs! >= 400) {
      final extra = firstMs! - sameWayMs!;
      add(extra >= 1500 ? SiteNoteKind.warn : SiteNoteKind.info,
          tr('Первое соединение на {0} мс дольше повторного тем же путём: столько заняло первое обращение — '
          'поиск адреса и установка связи. Это разовая задержка, дальше быстрее', [extra]));
    }
    if (farAddress) {
      add(SiteNoteKind.warn,
          tr('DNS подключения назвал далёкий адрес: до него {0} мс, а до адреса от Google DNS — {1} мс. '
          'Серверы можно проверить ниже, в карточке «Как отвечают DNS-серверы»', [addressMs, otherMs]));
    }
    final compared = route == ConnRoute.proxy && vpnSiteMs != null && vpnBaseMs != null;
    if (compared && vpnSiteMs! - vpnBaseMs! >= 150 && vpnSiteMs! * 2 > vpnBaseMs! * 3) {
      add(SiteNoteKind.warn,
          tr('Сайт далеко от VPN-сервера: соединение с ним {0} мс, а с проверочным адресом тем же '
          'путём — {1} мс', [vpnSiteMs, vpnBaseMs]));
    }
    if (replyMs == null) {
      add(SiteNoteKind.warn, tr('Соединение открылось, но на запрос сайт не ответил за {0} с', [SiteCheck.timeout.inSeconds]));
    } else if (replyMs! >= 1500 && replyMs! > warm * 2) {
      add(SiteNoteKind.warn,
          tr('Сайт сам долго отвечает: {0} мс после того, как соединение уже установлено. VPN и DNS тут ни при чём', [replyMs]));
    }
    if (!found.any((n) => n.kind == SiteNoteKind.warn)) {
      add(
          SiteNoteKind.ok,
          tr('Задержек по дороге не видно: соединение {0} мс'
          '{1}, '
          'ответ сайта {2} мс', [warm, compared ? tr(' — обычное время пути через VPN-сервер') : '', replyMs ?? '—']));
    }
    return found;
  }

  /// Результат текстом — чтобы скопировать и отправить.
  String get copyText => ['$shown — $summary', for (final n in notes) '  • ${n.text}'].join('\n');

  /// Главная строка вывода: первая, которая не «к сведению».
  SiteNote get mainNote => notes.firstWhere((n) => n.kind != SiteNoteKind.info, orElse: () => notes.first);

  /// Одной строкой для журнала.
  String get summary => stopped
      ? tr('проверка прервана: VPN отключился или переподключился')
      : [
        path,
        if (firstMs != null) tr('соединение {0} мс{1}', [firstMs, warmMs == null ? '' : tr(', повторное {0} мс', [warmMs])]),
        if (replyMs != null) tr('ответ сайта {0} мс', [replyMs]),
        if (addressMs != null) tr('адрес от DNS подключения {0} напрямую {1} мс', [address ?? '', addressMs]).replaceAll('  ', ' '),
        if (otherMs != null && otherAddress != address) tr('адрес от Google DNS {0} {1} мс', [otherAddress ?? '', otherMs]).replaceAll('  ', ' '),
        if (vpnBaseMs != null) tr('тем же путём через VPN: сайт {0} мс, проверочный адрес {1} мс', [vpnSiteMs, vpnBaseMs]),
        if (error != null) error!,
      ].join(', ');
}

/// «Почему тормозит?»: проверка одного сайта так, как к нему ходит браузер, — через локальный
/// HTTP-порт ядра. Показывает путь (через VPN или напрямую) и на что уходит время: поиск адреса,
/// дорога, сам сайт. Правила по приложениям на проверку не действуют — её делает сама SkipIt.
class SiteCheck {
  static const timeout = Duration(seconds: 8);

  /// Имя сайта из того, что вписал человек: без `https://`, пути и порта. null — это не имя сайта.
  static String? hostOf(String input) => nameOf(input)?.host;

  /// То же вместе с именем, как его показывать. Кириллическое имя («сайт.рф») в сеть уходит в
  /// латинской записи (`xn--…`): так его понимают ядро и DNS, — а в окне остаётся как вписано.
  static SiteName? nameOf(String input) {
    var text = input.trim().toLowerCase();
    text = text.replaceFirst(RegExp(r'^[a-z][a-z0-9+.-]*://'), '');
    text = text.split(RegExp(r'[/?#]')).first;
    text = text.replaceFirst(RegExp(r':\d+$'), '');
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
    final labels = text.split('.');
    if (labels.length < 2) return null;
    final ascii = <String>[];
    for (final label in labels) {
      if (!RegExp(r'^[\p{L}\p{N}]([\p{L}\p{N}-]*[\p{L}\p{N}])?$', unicode: true).hasMatch(label)) return null;
      ascii.add(label.runes.every((c) => c < 0x80) ? label : _punycode(label));
    }
    // Зона — не число: иначе это адрес цифрами, а не имя.
    if (ascii.any((l) => l.length > 63) || !RegExp(r'[a-z]').hasMatch(ascii.last) || ascii.last.length < 2) return null;
    return (host: ascii.join('.'), shown: text);
  }

  /// Латинская запись метки имени с нелатинскими буквами (Punycode, RFC 3492): «рф» → `xn--p1ai`.
  static String _punycode(String label) {
    const base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700;
    final input = label.runes.toList();
    final out = StringBuffer();
    for (final c in input) {
      if (c < 0x80) out.writeCharCode(c);
    }
    final basic = out.length;
    if (basic > 0) out.write('-');
    String digit(int d) => String.fromCharCode(d < 26 ? 97 + d : 22 + d);
    int adapt(int delta, int points, bool first) {
      delta = first ? delta ~/ damp : delta ~/ 2;
      delta += delta ~/ points;
      var k = 0;
      while (delta > ((base - tMin) * tMax) ~/ 2) {
        delta ~/= base - tMin;
        k += base;
      }
      return k + (base - tMin + 1) * delta ~/ (delta + skew);
    }

    var n = 0x80, delta = 0, bias = 72, handled = basic;
    while (handled < input.length) {
      final next = input.where((c) => c >= n).reduce((a, b) => a < b ? a : b);
      delta += (next - n) * (handled + 1);
      n = next;
      for (final c in input) {
        if (c < n) delta++;
        if (c != n) continue;
        var q = delta;
        for (var k = base;; k += base) {
          final t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias);
          if (q < t) break;
          out.write(digit(t + (q - t) % (base - t)));
          q = (q - t) ~/ (base - t);
        }
        out.write(digit(q));
        bias = adapt(delta, handled + 1, handled == basic);
        delta = 0;
        handled++;
      }
      delta++;
      n++;
    }
    return 'xn--$out';
  }

  /// Название сервера для подписи под результатом. У сервера, добавленного ссылкой без названия,
  /// названием служит его адрес — такое в подпись не идёт: результат копируют и отправляют, а адрес
  /// VPN-сервера показывать незачем (отчёт для разбора его тоже скрывает). [addresses] — адреса
  /// известных серверов.
  static String stampServer(String name, Iterable<String> addresses) {
    final lower = name.toLowerCase();
    final isAddress = RegExp(r'^\[?[0-9a-z.:-]+\]?:\d+$').hasMatch(lower) || InternetAddress.tryParse(name) != null;
    return isAddress || addresses.any((a) => a.isNotEmpty && lower.contains(a.toLowerCase())) ? '' : name;
  }

  /// Сколько сайтов проверяется за один раз.
  static const maxHosts = 5;

  /// Несколько сайтов через запятую, пробел или с новой строки — без повторов. null — что-то из
  /// вписанного не имя сайта, или сайтов больше [maxHosts].
  static List<SiteName>? hostsOf(String input) {
    final names = <String, SiteName>{};
    for (final part in input.split(RegExp(r'[\s,;]+')).where((p) => p.isNotEmpty)) {
      final name = nameOf(part);
      if (name == null) return null;
      names.putIfAbsent(name.host, () => name);
    }
    return names.isEmpty || names.length > maxHosts ? null : names.values.toList();
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
          error: status.isEmpty ? tr('ядро не ответило') : tr('ядро ответило «{0}»', [status]),
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
      return (readyMs: null, replyMs: null, error: tr('нет ответа за {0} с', [timeout.inSeconds]), localPort: localPort);
    } catch (_) {
      return (
        readyMs: null,
        replyMs: null,
        error: tr('соединение закрылось, не успев установиться'),
        localPort: localPort
      );
    } finally {
      await secure?.close();
      await raw?.close();
    }
  }

  /// Адрес [host] от независимого DNS (Google, по HTTPS), спрошенного напрямую. [sources] — адреса
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
  /// DNS — это DNS ядра. [connOf] по порту, с которого шло соединение, отдаёт запись о нём из журнала ядра: путь и выход.
  /// [keepGoing] отвечает, то ли ещё подключение: после отключения VPN проверка останавливается.
  static Future<void> run(
    SiteReport report, {
    required int port,
    String? auth,
    int? checkPort,
    required String checkHost,
    required bool ownTun,
    List<InternetAddress> sources = const [],
    required ConnEntry? Function(int localPort) connOf,
    bool Function()? keepGoing,
  }) async {
    // Подключение уже не то, при котором проверку начали.
    bool gone() => !(keepGoing?.call() ?? true);
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
      for (var i = 0; i < 3 && first.readyMs != null && !gone(); i++) {
        final again = await viaProxy(report.host, port: port, auth: auth);
        site.add(again);
        report
          ..warmMs = _best(report.warmMs, again.readyMs)
          ..replyMs = _best(report.replyMs, again.replyMs);
      }
      if (gone()) {
        report.stopped = true;
        return;
      }
      // Строка журнала ядра о том, куда ушло соединение, приходит чуть позже него самого.
      await Future.delayed(const Duration(milliseconds: 200));
      report.route = site.map((m) => m.localPort == null ? null : connOf(m.localPort!)).nonNulls.firstOrNull?.route;
      // Первое соединение сравнимо только с повторными, прошедшими тем же выходом.
      final firstWay = first.localPort == null ? null : connOf(first.localPort!)?.outbound;
      if (firstWay != null) report.sameWayMs = byOutbound(site.sublist(1))[firstWay];

      if (report.route == ConnRoute.proxy && checkPort != null && report.firstMs != null) {
        final base = [for (var i = 0; i < 4; i++) await viaProxy(checkHost, port: checkPort)];
        await Future.delayed(const Duration(milliseconds: 200));
        // Сравниваем только то, что шло одним выходом; если общих несколько — тот, где сайт быстрее.
        // Первое соединение с каждой стороны в счёт не идёт: оно «холодное» — с поиском адреса и новой
        // связью с VPN-сервером — и рядом с прогретым выглядело бы как далёкий сайт.
        final siteBy = byOutbound(site.sublist(1)), baseBy = byOutbound(base.sublist(1));
        for (final out in siteBy.keys.where(baseBy.containsKey)) {
          if (report.vpnSiteMs == null || siteBy[out]! < report.vpnSiteMs!) {
            report
              ..vpnSiteMs = siteBy[out]
              ..vpnBaseMs = baseBy[out];
          }
        }
      }
      // Напрямую идём только к сайту, который и так идёт напрямую: адрес сайта, идущего через VPN,
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
