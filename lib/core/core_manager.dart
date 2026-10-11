import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'log_store.dart';
import 'paths.dart';
import 'util.dart';

export 'log_store.dart';

class CoreException implements Exception {
  CoreException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Один управляемый процесс ядра (xray или sing-box).
class CoreProcess {
  CoreProcess(this.name, this.log);

  final String name;
  final LogBuffer log;
  Process? _process;
  bool _stopping = false;
  void Function(int exitCode)? onUnexpectedExit;

  /// Перехват строк вывода ядра: true — строка разобрана и в общий журнал не идёт.
  bool Function(String line)? intercept;

  /// Команды раскраски текста для консоли (sing-box красит уровень строки и номер соединения).
  static final _colorCodes = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');

  /// Дата и время, которые Xray ставит в начале своих строк («2026/10/05 02:23:55.652302 »).
  /// Журнал сам помечает каждую строку временем, а день виден по отрезку.
  static final _ownTime = RegExp(r'^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}(\.\d+)? ');

  /// Строка ядра в том виде, в каком она идёт в журнал: без команд раскраски и без своего времени.
  static String clean(String line) => line.replaceAll(_colorCodes, '').replaceFirst(_ownTime, '');

  void _feed(String line) {
    line = clean(line);
    if (intercept?.call(line) ?? false) return;
    log.add(name, line);
  }

  bool get running => _process != null;
  int? get pid => _process?.pid;

  /// [input] — текст, который ядро прочитает со стандартного входа (конфиг: так он не лежит на диске).
  Future<void> start(String exe, List<String> args, {Map<String, String>? env, String? input}) async {
    if (!File(exe).existsSync()) {
      throw CoreException('Не найден $exe. Запустите tools\\setup.ps1, чтобы скачать ядра.');
    }
    _stopping = false;
    final p = await Process.start(exe, args,
        workingDirectory: File(exe).parent.path, environment: env);
    _process = p;
    if (input != null) {
      // Ядро могло завершиться, не дочитав (ошибка запуска) — тогда запись в закрытый вход не сбой.
      unawaited(() async {
        try {
          p.stdin.add(utf8.encode(input));
          await p.stdin.flush();
          await p.stdin.close();
        } catch (_) {}
      }());
    }
    // Строка в другой кодировке (сообщение Windows) не должна обрывать чтение журнала ядра.
    const decoder = Utf8Decoder(allowMalformed: true);
    p.stdout.transform(decoder).transform(const LineSplitter()).listen(_feed);
    p.stderr.transform(decoder).transform(const LineSplitter()).listen(_feed);
    unawaited(p.exitCode.then((code) {
      if (!identical(_process, p)) return;
      _process = null;
      log.add(name, '[$name завершился с кодом $code]');
      if (!_stopping) onUnexpectedExit?.call(code);
    }));
  }

  Future<void> stop() async {
    final p = _process;
    if (p == null) return;
    _stopping = true;
    _process = null;
    p.kill();
    await p.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
      Process.killPid(p.pid, ProcessSignal.sigkill);
      return -1;
    });
  }
}

Future<bool> waitForPort(int port, {Duration timeout = const Duration(seconds: 6), bool Function()? alive}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (alive != null && !alive()) return false;
    try {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: const Duration(milliseconds: 300));
      s.destroy();
      return true;
    } catch (_) {
      await Future.delayed(const Duration(milliseconds: 150));
    }
  }
  return false;
}

/// Счётчики трафика: сколько ушло через VPN и сколько напрямую.
/// Основной источник — Stats API Xray (`xray api statsquery`): у каждого выхода свой счётчик.
/// Когда TUN держит sing-box, часть трафика он выпускает напрямую сам (программы из правил по
/// приложениям, локальная сеть) — до Xray она не доходит и берётся из списка соединений sing-box.
class TrafficStats {
  int vpnUp = 0, vpnDown = 0;
  int directUp = 0, directDown = 0;
  int upSpeed = 0, downSpeed = 0;

  int get up => vpnUp + directUp;
  int get down => vpnDown + directDown;

  var _xrayDirectUp = 0, _xrayDirectDown = 0;
  var _tunDirectUp = 0, _tunDirectDown = 0;

  DateTime? _speedAt;
  var _speedUp = 0, _speedDown = 0;

  /// Сколько уже учтено по каждому открытому соединению sing-box.
  final _tunConns = <String, (int, int)>{};

  static final _http = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionTimeout = const Duration(milliseconds: 500);

  void reset() {
    vpnUp = vpnDown = directUp = directDown = upSpeed = downSpeed = 0;
    _xrayDirectUp = _xrayDirectDown = _tunDirectUp = _tunDirectDown = 0;
    _speedAt = null;
    _speedUp = _speedDown = 0;
    _tunConns.clear();
  }

  /// [routes] — куда ведёт каждый выход Xray, [skip] — выходы, которые в счёт не идут.
  /// [tunPort] и [tunSecret] — адрес списка соединений sing-box, если TUN держит он.
  /// [xray] false — счётчики Xray не запрашиваются: на каждый запрос запускается процесс ядра, и при
  /// спрятанном окне это лишняя работа (счётчики накопительные — догонятся при следующем запросе).
  /// sing-box спрашивается всегда: он помнит только открытые соединения, пропуск потерял бы закрытые.
  Future<void> poll(
    int apiPort,
    Map<String, ConnRoute> routes, {
    Set<String> skip = const {},
    int? tunPort,
    String tunSecret = '',
    bool xray = true,
  }) async {
    if (xray) {
      try {
        final r = await Process.run(AppPaths.xrayExe,
            ['api', 'statsquery', '--server=127.0.0.1:$apiPort', '-pattern', 'outbound>>>'],
            stdoutEncoding: utf8);
        if (r.exitCode == 0) {
          final data = jsonDecode(r.stdout as String) as Map<String, dynamic>;
          applyXray(data['stat'] as List? ?? const [], routes, skip: skip);
        }
      } catch (_) {}
    }
    if (tunPort != null) {
      try {
        final req = await _http.getUrl(Uri.parse('http://127.0.0.1:$tunPort/connections'));
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $tunSecret');
        final res = await req.close().timeout(const Duration(milliseconds: 800));
        final body = await utf8.decodeStream(res).timeout(const Duration(milliseconds: 800));
        if (res.statusCode == 200) applySingbox(jsonDecode(body) as Map<String, dynamic>);
      } catch (_) {}
    }
    if (xray) markSpeed(DateTime.now());
  }

  /// Скорость — прирост с прошлого замера, делённый на прошедшее время: замеры идут не строго раз
  /// в секунду (а после спрятанного окна — с большим перерывом).
  void markSpeed(DateTime now) {
    final at = _speedAt;
    final ms = at == null ? 1000 : now.difference(at).inMilliseconds.clamp(200, 1 << 31);
    upSpeed = up > _speedUp ? (up - _speedUp) * 1000 ~/ ms : 0;
    downSpeed = down > _speedDown ? (down - _speedDown) * 1000 ~/ ms : 0;
    _speedAt = now;
    _speedUp = up;
    _speedDown = down;
  }

  /// Счётчики выходов Xray: выходы-«freedom» — напрямую, блокировка и DNS не считаются, остальное — VPN.
  void applyXray(List stat, Map<String, ConnRoute> routes, {Set<String> skip = const {}}) {
    var vu = 0, vd = 0, du = 0, dd = 0;
    for (final s in stat) {
      // Имя счётчика: outbound>>>тег>>>traffic>>>uplink.
      final parts = '${s['name'] ?? ''}'.split('>>>');
      if (parts.length != 4 || parts[1] == 'api' || skip.contains(parts[1])) continue;
      final value = asInt(s['value']) ?? 0;
      final upload = parts[3] == 'uplink';
      switch (routes[parts[1]] ?? ConnRoute.proxy) {
        case ConnRoute.proxy:
          upload ? vu += value : vd += value;
        case ConnRoute.direct:
          upload ? du += value : dd += value;
        case ConnRoute.block || ConnRoute.dns:
          break;
      }
    }
    vpnUp = vu;
    vpnDown = vd;
    _xrayDirectUp = du;
    _xrayDirectDown = dd;
    _sum();
  }

  /// Соединения, которые sing-box выпустил напрямую сам. Соединения ядер не считаются:
  /// это тот же трафик, что уже посчитал Xray на своих выходах.
  void applySingbox(Map<String, dynamic> data) {
    final seen = <String>{};
    for (final c in (data['connections'] as List? ?? const [])) {
      if (c is! Map || !(c['chains'] as List? ?? const []).contains('direct')) continue;
      final path = '${(c['metadata'] as Map?)?['processPath'] ?? ''}'.toLowerCase();
      if (path.endsWith('skipit-xray.exe') || path.endsWith('skipit-sing-box.exe')) continue;
      final id = '${c['id']}';
      final up = asInt(c['upload']) ?? 0, down = asInt(c['download']) ?? 0;
      final was = _tunConns[id] ?? (0, 0);
      if (up > was.$1) _tunDirectUp += up - was.$1;
      if (down > was.$2) _tunDirectDown += down - was.$2;
      _tunConns[id] = (up, down);
      seen.add(id);
    }
    // Закрытые соединения из списка пропадают — их итог уже прибавлен.
    _tunConns.removeWhere((id, _) => !seen.contains(id));
    _sum();
  }

  void _sum() {
    directUp = _xrayDirectUp + _tunDirectUp;
    directDown = _xrayDirectDown + _tunDirectDown;
  }
}
