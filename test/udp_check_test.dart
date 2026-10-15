import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/log_store.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/core/ping.dart';
import 'package:skipit/core/site_check.dart';

/// Проверка UDP через сервер на настоящем ядре, без интернета: «сервер» — второе ядро Xray с входом
/// SOCKS (с UDP и без), вместо STUN-сервера Cloudflare — свой ответчик на 127.0.0.1.
void main() {
  final exe = '${Directory.current.path}\\core\\skipit-xray.exe';
  final hasCore = File(exe).existsSync();

  test('вывод проверки UDP словами', () {
    expect(Pinger.udpVerdict(const []), isNull);
    // Пока проверяется хоть один сервер, вывода нет.
    expect(Pinger.udpVerdict(const [40, null]), isNull);
    expect(Pinger.udpVerdict(const [40, 55])!.kind, SiteNoteKind.ok);
    expect(Pinger.udpVerdict(const [40, -1])!.text, startsWith('UDP проходит у 1 из 2 серверов'));
    expect(Pinger.udpVerdict(const [-1, -1])!.kind, SiteNoteKind.bad);
    expect(Pinger.udpVerdict(const [-1])!.text, startsWith('UDP через сервер не проходит'));
    // Проверка не состоялась — это не «UDP не проходит».
    final failed = Pinger.udpVerdict(const [Pinger.udpFailed, Pinger.udpFailed])!;
    expect(failed.kind, SiteNoteKind.warn);
    expect(failed.text, startsWith('Проверить UDP не удалось'));
  });

  test('UDP через сервер: проходит — время ответа, не проходит — -1', () async {
    await AppPaths.init();
    // Ответчик STUN: на запрос Binding Request отвечает Binding Success с тем же номером запроса.
    final stun = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    stun.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = stun.receive();
      if (d == null || d.data.length < 20) return;
      final reply = [0x01, 0x01, 0, 0, ...d.data.sublist(4, 20)];
      stun.send(reply, d.address, d.port);
    });

    Future<Process> server(int port, {required bool udp}) async {
      final dir = await Directory.systemTemp.createTemp('skipit-udp');
      final file = File('${dir.path}\\server.json');
      await file.writeAsString(jsonEncode({
        'log': {'loglevel': 'warning'},
        'inbounds': [
          {
            'protocol': 'socks',
            'listen': '127.0.0.1',
            'port': port,
            'settings': {
              'auth': 'password',
              'accounts': [
                {'user': 'u', 'pass': 'p'},
              ],
              'udp': udp,
            },
          },
        ],
        'outbounds': [
          {'protocol': 'freedom'},
        ],
      }));
      final p = await Process.start(exe, ['run', '-c', file.path]);
      await Future.delayed(const Duration(milliseconds: 800));
      return p;
    }

    final withUdp = await server(18941, udp: true);
    final noUdp = await server(18942, udp: false);
    try {
      final links = [
        'socks://${base64.encode(utf8.encode('u:p'))}@127.0.0.1:18941#with',
        'socks://${base64.encode(utf8.encode('u:p'))}@127.0.0.1:18942#without',
      ];
      final servers = [for (final l in links) LinkParser.parseLink(l)!];
      final results = <String, int>{};
      await Pinger.udpAll(servers, LogBuffer(), (s, ms) => results[s.name] = ms, null, null, '127.0.0.1', stun.port);
      expect(results['with'], greaterThanOrEqualTo(0));
      expect(results['without'], -1);
    } finally {
      withUdp.kill();
      noUdp.kill();
      stun.close();
    }
  }, skip: hasCore ? false : 'ядро Xray не скачано (tools\\setup.ps1)', timeout: const Timeout(Duration(seconds: 60)));
}
