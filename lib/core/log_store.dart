import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class LogLine {
  LogLine(this.source, this.text, [DateTime? time]) : time = time ?? DateTime.now();
  final DateTime time;
  final String source;
  final String text;

  /// Сколько раз подряд ядро написало эту же строку (см. [LogBuffer.add]): в журнале она одна, со счётчиком.
  int repeats = 1;

  /// Когда строка повторилась в последний раз.
  late DateTime lastSeen = time;

  /// Время каждого повтора (без первого появления — оно в [time]). Хранятся только последние
  /// [maxRepeatTimes]: строка может повторяться тысячи раз.
  final repeatTimes = <DateTime>[];
  static const maxRepeatTimes = 200;

  /// Ещё один повтор строки.
  void repeated(DateTime at) {
    repeats += 1;
    lastSeen = at;
    repeatTimes.add(at);
    if (repeatTimes.length > maxRepeatTimes) repeatTimes.removeAt(0);
  }

  /// 2 — ошибка, 1 — предупреждение, 0 — обычная строка.
  late final int level = _levelOf(text);

  /// Пометка уровня, которую ставит само ядро: `[Warning]` у Xray, `WARN` в начале строки у sing-box.
  static final _coreLevel = RegExp(r'\[(debug|info|warning|error)\]|^\s*(trace|debug|info|warn|error|fatal|panic)\b');

  /// У подключения несколько общих DNS-серверов: отказ одного — не сбой, ядро спросит следующий.
  /// Ставится при подключении.
  static bool dnsHasSpare = false;

  static int _levelOf(String text) {
    // NOERROR в ответе DNS значит «ошибки нет» — слово «error» внутри него не в счёт.
    final t = text.toLowerCase().replaceAll('noerror', '');
    // Не ответил один DNS-сервер, а за ним есть запасной: сайт всё равно откроется — это предупреждение.
    if (dnsHasSpare && t.contains('app/dns: failed to retrieve response')) return 1;
    // Программа спросила имя сайта, которого не существует. Ядро пишет это как ошибку, но VPN тут
    // ни при чём — оставляем предупреждением.
    if (t.contains('failed to resolve ip') && t.contains('rcode: 3')) return 1;
    // Ядро пишет «Error» и тогда, когда программа на компьютере просто закрыла своё соединение через
    // адаптер. Это не сбой VPN — в счётчик ошибок такие строки не идут.
    if (t.contains('proxy/tun: connection reset by peer') ||
        t.contains('proxy/tun: connection was refused') ||
        t.contains('proxy/tun: operation timed out')) {
      return 0;
    }
    // Проверка интернета по IPv6, которую делает сама Windows: при выключенном IPv6 она не проходит всегда.
    if (t.contains('ipv6.msftncsi.com') || t.contains('ipv6.msftconnecttest.com')) return 0;
    // Ядра сами помечают уровень строки — ему и верим. Иначе предупреждение из модуля «common/errors»
    // или обычная строка со словом «error» в адресе сайта считались бы ошибкой.
    final own = _coreLevel.firstMatch(t);
    if (own != null) {
      return switch (own.group(1) ?? own.group(2)) {
        'error' || 'fatal' || 'panic' => 2,
        // Xray пишет «[Warning] core: Xray … started» при обычном запуске — это не предупреждение.
        'warning' || 'warn' => t.contains('started') ? 0 : 1,
        _ => 0,
      };
    }
    if (t.contains('error') || t.contains('fatal') || t.contains('panic') || t.contains('ошибк') ||
        t.contains('сбой') || t.contains('не удалось')) {
      return 2;
    }
    // Xray пишет «[Warning] core: Xray … started» при обычном запуске — это не предупреждение.
    if (t.contains('warn') && !t.contains('started')) return 1;
    return 0;
  }
}

/// Куда ядро отправило соединение.
enum ConnRoute { proxy, direct, block, dns }

/// Одно соединение программы, как его записало ядро Xray: куда шло и каким путём отправлено.
class ConnEntry {
  ConnEntry({
    required this.network,
    required this.host,
    required this.port,
    required this.inbound,
    required this.outbound,
    required this.route,
    this.source = '',
    DateTime? time,
  }) : time = time ?? DateTime.now();

  final DateTime time;

  /// Откуда пришло соединение: локальный адрес и порт программы (`172.19.0.1:63662`).
  final String source;

  /// Ядро не смогло узнать, какая программа открыла это соединение, — правила по приложениям
  /// к нему не применились, оно пошло общим путём.
  bool unknownProcess = false;

  /// tcp или udp.
  final String network;
  final String host;
  final int port;

  /// Теги входа и выхода из конфига ядра (`socks`, `proxy`, `direct`…).
  final String inbound;
  final String outbound;
  final ConnRoute route;

  static final _access = RegExp(r'from (\S+) accepted (\S+)(?: \[(.+?)\])?');

  /// Адрес без приставки сети: `udp:172.19.0.1:63662` → `172.19.0.1:63662`.
  static String bareAddress(String address) => address.replaceFirst(RegExp(r'^(tcp|udp):'), '');
  static final _target = RegExp(r'^(?:(tcp|udp):)?(.+):(\d+)$');

  /// Разбирает строку журнала доступа Xray:
  /// `… from 127.0.0.1:51234 accepted tcp:example.com:443 [socks -> proxy]`.
  /// Обычный HTTP через прокси-порт ядро пишет полным адресом страницы
  /// (`accepted http://example.com/path?query`) — от него остаётся только сайт и порт.
  /// [routes] — что означает каждый выход конфига. null — это не строка о соединении.
  static ConnEntry? tryParse(String line, Map<String, ConnRoute> routes) {
    final m = _access.firstMatch(line);
    if (m == null) return null;
    final tags = (m.group(3) ?? '').split(RegExp(r'\s*(?:->|>>)\s*'));
    final outbound = tags.length > 1 ? tags.last.trim() : '';
    var network = 'tcp', host = m.group(2)!, port = 0;
    final url = host.contains('://') ? Uri.tryParse(host) : null;
    // HTTPS через прокси-порт (CONNECT) записан как //example.com:443.
    if (host.startsWith('//')) host = host.substring(2);
    final t = _target.firstMatch(host);
    if (url != null && url.host.isNotEmpty) {
      host = url.host;
      port = url.port;
    } else if (t != null) {
      network = t.group(1) ?? 'tcp';
      host = t.group(2)!;
      port = int.parse(t.group(3)!);
    }
    return ConnEntry(
      network: network,
      host: host,
      port: port,
      inbound: tags.first.trim(),
      outbound: outbound,
      route: routes[outbound] ?? ConnRoute.proxy,
      source: bareAddress(m.group(1)!),
    );
  }
}

/// Соединения с одним и тем же адресом, отправленные одним путём: в списке они показаны одной
/// строкой со счётчиком.
class ConnGroup {
  ConnGroup(this.key);

  /// Сеть, адрес, порт и путь — то, что у соединений группы общее.
  final String key;

  /// Соединения группы, от старых к новым.
  final items = <ConnEntry>[];
  ConnEntry get last => items.last;
}

/// Склеивает повторы. Группы идут по времени последнего соединения: к чему обращались только что — в конце.
List<ConnGroup> groupConnections(Iterable<ConnEntry> conns) {
  final groups = <String, ConnGroup>{};
  for (final c in conns) {
    final key = '${c.network}:${c.host}:${c.port}>${c.route.name}';
    // Группа переставляется в конец: порядок словаря — порядок последних обращений.
    final g = groups.remove(key) ?? ConnGroup(key);
    g.items.add(c);
    groups[key] = g;
  }
  return groups.values.toList();
}

/// Отрезок журнала: одно подключение к серверу или время без подключения между ними.
class LogSession {
  LogSession({
    required this.id,
    required this.start,
    required this.connection,
    required this.title,
    this.detail = '',
    this.file,
  }) : end = start;

  /// Имя файла без расширения: `2026-10-01_15-13-41_123` (по нему же считается срок хранения).
  final String id;
  final DateTime start;
  DateTime end;

  /// true — подключение к серверу, false — события программы без подключения.
  final bool connection;

  /// Имя сервера (для подключения) или подпись отрезка.
  final String title;

  /// Режим подключения.
  final String detail;
  final File? file;

  /// Продолжения файла: когда [file] заполнен, запись идёт в следующую часть (`<id>-2.log`, `<id>-3.log`…).
  final parts = <File>[];

  /// Все файлы отрезка по порядку.
  List<File> get files => [if (file != null) file!, ...parts];

  int count = 0;
  int warnings = 0;
  int errors = 0;

  /// Сейчас в этот отрезок пишутся строки.
  bool live = false;

  /// Строки отрезка; null — ещё не прочитаны с диска (см. [LogBuffer.load]).
  List<LogLine>? lines;

  /// Соединения программ за этот отрезок. Живут только в памяти: на диск список сайтов не пишется.
  final connections = <ConnEntry>[];

  /// Сколько соединений было за отрезок по каждому пути. В [connections] остаются только последние
  /// [LogBuffer.maxConnections], счёт же идёт по всем.
  final connectionCounts = <ConnRoute, int>{};

  int get connectionsTotal => connectionCounts.values.fold(0, (a, b) => a + b);

  /// Для скольких соединений ядро не узнало программу (см. [ConnEntry.unknownProcess]).
  int unknownProcess = 0;

  RandomAccessFile? _out;
  int _written = 0;

  void _count(LogLine l) {
    count++;
    if (l.level == 2) errors++;
    if (l.level == 1) warnings++;
    if (l.time.isAfter(end)) end = l.time;
  }
}

/// Журнал программы и ядер, разбитый на отрезки по подключениям. Каждый отрезок — отдельный файл
/// в папке `logs`; файлы старше [keepDays] дней удаляются.
class LogBuffer extends ChangeNotifier {
  /// Сколько дней хранится журнал каждого дня.
  static const keepDays = 5;

  /// Больше строк одного отрезка в памяти не держим (при уровне debug ядро пишет очень много).
  static const maxLines = 5000;

  /// Столько последних соединений помним в одном отрезке.
  static const maxConnections = 2000;

  /// Размер одной части файла отрезка. Заполнилась — запись продолжается в следующей части.
  @visibleForTesting
  static int fileLimit = 4 * 1024 * 1024;

  /// Частей у одного отрезка не больше этого. Дальше строки ядер в файл не идут (в окне они есть),
  /// а строки самой программы — подключение, ошибки, Kill Switch — пишутся всегда.
  static const maxParts = 5;

  static final _partName = RegExp(r'^(.*_\d{3})-(\d+)$');

  /// Все отрезки, от старых к новым.
  final sessions = <LogSession>[];
  LogSession? _current;
  Directory? _dir;

  /// Отрезок, в который сейчас идёт запись (null — пока не было ни одной строки).
  LogSession? get current => _current;

  /// Строки текущего отрезка.
  List<LogLine> get lines => _current?.lines ?? const [];

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _idFor(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}_${_two(t.hour)}-${_two(t.minute)}-'
      '${_two(t.second)}_${t.millisecond.toString().padLeft(3, '0')}';

  /// Подключает папку с файлами журнала: удаляет просроченные и поднимает список прошлых отрезков.
  /// Без вызова журнал живёт только в памяти (так работают тесты).
  Future<void> open(Directory dir) async {
    try {
      // Папка подключается сразу (синхронно): строки, пришедшие, пока читается история, уже пишутся в файлы.
      dir.createSync(recursive: true);
      _dir = dir;
      _purgeOld();
      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.log')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      final past = <LogSession>[];
      final continued = <LogSession>[];
      for (final f in files) {
        if (sessions.any((s) => s.files.any((x) => x.path == f.path))) continue;
        final s = await _readSession(f, keepLines: false);
        if (s == null) continue;
        (_partName.hasMatch(s.id) ? continued : past).add(s);
      }
      // Части приклеиваются к своему отрезку: в списке подключение остаётся одной строкой.
      continued.sort((a, b) => _partNumber(a.id).compareTo(_partNumber(b.id)));
      for (final part in continued) {
        final base = _partName.firstMatch(part.id)!.group(1);
        final owner = past.where((s) => s.id == base).firstOrNull;
        if (owner == null) {
          past.add(part);
          continue;
        }
        owner
          ..parts.add(part.file!)
          ..count += part.count
          ..warnings += part.warnings
          ..errors += part.errors;
        if (part.end.isAfter(owner.end)) owner.end = part.end;
      }
      past.sort((a, b) => a.id.compareTo(b.id));
      sessions.insertAll(0, past);
      notifyListeners();
    } catch (_) {
      // Папка недоступна — журнал остаётся в памяти.
    }
  }

  static int _partNumber(String id) => int.parse(_partName.firstMatch(id)!.group(2)!);

  /// День из имени файла: журнал дня живёт [keepDays] дней, потом удаляется целиком.
  void _purgeOld() {
    final dir = _dir;
    if (dir == null) return;
    final now = DateTime.now();
    final limit = DateTime(now.year, now.month, now.day).subtract(const Duration(days: keepDays));
    try {
      for (final f in dir.listSync().whereType<File>()) {
        final m = RegExp(r'(\d{4})-(\d{2})-(\d{2})_[\d_-]+\.log$').firstMatch(f.path);
        if (m == null) continue;
        final day = DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
        if (day.isBefore(limit)) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
    sessions.removeWhere((s) => !s.live && s.file != null && !s.file!.existsSync());
  }

  /// Читает файл отрезка: заголовок и строки (для списка достаточно счётчиков — [keepLines] false).
  static Future<LogSession?> _readSession(File f, {required bool keepLines}) async {
    try {
      final rows = await f.readAsLines();
      if (rows.isEmpty || !rows.first.startsWith('#')) return null;
      final head = jsonDecode(rows.first.substring(1)) as Map<String, dynamic>;
      final name = f.uri.pathSegments.last;
      final s = LogSession(
        id: name.substring(0, name.length - 4),
        start: DateTime.parse(head['start'] as String),
        connection: head['connection'] == true,
        title: head['title'] as String? ?? '',
        detail: head['detail'] as String? ?? '',
        file: f,
      );
      final lines = <LogLine>[];
      for (final row in rows.skip(1)) {
        final a = row.indexOf('\t');
        final b = a < 0 ? -1 : row.indexOf('\t', a + 1);
        if (b < 0) continue;
        final time = DateTime.tryParse(row.substring(0, a));
        if (time == null) continue;
        final line = LogLine(row.substring(a + 1, b), row.substring(b + 1), time);
        s._count(line);
        if (keepLines) lines.add(line);
      }
      if (keepLines) s.lines = lines;
      return s;
    } catch (_) {
      return null;
    }
  }

  /// Подгружает строки прошлого отрезка с диска (текущий и так в памяти).
  Future<void> load(LogSession s) async {
    if (s.lines != null || s.file == null || !_loading.add(s.id)) return;
    final lines = <LogLine>[];
    for (final f in s.files) {
      lines.addAll((await _readSession(f, keepLines: true))?.lines ?? const []);
    }
    s.lines = lines;
    _loading.remove(s.id);
    notifyListeners();
  }

  final _loading = <String>{};

  void _begin({required bool connection, required String title, String detail = ''}) {
    _purgeOld();
    final now = DateTime.now();
    final id = _idFor(now);
    final dir = _dir;
    final s = LogSession(
      id: id,
      start: now,
      connection: connection,
      title: title,
      detail: detail,
      file: dir == null ? null : File('${dir.path}\\$id.log'),
    )
      ..live = true
      ..lines = [];
    try {
      s._out = s.file?.openSync(mode: FileMode.write);
      s._out?.writeStringSync('#${jsonEncode({
            'start': now.toIso8601String(),
            'connection': connection,
            'title': title,
            'detail': detail,
          })}\n');
    } catch (_) {
      s._out = null;
    }
    sessions.add(s);
    _current = s;
    _recent.clear();
  }

  void _finish() {
    final s = _current;
    if (s == null) return;
    s.live = false;
    try {
      s._out?.closeSync();
    } catch (_) {}
    s._out = null;
    _current = null;
  }

  /// Начало подключения: дальше строки пишутся в новый отрезок с именем сервера.
  void startSession(String title, {String detail = ''}) {
    _finish();
    _begin(connection: true, title: title, detail: detail);
    notifyListeners();
  }

  /// Подключение закончилось. Следующий отрезок («без подключения») появится с первой же строкой.
  void endSession() {
    if (_current == null) return;
    _finish();
    notifyListeners();
  }

  void add(String source, String text) {
    for (final t in const LineSplitter().convert(text)) {
      if (t.trim().isEmpty) continue;
      if (_current == null) _begin(connection: false, title: 'Без подключения');
      final s = _current!;
      // Ядро может писать одну и ту же строку сотни раз (программа раз за разом стучится на адрес,
      // которого нет). Повторы не добавляются — у первой строки растёт счётчик. Через [_repeatSpan]
      // строка появляется заново, чтобы было видно, что это ещё продолжается.
      if (source == 'xray' || source == 'sing-box') {
        final key = '$source|${_sameLineKey(t)}';
        final now = DateTime.now();
        final shown = _recent[key];
        if (shown != null &&
            now.difference(shown.lastSeen) < _repeatGap &&
            now.difference(shown.time) < _repeatSpan) {
          shown.repeated(now);
          continue;
        }
        if (_recent.length > 300) _recent.clear();
        final line = LogLine(source, t, now);
        _recent[key] = line;
        _append(s, line);
        continue;
      }
      _append(s, LogLine(source, t));
    }
    notifyListeners();
  }

  /// Строки ядер, показанные недавно: по ним узнаются повторы.
  final _recent = <String, LogLine>{};

  /// Повтором считается та же строка, пришедшая не позже чем через минуту после предыдущей…
  static const _repeatGap = Duration(minutes: 1);

  /// …и не дольше десяти минут подряд: потом строка показывается заново.
  static const _repeatSpan = Duration(minutes: 10);

  /// Строка без того, что меняется от раза к разу: времени ядра и номера соединения.
  static String _sameLineKey(String text) => text
      .replaceFirst(RegExp(r'^\d{4}[/-]\d{2}[/-]\d{2} \d{2}:\d{2}:\d{2}(\.\d+)? '), '')
      .replaceAll(RegExp(r'\[\d+\] '), '');

  void _append(LogSession s, LogLine line) {
    s.lines!.add(line);
    if (s.lines!.length > maxLines) s.lines!.removeRange(0, s.lines!.length - maxLines);
    s._count(line);
    if (s._out == null) return;
    if (s._written >= fileLimit && s.parts.length < maxParts - 1) _nextPart(s);
    // Все части заполнены: строки ядер дальше не пишутся, а события программы (отключение, ошибки,
    // Kill Switch) — пишутся всегда, иначе по файлу нельзя было бы понять, чем всё закончилось.
    final core = line.source == 'xray' || line.source == 'sing-box' || line.source == 'test';
    if (s._written >= fileLimit && core) return;
    try {
      final row = '${line.time.toIso8601String()}\t${line.source}\t${line.text}\n';
      s._out!.writeStringSync(row);
      s._written += row.length;
    } catch (_) {}
  }

  /// Файл отрезка заполнен — запись продолжается в следующей части.
  void _nextPart(LogSession s) {
    final dir = _dir;
    if (dir == null) return;
    final file = File('${dir.path}\\${s.id}-${s.parts.length + 2}.log');
    try {
      final out = file.openSync(mode: FileMode.write);
      out.writeStringSync('#${jsonEncode({
            'start': s.start.toIso8601String(),
            'connection': s.connection,
            'title': s.title,
            'detail': s.detail,
            'part': s.parts.length + 2,
          })}\n');
      try {
        s._out?.closeSync();
      } catch (_) {}
      s._out = out;
      s._written = 0;
      s.parts.add(file);
    } catch (_) {
      // Новую часть создать не удалось — остаёмся на прежней (она заполнена, строки ядер не пишутся).
    }
  }

  /// Соединение программы (из журнала доступа Xray) — в текущий отрезок, только в память.
  void addConnection(ConnEntry c) {
    final s = _current;
    if (s == null) return;
    final list = s.connections;
    list.add(c);
    s.connectionCounts[c.route] = (s.connectionCounts[c.route] ?? 0) + 1;
    if (list.length > maxConnections) list.removeRange(0, list.length - maxConnections);
    // Соединений бывают сотни в секунду (загрузки, торренты): окно журнала обновляется не на каждое,
    // а не чаще четырёх раз в секунду — иначе оно перерисовывалось бы без остановки.
    _connNotify ??= Timer(const Duration(milliseconds: 250), () {
      _connNotify = null;
      notifyListeners();
    });
  }

  /// Ядро не узнало программу для ещё одного соединения. Возвращает, сколько их набралось за отрезок.
  int addUnknownProcess() {
    final s = _current;
    if (s == null) return 0;
    s.unknownProcess++;
    _connNotify ??= Timer(const Duration(milliseconds: 250), () {
      _connNotify = null;
      notifyListeners();
    });
    return s.unknownProcess;
  }

  Timer? _connNotify;

  /// Закрывает файл текущего отрезка (выход из программы).
  void close() => _finish();

  /// Удаляет прошлый отрезок вместе с файлом. Текущий удалить нельзя — в него идёт запись.
  void remove(LogSession s) {
    if (s.live) return;
    _deleteFiles(s);
    sessions.remove(s);
    notifyListeners();
  }

  /// Удаляет прошлые отрезки — все или только начавшиеся в день [day]; текущий остаётся.
  void clearHistory({DateTime? day}) {
    bool matches(LogSession s) =>
        day == null || (s.start.year == day.year && s.start.month == day.month && s.start.day == day.day);
    for (final s in sessions.where((s) => !s.live && matches(s)).toList()) {
      _deleteFiles(s);
      sessions.remove(s);
    }
    notifyListeners();
  }

  static void _deleteFiles(LogSession s) {
    for (final f in s.files) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }

  String tail(int n, {String? source}) => lines
      .where((l) => source == null || l.source == source)
      .toList()
      .reversed
      .take(n)
      .toList()
      .reversed
      .map((l) => l.text)
      .join('\n');
}
