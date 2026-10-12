import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/settings.dart';
import 'log_store.dart';
import 'paths.dart';

/// Один DNS-сервер из конфига подключения и результат его проверки.
class DnsProbe {
  DnsProbe({required this.address, this.port, required this.domains, this.limitMs});

  /// Адрес, как он записан в конфиге ядра (`https://…`, `https+local://…`, `1.1.1.1`).
  final String address;
  final int? port;

  /// Для скольких сайтов сервер назначен; 0 — общий, для всех остальных.
  int domains;

  /// Служебный сервер, который программа добавила сама: у него ядро узнаёт только адреса VPN-сервера
  /// и DNS-серверов «+local» (см. XrayConfig.bootstrapDns), адреса сайтов у него не спрашиваются.
  bool service = false;

  /// Сколько ядро ждёт ответа этого сервера (timeoutMs из конфига), если задано.
  final int? limitMs;

  /// Пометка «+local»: ядро идёт к серверу само, мимо правил, — то есть напрямую.
  bool get local => address.contains('+local://');

  String get label => port == null ? address : '$address:$port';

  bool done = false;

  /// Время ответа на первый запрос (с установкой соединения) и на следующий; null — ответа не было.
  int? firstMs, nextMs;

  /// За сколько миллисекунд мимо VPN открывается соединение с адресами, которые сервер назвал в
  /// ответ на пробные запросы (худший из них); null — не мерили или адреса не ответили. Сервер может
  /// отвечать быстро, но называть далёкие узлы сайтов — тогда всё, что идёт мимо VPN, ждёт дольше.
  int? reachMs;

  /// Сервер из той же проверки, чьи адреса заметно ближе, и его время (см. [DnsCheck.compare]).
  String? nearerLabel;
  int? nearerMs;

  bool get far => nearerMs != null;

  /// Каким путём запрос ушёл из основного ядра; у серверов «+local» не заполняется.
  ConnRoute? route;
  String? error;

  bool get ok => firstMs != null || nextMs != null;

  /// Ответ пришёл позже, чем ядро готово ждать этот сервер.
  bool get slow => limitMs != null && [firstMs, nextMs].any((ms) => ms != null && ms > limitMs!);

  String get path => local
      ? 'напрямую, мимо правил'
      : switch (route) {
          ConnRoute.proxy => 'через VPN',
          ConnRoute.direct => 'напрямую',
          ConnRoute.block => 'заблокирован правилом',
          _ => 'путь не определён',
        };

  String get result {
    String ms(int? value) => value == null ? 'без ответа' : '$value мс';
    return error ?? (ok ? 'первый запрос ${ms(firstMs)}, следующий ${ms(nextMs)}' : 'не ответил за ${DnsCheck.timeout.inSeconds} с');
  }
}

/// Проверка DNS-серверов подключения «как их видит ядро»: на каждый сервер запускается своя временная
/// копия Xray, у которой он единственный, и программа задаёт ей обычный DNS-запрос, замеряя время.
/// К серверу копия ходит тем же путём, что и основное ядро: через его вход проверки DNS
/// (XrayConfig.addDnsCheckInbound), а к серверам «+local» — напрямую через настоящую сетевую карту.
class DnsCheck {
  static const timeout = Duration(seconds: 5);

  /// DNS-серверы из готового конфига ядра, без повторов. [service] — адреса служебных серверов.
  static List<DnsProbe> servers(Map<String, dynamic> config, {Set<String> service = const {}}) {
    final probes = <String, DnsProbe>{};
    for (final s in ((config['dns'] as Map?)?['servers'] as List? ?? const [])) {
      final address = s is Map ? s['address'] : s;
      if (address is! String || address == 'localhost' || address == 'fakedns') continue;
      final port = s is Map && s['port'] is int ? s['port'] as int : null;
      final domains = s is Map ? (s['domains'] as List? ?? const []).length : 0;
      final limit = s is Map && s['timeoutMs'] is int ? s['timeoutMs'] as int : null;
      final known = probes['$address:$port'];
      if (known == null) {
        probes['$address:$port'] = DnsProbe(address: address, port: port, domains: domains, limitMs: limit)
          ..service = service.contains(address);
      } else {
        // Один и тот же сервер может стоять дважды — для разных списков сайтов.
        known.domains = known.domains == 0 || domains == 0 ? 0 : known.domains + domains;
      }
    }
    return probes.values.toList();
  }

  /// Имя настоящей сетевой карты: первая с адресом IPv4, кроме адаптеров VPN [skip].
  static Future<String?> physicalNic(List<String> skip) async {
    try {
      final all = await NetworkInterface.list(type: InternetAddressType.IPv4);
      return all.where((i) => !skip.contains(i.name)).firstOrNull?.name;
    } catch (_) {
      return null;
    }
  }

  /// Конфиг временного ядра: вход DNS на [port], единственный DNS-сервер — проверяемый.
  /// [checkPort] и [password] — вход проверки DNS основного ядра и его пароль, [nic] — сетевая карта
  /// для серверов «+local» (нужна, пока маршрут Windows ведёт в адаптер VPN).
  static Map<String, dynamic> helperConfig(DnsProbe probe,
      {required int port, required int checkPort, required String password, String? nic}) {
    // Пометка «+local» снимается: у временного ядра запрос идёт через выход, привязанный к сетевой карте.
    final address = probe.address.replaceFirst('+local://', '://');
    return {
      'log': {'loglevel': 'warning'},
      'dns': {
        'tag': 'probe',
        'servers': [
          probe.port == null ? address : {'address': address, 'port': probe.port},
        ],
        'queryStrategy': 'UseIPv4',
        'disableCache': true,
      },
      'inbounds': [
        {
          'tag': 'in',
          'protocol': 'dokodemo-door',
          'listen': '127.0.0.1',
          'port': port,
          'settings': {'address': '127.0.0.1', 'port': 53, 'network': 'udp'},
        },
      ],
      'outbounds': [
        if (probe.local)
          {
            'tag': 'out',
            'protocol': 'freedom',
            'streamSettings': {
              'sockopt': {'domainStrategy': 'UseIPv4', if (nic != null) 'interface': nic},
            },
          }
        else
          {
            'tag': 'out',
            'protocol': 'socks',
            'settings': {
              'servers': [
                {
                  'address': '127.0.0.1',
                  'port': checkPort,
                  'users': [
                    {'user': AppSettings.serviceUser, 'pass': password},
                  ],
                },
              ],
            },
          },
        {'tag': 'dns', 'protocol': 'dns'},
      ],
      'routing': {
        'rules': [
          {'inboundTag': ['in'], 'outboundTag': 'dns'},
          {'inboundTag': ['probe'], 'outboundTag': 'out'},
        ],
      },
    };
  }

  /// Запрос «какой адрес у [name]» в формате DNS.
  static Uint8List query(String name, int id) => Uint8List.fromList([
        id >> 8, id & 0xff, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
        for (final part in name.split('.')) ...[part.length, ...ascii.encode(part)],
        0, 0, 1, 0, 1,
      ]);

  /// Адреса IPv4 из ответа DNS.
  static List<InternetAddress> addresses(Uint8List data) {
    final found = <InternetAddress>[];
    if (data.length < 12) return found;
    // Имя в записи — цепочка меток или двухбайтовая ссылка на имя, которое уже встречалось.
    int skipName(int at) {
      while (at < data.length) {
        final len = data[at];
        if (len == 0) return at + 1;
        if (len & 0xc0 == 0xc0) return at + 2;
        at += len + 1;
      }
      return at;
    }

    var at = 12;
    for (var q = data[4] << 8 | data[5]; q > 0; q--) {
      at = skipName(at) + 4;
    }
    for (var a = data[6] << 8 | data[7]; a > 0; a--) {
      at = skipName(at);
      if (at + 10 > data.length) break;
      final type = data[at] << 8 | data[at + 1], size = data[at + 8] << 8 | data[at + 9];
      at += 10;
      if (at + size > data.length) break;
      if (type == 1 && size == 4) found.add(InternetAddress.fromRawAddress(data.sublist(at, at + 4)));
      at += size;
    }
    return found;
  }

  /// За сколько миллисекунд открывается соединение с [ip] (порт 443), лучшее из двух раз; null — не
  /// открылось. [sources] — адреса настоящих сетевых карт (Pinger.physicalSources): пока маршрут Windows
  /// ведёт в адаптер VPN, без привязки к карте на соединение ответил бы сам адаптер.
  static Future<int?> reach(InternetAddress ip, List<InternetAddress> sources) async {
    int? best;
    // Второй раз — только если первый удался: адрес, который не отвечает, ждать дважды незачем.
    for (var i = 0; i < 2 && (i == 0 || best != null); i++) {
      for (final source in sources.isEmpty ? const <InternetAddress?>[null] : sources) {
        if (source != null && source.type != ip.type) continue;
        final watch = Stopwatch()..start();
        try {
          final socket =
              await Socket.connect(ip, 443, sourceAddress: source, timeout: const Duration(seconds: 3));
          socket.destroy();
          final ms = watch.elapsedMilliseconds;
          if (best == null || ms < best) best = ms;
          break;
        } catch (_) {
          // Через эту карту не вышло — пробуем следующую.
        }
      }
    }
    return best;
  }

  /// Отмечает серверы, чьи адреса заметно дальше, чем у лучшего в этой проверке: больше чем в полтора
  /// раза и не меньше чем на 60 мс.
  static void compare(List<DnsProbe> probes) {
    final measured = probes.where((p) => p.reachMs != null).toList();
    if (measured.length < 2) return;
    final best = measured.reduce((a, b) => a.reachMs! <= b.reachMs! ? a : b);
    for (final p in measured) {
      final far = p.reachMs! - best.reachMs! >= 60 && p.reachMs! * 2 > best.reachMs! * 3;
      p.nearerLabel = far ? best.label : null;
      p.nearerMs = far ? best.reachMs : null;
    }
  }

  /// Сколько миллисекунд сервер на [port] отвечал на запрос адреса [name]; null — ответа с адресом нет.
  /// В [into] складываются адреса из ответа.
  static Future<int?> ask(int port, String name, int id, {List<InternetAddress>? into}) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final done = Completer<int?>();
    final watch = Stopwatch()..start();
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final data = socket.receive()?.data;
      if (data == null || data.length < 12 || data[0] != id >> 8 || data[1] != id & 0xff || done.isCompleted) return;
      // Ответ без ошибки (код 0) и хотя бы с одной записью.
      final ok = data[3] & 0x0f == 0 && (data[6] << 8 | data[7]) > 0;
      if (ok) into?.addAll(addresses(data));
      done.complete(ok ? watch.elapsedMilliseconds : null);
    }, onError: (_) {
      if (!done.isCompleted) done.complete(null);
    });
    socket.send(query(name, id), InternetAddress.loopbackIPv4, port);
    final ms = await done.future.timeout(timeout, onTimeout: () => null);
    socket.close();
    return ms;
  }

  /// Проверяет один сервер и записывает результат в [probe]. [sources] — см. [reach]. [measureReach] —
  /// мерить ли, далеко ли названные сервером адреса (спрашивается после запросов, когда путь к серверу
  /// уже известен): для этого программа сама идёт к ним мимо VPN. При включённом Kill Switch этого делать
  /// нельзя, а у сервера, к которому запросы идут через VPN, незачем — его адреса и должны быть ближе
  /// к VPN-серверу.
  static Future<void> run(DnsProbe probe,
      {required int checkPort,
      required String password,
      String? nic,
      List<InternetAddress> sources = const [],
      bool Function()? measureReach}) async {
    Process? core;
    try {
      // Свободный порт для входа временного ядра.
      final free = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = free.port;
      free.close();

      final process = core = await Process.start(AppPaths.xrayExe, ['run', '-c', 'stdin:'],
          workingDirectory: AppPaths.coreDir.path);
      final started = Completer<bool>();
      void feed(String line) {
        if (line.contains('core: Xray') && line.contains('started') && !started.isCompleted) started.complete(true);
      }

      const decoder = Utf8Decoder(allowMalformed: true);
      process.stdout.transform(decoder).transform(const LineSplitter()).listen(feed);
      process.stderr.transform(decoder).transform(const LineSplitter()).listen(feed);
      unawaited(process.exitCode.then((_) {
        if (!started.isCompleted) started.complete(false);
      }));
      process.stdin.add(utf8
          .encode(jsonEncode(helperConfig(probe, port: port, checkPort: checkPort, password: password, nic: nic))));
      await process.stdin.close();
      if (!await started.future.timeout(timeout, onTimeout: () => false)) {
        probe.error = 'не удалось запустить проверку';
        return;
      }
      probe.firstMs = await ask(port, 'www.google.com', 0x5101);
      final wiki = <InternetAddress>[], akamai = <InternetAddress>[];
      probe.nextMs = await ask(port, 'www.wikipedia.org', 0x5102, into: wiki);
      // Далеко ли адреса, которые сервер называет: по двум именам, чьи узлы стоят в разных странах.
      // Служебный сервер адресов сайтов не выдаёт — его не меряем.
      if (probe.ok && !probe.service && (measureReach?.call() ?? true)) {
        await ask(port, 'www.microsoft.com', 0x5103, into: akamai);
        for (final ip in [wiki.firstOrNull, akamai.firstOrNull].nonNulls) {
          final ms = await reach(ip, sources);
          if (ms != null && ms > (probe.reachMs ?? -1)) probe.reachMs = ms;
        }
      }
    } catch (e) {
      probe.error = 'не удалось запустить проверку: $e';
    } finally {
      core?.kill();
      probe.done = true;
    }
  }
}
