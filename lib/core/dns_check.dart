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

  /// Служебный сервер, который программа добавила сама: у него ядро узнаёт только адрес VPN-сервера
  /// (см. XrayConfig.bootstrapDns), адреса сайтов у него не спрашиваются.
  bool service = false;

  /// Сколько ядро ждёт ответа этого сервера (timeoutMs из конфига), если задано.
  final int? limitMs;

  /// Пометка «+local»: ядро идёт к серверу само, мимо правил, — то есть напрямую.
  bool get local => address.contains('+local://');

  String get label => port == null ? address : '$address:$port';

  bool done = false;

  /// Время ответа на первый запрос (с установкой соединения) и на следующий; null — ответа не было.
  int? firstMs, nextMs;

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

  /// Сколько миллисекунд сервер на [port] отвечал на запрос адреса [name]; null — ответа с адресом нет.
  static Future<int?> ask(int port, String name, int id) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final done = Completer<int?>();
    final watch = Stopwatch()..start();
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final data = socket.receive()?.data;
      if (data == null || data.length < 12 || data[0] != id >> 8 || data[1] != id & 0xff || done.isCompleted) return;
      // Ответ без ошибки (код 0) и хотя бы с одной записью.
      done.complete(data[3] & 0x0f == 0 && (data[6] << 8 | data[7]) > 0 ? watch.elapsedMilliseconds : null);
    }, onError: (_) {
      if (!done.isCompleted) done.complete(null);
    });
    socket.send(query(name, id), InternetAddress.loopbackIPv4, port);
    final ms = await done.future.timeout(timeout, onTimeout: () => null);
    socket.close();
    return ms;
  }

  /// Проверяет один сервер и записывает результат в [probe].
  static Future<void> run(DnsProbe probe, {required int checkPort, required String password, String? nic}) async {
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
      probe.nextMs = await ask(port, 'www.wikipedia.org', 0x5102);
    } catch (e) {
      probe.error = 'не удалось запустить проверку: $e';
    } finally {
      core?.kill();
      probe.done = true;
    }
  }
}
