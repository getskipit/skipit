import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/core_manager.dart';
import 'package:skipit/core/log_explain.dart';
import 'package:skipit/core/util.dart';
import 'package:skipit/state/app_state.dart';

/// Журнал разбит на отрезки по подключениям, каждый отрезок — файл; журнал дня живёт 5 дней.
void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('skipit-logs'));
  tearDown(() async => dir.delete(recursive: true));

  test('строка журнала доступа Xray разбирается в соединение: куда шло и каким путём', () {
    const routes = {'proxy': ConnRoute.proxy, 'direct': ConnRoute.direct, 'block': ConnRoute.block};
    // Строки в том виде, как их пишет Xray 26.9.30.
    final a = ConnEntry.tryParse(
        '2026/10/02 00:01:11.773977 from tcp:127.0.0.1:50349 accepted tcp:example.com:443 [socks >> direct]', routes)!;
    expect((a.network, a.host, a.port, a.inbound, a.outbound, a.route),
        ('tcp', 'example.com', 443, 'socks', 'direct', ConnRoute.direct));
    final b = ConnEntry.tryParse('from tcp:127.0.0.1:1 accepted udp:[2a00:1450::8a]:443 [skipit-tun -> block]', routes)!;
    expect((b.network, b.host, b.route), ('udp', '[2a00:1450::8a]', ConnRoute.block));
    // Неизвестный выход (сервер провайдера с любым тегом) — это VPN.
    expect(ConnEntry.tryParse('from 127.0.0.1:1 accepted tcp:a.com:80 [http -> de-1]', routes)!.route, ConnRoute.proxy);
    expect(ConnEntry.tryParse('[Warning] core: Xray 26.9.30 started', routes), isNull);
    // Обычный HTTP через прокси-порт записан адресом страницы: остаётся только сайт, путь отбрасывается.
    final h = ConnEntry.tryParse(
        '2026/10/02 00:22:43.474967 from 127.0.0.1:54061 accepted http://ctldl.windowsupdate.com/msdownload/pin.cab?7e2d [http -> proxy-2]',
        routes)!;
    expect((h.host, h.port, h.inbound, h.outbound, h.route), ('ctldl.windowsupdate.com', 80, 'http', 'proxy-2', ConnRoute.proxy));
    // HTTPS через прокси-порт (CONNECT).
    final s = ConnEntry.tryParse('from 127.0.0.1:50168 accepted //tls.example:443 [http -> direct]', routes)!;
    expect((s.host, s.port, s.route), ('tls.example', 443, ConnRoute.direct));
  });

  test('соединение, для которого ядро не узнало программу, находится по адресу программы', () {
    // Адрес программы есть и в строке журнала доступа, и в строке ядра о неудаче.
    final c = ConnEntry.tryParse(
        'from udp:172.19.0.1:63662 accepted udp:203.0.113.9:22102 [skipit-tun -> proxy]', const {'proxy': ConnRoute.proxy})!;
    expect((c.source, c.unknownProcess), ('172.19.0.1:63662', false));
    expect(ConnEntry.tryParse('from 127.0.0.1:50168 accepted //tls.example:443 [http -> direct]', const {})!.source,
        '127.0.0.1:50168');
    expect(
        AppState.unknownProcessSource('2026/10/04 00:10:11.1 [Error] app/router: Unables to find local process name: '
            'process not found for udp:172.19.0.1:63662'),
        '172.19.0.1:63662');
    expect(AppState.unknownProcessSource('[Error] app/router: Unables to find local process name: Access is denied.'), isNull);

    final log = LogBuffer()..startSession('Сервер');
    expect(log.addUnknownProcess(), 1);
    expect(log.addUnknownProcess(), 2);
    expect(log.sessions.single.unknownProcess, 2);
    log.endSession();
  });

  test('соединения хранятся только в памяти: список сайтов на диск не пишется', () async {
    final log = LogBuffer();
    await log.open(dir);
    log.startSession('Сервер');
    log.addConnection(ConnEntry(
        network: 'tcp', host: 'secret.example', port: 443, inbound: 'socks', outbound: 'proxy', route: ConnRoute.proxy));
    log.endSession();
    expect(log.sessions.single.connections, hasLength(1));
    expect(log.sessions.single.file!.readAsStringSync(), isNot(contains('secret.example')));
  });

  test('строки sing-box: команды раскраски убираются, успешный ответ DNS — не ошибка', () {
    // Так sing-box пишет на уровне debug: слово уровня и номер соединения раскрашены для консоли.
    const raw = '\x1B[36mINFO\x1B[0m [\x1B[38;5;85m2435357074\x1B[0m 74ms] dns: exchanged catalog.gamepass.com NOERROR 18';
    final text = CoreProcess.clean(raw);
    expect(text, 'INFO [2435357074 74ms] dns: exchanged catalog.gamepass.com NOERROR 18');
    expect(LogLine('sing-box', text).level, 0);
    // Настоящие ошибки и предупреждения остаются.
    expect(LogLine('sing-box', CoreProcess.clean('\x1B[31mERROR\x1B[0m connection: i/o timeout')).level, 2);
    expect(LogLine('sing-box', 'WARN inbound/tun: open interface take too much time').level, 1);
    // Не ответил один DNS-сервер: ошибка, но при запасном DNS — только предупреждение (сайт откроется).
    const dnsFail = '[Error] app/dns: failed to retrieve response for example.com. > Post "https://doh.example/dns-query": '
        'context deadline exceeded';
    expect(LogLine('xray', dnsFail).level, 2);
    LogLine.dnsHasSpare = true;
    addTearDown(() => LogLine.dnsHasSpare = false);
    expect(LogLine('xray', dnsFail).level, 1);
    expect(CoreProcess.clean('обычная строка [0m] без команд'), 'обычная строка [0m] без команд');
    // Своё время Xray в начале строки убирается: журнал помечает строки временем сам.
    expect(CoreProcess.clean('2026/10/05 02:23:55.652302 [Info] transport/internet/tcp: listening tcp on 127.0.0.1:10809'),
        '[Info] transport/internet/tcp: listening tcp on 127.0.0.1:10809');
    // Дата в середине строки остаётся.
    expect(CoreProcess.clean('[Info] expires 2026/10/05 02:23:55 soon'), '[Info] expires 2026/10/05 02:23:55 soon');
  });

  test('одинаковые соединения склеиваются в группу; свежие обращения — в конце', () {
    ConnEntry conn(String host, ConnRoute route, [String network = 'tcp']) =>
        ConnEntry(network: network, host: host, port: 443, inbound: 'http', outbound: route.name, route: route);
    final groups = groupConnections([
      conn('a.example', ConnRoute.proxy),
      conn('b.example', ConnRoute.proxy),
      conn('a.example', ConnRoute.proxy),
      // Тот же сайт другим путём или по другой сети — отдельная строка.
      conn('a.example', ConnRoute.direct),
      conn('b.example', ConnRoute.proxy, 'udp'),
      conn('a.example', ConnRoute.proxy),
    ]);
    expect([for (final g in groups) (g.last.host, g.last.route, g.last.network, g.items.length)], [
      ('b.example', ConnRoute.proxy, 'tcp', 1),
      ('a.example', ConnRoute.direct, 'tcp', 1),
      ('b.example', ConnRoute.proxy, 'udp', 1),
      ('a.example', ConnRoute.proxy, 'tcp', 3),
    ]);
  });

  test('обычные строки ядер получают пояснение простыми словами', () {
    String? x(String line) => LogExplain.of('xray', line);
    String? s(String line) => LogExplain.of('sing-box', line);
    // Строки в том виде, как их пишут ядра (взяты из журнала).
    expect(x('2026/10/03 20:30:09.025940 [Debug] [3705316341] proxy: XtlsPadding 80 1133 0'), contains('debug'));
    expect(x('[Info] [2701967293] proxy/dns: rejected type TypePTR query for domain 95.205.125.74.in-addr.arpa.'),
        contains('обратный запрос'));
    expect(x('[Debug] app/dns: domain p2p-sto2.discovery.steamserver.net will use DNS in order: [DOHL//dns.example]'),
        contains('p2p-sto2.discovery.steamserver.net'));
    // Не ответил один DNS-сервер: это ещё не «сайт не найден» — за ним может стоять запасной.
    expect(
        x('[Error] app/dns: failed to retrieve response for site.example. > Post "https://dns.example/dns-query": '
            'context deadline exceeded'),
        contains('запасной'));
    expect(x('[Info] app/dns: DOHL//dns.example querying: p2p-sto2.discovery.steamserver.net.'),
        'Ядро спрашивает у DNS-сервера адрес p2p-sto2.discovery.steamserver.net.');
    expect(
        x('[Info] app/dns: DOHL//dns.example got answer: p2p-sto2.discovery.steamserver.net. TypeA -> [155.133.252.54], rtt: 60.9583ms, lock: 0s'),
        contains('за 61 мс'));
    expect(x('[Info] [593965005] app/dispatcher: taking detour [proxy-2] for [tcp:ipv6.msftconnecttest.com:80]'),
        'Для соединения с ipv6.msftconnecttest.com:80 ядро выбрало путь «proxy-2».');
    expect(x('[Info] [593965005] proxy/vless/outbound: tunneling request to tcp:ipv6.msftconnecttest.com:80 via fi.example:2096'),
        contains('через VPN-сервер'));
    expect(s('INFO [2014162670 0ms] router: found process path: D:\\vpn\\build\\dev\\core\\skipit-xray.exe'),
        'Соединение открыла программа skipit-xray.exe.');
    expect(s('INFO [1 0ms] outbound/direct[direct]: outbound connection to 203.0.113.9:443'), contains('напрямую'));
    expect(s('DEBUG [1 0ms] router: match[2] process_name=[skipit-xray.exe skipit-sing-box.exe] => route(direct)'),
        contains('напрямую'));
    // Отказ в доступе к чужому процессу — это не «нужны права администратора».
    expect(s('INFO [3107459377 0ms] router: failed to search process: Access is denied.'), contains('какая программа'));
    expect(x('[Error] app/router: Unables to find local process name: Access is denied.'), contains('какая программа'));
    // Прежние пояснения к сбоям не перебиты новыми.
    expect(x('[Warning] [1] proxy/http: failed to read response from ipv6.msftconnecttest.com > unexpected EOF'),
        contains('IPv6'));
  });

  test('отказ сервера подписки объясняется по коду; окончательный отказ не повторяют другим путём', () {
    expect(describeNetError(ServerRefused(402)), 'Сервер сообщает, что подписка не оплачена или закончилась (код 402)');
    expect(ServerRefused(402).isFinal, isTrue);
    expect(ServerRefused(404).reason, contains('не найдена'));
    expect(ServerRefused(403).reason, contains('отказал в доступе'));
    // Сбой на стороне сервера и просьба подождать — не окончательный отказ.
    expect(ServerRefused(502).isFinal, isFalse);
    expect(ServerRefused(429).isFinal, isFalse);
    // Строка журнала с таким текстом считается ошибкой.
    expect(LogLine('subscription', 'Провайдер: не удалось обновить подписку — ${ServerRefused(402).reason}').level, 2);
  });

  test('длинный журнал продолжается в следующих частях; события программы пишутся всегда', () async {
    final saved = LogBuffer.fileLimit;
    LogBuffer.fileLimit = 2000;
    addTearDown(() => LogBuffer.fileLimit = saved);

    final log = LogBuffer();
    await log.open(dir);
    log.startSession('Сервер', detail: 'TUN');
    // Разные строки (одинаковые склеились бы в одну со счётчиком).
    for (var i = 0; i < 400; i++) {
      log.add('xray', 'line $i ${'x' * 40}');
    }
    // Все части заполнены — строка ядра в файл уже не идёт, строка программы идёт.
    log
      ..add('xray', 'after the limit')
      ..add('app', 'Отключено')
      ..endSession();

    final files = dir.listSync().whereType<File>().map((f) => f.uri.pathSegments.last).toList()..sort();
    expect(files, hasLength(LogBuffer.maxParts));
    final s = log.sessions.single;
    expect(s.parts, hasLength(LogBuffer.maxParts - 1));
    final text = s.files.map((f) => f.readAsStringSync()).join();
    expect(text, contains('line 0 '));
    expect(text, contains('Отключено'));
    expect(text, isNot(contains('after the limit')));
    // Каждая часть не больше лимита (плюс одна строка и заголовок).
    for (final f in s.files) {
      expect(f.lengthSync(), lessThan(2000 + 400));
    }

    // После перезапуска программы подключение остаётся одним отрезком со всеми строками.
    final again = LogBuffer();
    await again.open(dir);
    expect(again.sessions, hasLength(1));
    final loaded = again.sessions.single;
    expect((loaded.title, loaded.parts.length), ('Сервер', LogBuffer.maxParts - 1));
    await again.load(loaded);
    expect(loaded.lines!.first.text, startsWith('line 0 '));
    expect(loaded.lines!.last.text, 'Отключено');
    // Строки идут по порядку частей.
    final numbers = [for (final l in loaded.lines!) if (l.text.startsWith('line ')) int.parse(l.text.split(' ')[1])];
    expect(numbers, [...numbers]..sort());
    again.remove(loaded);
    expect(dir.listSync().whereType<File>(), isEmpty);
  });

  test('уровень строки ядра берётся из его же пометки, а не из случайных слов', () {
    // Предупреждение из модуля «common/errors» — предупреждение, а не ошибка.
    expect(
        LogLine('test', '2026/10/04 01:09:46.310999 [Warning] common/errors: The feature WebSocket transport '
            'is deprecated, not recommended for using and might be removed.').level,
        1);
    // Обычная строка со словом «error» в адресе сайта — не ошибка.
    expect(LogLine('xray', '[Info] [1] proxy/http: request to Host [errors.example.com]').level, 0);
    expect(LogLine('xray', '[Error] app/dns: failed to retrieve response for a.example').level, 2);
    expect(LogLine('xray', '[Warning] core: Xray 26.9.30 started').level, 0);
    expect(LogLine('sing-box', 'INFO[0000] router: error-pages.example matched').level, 0);
    expect(LogLine('sing-box', 'ERROR[0012] connection: i/o timeout').level, 2);
    expect(LogLine('sing-box', 'WARN[0010] inbound/tun: open interface take too much time').level, 1);
    // Строки самой программы уровня не несут — для них работают слова.
    expect(LogLine('app', 'Ошибка подключения: порт занят').level, 2);
    expect(LogLine('app', 'Подключено').level, 0);
  });

  test('слово после числа ставится в нужной форме', () {
    String times(int n) => '$n ${plural(n, 'раз', 'раза', 'раз')}';
    expect([1, 2, 4, 5, 11, 12, 14, 21, 22, 25, 101, 111, 122].map(times).toList(), [
      '1 раз', '2 раза', '4 раза', '5 раз', '11 раз', '12 раз', '14 раз', '21 раз', '22 раза', '25 раз',
      '101 раз', '111 раз', '122 раза',
    ]);
  });

  test('вид всплывающего сообщения узнаётся по тексту: успех, ошибка или сведение', () {
    for (final text in [
      'Подписка «SkipIt VPN» обновлена',
      'Журнал скопирован',
      'Ссылка на профиль скопирована',
      'Сохранено: SkipIt — настройки 2026-10-04.json',
      'Добавлено: серверов: 2',
      'У вас последняя версия',
    ]) {
      expect(ToastMessage.kindOf(text), ToastKind.success, reason: text);
    }
    for (final text in [
      'Не удалось обновить «Провайдер»: Сервер сообщает, что подписка не оплачена или закончилась (код 402)',
      'Ошибка проверки: нет свободных портов',
      'Добавлено: подписка с ошибкой: Сервер не ответил вовремя',
      'Ничего не найдено',
      'Сначала отключите VPN',
      'Это не файл настроек SkipIt',
    ]) {
      expect(ToastMessage.kindOf(text), ToastKind.error, reason: text);
    }
    for (final text in ['Буфер обмена пуст', 'Уже в списке', 'Тестовая сборка не обновляется из релизов',
        'Доступна новая версия SkipIt: 1.0.6']) {
      expect(ToastMessage.kindOf(text), ToastKind.info, reason: text);
    }
  });

  test('соединения считаются все, хотя в списке остаются только последние', () {
    final log = LogBuffer()..startSession('Сервер');
    ConnEntry conn(int i, ConnRoute route) =>
        ConnEntry(network: 'tcp', host: 'h$i.example', port: 443, inbound: 'socks', outbound: route.name, route: route);
    for (var i = 0; i < LogBuffer.maxConnections + 500; i++) {
      log.addConnection(conn(i, i % 10 == 0 ? ConnRoute.direct : ConnRoute.proxy));
    }
    log.addConnection(conn(-1, ConnRoute.block));
    final s = log.sessions.single;
    expect(s.connections, hasLength(LogBuffer.maxConnections));
    expect(s.connectionsTotal, LogBuffer.maxConnections + 501);
    expect(s.connectionCounts, {ConnRoute.proxy: 2250, ConnRoute.direct: 250, ConnRoute.block: 1});
    log.endSession();
  });

  test('одинаковые строки ядра не засоряют журнал: одна строка со счётчиком', () async {
    final log = LogBuffer();
    await log.open(dir);
    log.startSession('Сервер');
    // Так ядро пишет, когда программа раз за разом стучится на несуществующий адрес:
    // меняются только время и номер соединения.
    for (var i = 0; i < 40; i++) {
      log.add('xray', '2026/10/02 23:16:${(10 + i).toString()}.842578 [Error] [${619022970 + i}] transport/internet: '
          'failed to resolve ip > app/dns: returning nil for domain pubwxp.vivox.com > rcode: 3');
    }
    log.add('xray', '2026/10/02 23:17:01.000000 [Error] [1] transport/internet: failed to resolve ip > '
        'app/dns: returning nil for domain other.example > rcode: 3');
    // Строки самой программы не склеиваются: два «Подключено» — это два события.
    log
      ..add('app', 'Подключено')
      ..add('app', 'Подключено');
    final lines = log.lines;
    expect(lines.map((l) => l.source).toList(), ['xray', 'xray', 'app', 'app']);
    expect(lines[0].repeats, 40);
    expect(lines[1].repeats, 1);
    final session = log.current!;
    // Счётчики отрезка считают строки, а не повторы; на диск повторы тоже не пишутся.
    expect((session.count, session.errors, session.warnings), (4, 0, 2));
    log.endSession();
    expect('pubwxp.vivox.com'.allMatches(session.file!.readAsStringSync()).length, 1);

    // В новом отрезке та же строка показывается заново.
    log.startSession('Сервер');
    log.add('xray', '[Error] [5] transport/internet: failed to resolve ip > app/dns: returning nil for domain '
        'pubwxp.vivox.com > rcode: 3');
    expect(log.lines.single.repeats, 1);
    expect(LogExplain.of('xray', log.lines.single.text), contains('pubwxp.vivox.com'));
    expect(LogExplain.of('xray', log.lines.single.text), contains('не существует'));
    expect(log.lines.single.level, 1);
    log.endSession();
  });

  test('к строкам ядра есть пояснения простыми словами, к строкам программы — нет', () {
    expect(LogExplain.of('xray', '[Warning] core: Xray 26.9.30 started'), contains('запущено'));
    expect(LogExplain.of('xray', 'proxy/http: failed to read response from example.com > unexpected EOF'),
        contains('example.com'));
    // Проверка интернета по IPv6, которую делает сама Windows: своё пояснение, и это не предупреждение.
    const ncsi = '2026/10/02 21:29:14.960610 [Warning] [1537693391] proxy/http: failed to read response from '
        'ipv6.msftncsi.com > unexpected EOF';
    expect(LogExplain.of('xray', ncsi), contains('Windows проверяет'));
    expect(LogExplain.of('xray', ncsi.replaceFirst('msftncsi', 'msftconnecttest')), contains('Windows проверяет'));
    expect(LogLine('xray', ncsi).level, 0);
    expect(LogExplain.of('xray', 'The "freedom.domainStrategy" setting is deprecated'), contains('устаревший'));
    expect(LogExplain.of('sing-box', 'open interface take too much time'), contains('адаптер'));
    expect(LogExplain.of('app', 'Ошибка подключения: timeout'), isNull);
    // Программа сама закрыла соединение через адаптер: пояснение есть, но ошибкой это не считается.
    const reset = '2026/10/02 02:09:32.664688 [Error] proxy/tun: connection reset by peer';
    expect(LogExplain.of('xray', reset), contains('сама оборвала'));
    expect(LogLine('xray', reset).level, 0);
    const refused = '2026/10/02 19:42:50.569535 [Error] proxy/tun: connection was refused';
    expect(LogExplain.of('xray', refused), contains('раньше, чем оно установилось'));
    expect(LogLine('xray', refused).level, 0);
    expect(LogLine('xray', '[Error] app/dns: failed to retrieve response').level, 2);
    expect(
        LogExplain.of('xray', '[Warning] app/observatory/burst: error ping https://www.gstatic.com/generate_204 with proxy-2: Head: context deadline exceeded'),
        contains('«proxy-2»'));
    // Пояснения к сбоям — только у предупреждений и ошибок: обычная строка с тем же словом не помечается.
    expect(LogExplain.of('xray', '[Warning] transport/internet/tcp: REALITY: failed to verify'), contains('защищённого'));
    expect(LogExplain.of('xray', '[Info] transport/internet/tcp: dialing REALITY to tcp:example.com:443'), isNull);
    expect(LogExplain.of('xray', 'A unified platform for anti-censorship.'), isNull);
  });

  test('строки делятся на отрезки: без подключения → подключение → без подключения', () async {
    final log = LogBuffer();
    await log.open(dir);

    log.add('app', 'Запуск');
    log.startSession('🇩🇪 Germany', detail: 'Смешанный');
    log.add('xray', '[Warning] core: Xray 26.9.30 started');
    log.add('xray', '[Warning] proxy/http: failed to read response');
    log.add('app', 'Ошибка подключения: порт занят');
    log.endSession();
    log.add('update', 'У вас последняя версия');

    expect(log.sessions.map((s) => s.connection), [false, true, false]);
    final conn = log.sessions[1];
    expect(conn.title, '🇩🇪 Germany');
    expect(conn.detail, 'Смешанный');
    expect(conn.live, isFalse);
    // «Xray … started» — не предупреждение, остальные две строки считаются.
    expect((conn.count, conn.warnings, conn.errors), (3, 1, 1));
    expect(log.sessions.last.live, isTrue);
    expect(log.tail(5), 'У вас последняя версия');
    log.close();
  });

  test('после перезапуска прошлые отрезки читаются с диска', () async {
    final first = LogBuffer();
    await first.open(dir);
    first.startSession('Finland', detail: 'TUN');
    first.add('sing-box', 'ERROR connection: i/o timeout');
    first.endSession();

    final second = LogBuffer();
    await second.open(dir);
    final past = second.sessions.single;
    expect((past.title, past.detail, past.errors, past.live), ('Finland', 'TUN', 1, false));
    expect(past.lines, isNull, reason: 'строки подгружаются только при открытии отрезка');
    await second.load(past);
    expect(past.lines!.single.text, 'ERROR connection: i/o timeout');

    second.remove(past);
    expect(second.sessions, isEmpty);
    expect(dir.listSync(), isEmpty);
  });

  test('очистка истории за один день не трогает другие дни и текущий журнал', () async {
    final first = LogBuffer();
    await first.open(dir);
    first.startSession('Finland', detail: 'TUN');
    first.add('app', 'Подключено');
    first.endSession();
    first.close();

    // Тот же журнал, но вчерашний: имя файла и время начала в заголовке сдвинуты на день.
    final today = dir.listSync().whereType<File>().firstWhere((f) => f.readAsStringSync().contains('Finland'));
    final rows = today.readAsLinesSync();
    final head = jsonDecode(rows.first.substring(1)) as Map<String, dynamic>;
    final start = DateTime.parse(head['start'] as String).subtract(const Duration(days: 1));
    head['start'] = start.toIso8601String();
    String two(int n) => n.toString().padLeft(2, '0');
    File('${dir.path}\\${start.year}-${two(start.month)}-${two(start.day)}_10-00-00_000.log')
        .writeAsStringSync(['#${jsonEncode(head)}', ...rows.skip(1)].join('\n'));

    final second = LogBuffer();
    await second.open(dir);
    final before = second.sessions.where((s) => !s.live).length;
    expect(second.sessions.where((s) => s.start.day == start.day), hasLength(1));

    second.clearHistory(day: start);
    expect(second.sessions.where((s) => s.start.day == start.day), isEmpty);
    expect(second.sessions.where((s) => !s.live), hasLength(before - 1));

    second.clearHistory();
    expect(second.sessions.where((s) => !s.live), isEmpty);
    second.close();
  });

  test('журнал старше 5 дней удаляется, более свежий остаётся', () async {
    String name(DateTime t) =>
        '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}_10-00-00_000.log';
    final now = DateTime.now();
    final old = File('${dir.path}\\${name(now.subtract(const Duration(days: 6)))}');
    final fresh = File('${dir.path}\\${name(now.subtract(const Duration(days: 4)))}');
    for (final f in [old, fresh]) {
      await f.writeAsString('#{"start":"${now.toIso8601String()}","connection":true,"title":"A","detail":""}\n');
    }

    final log = LogBuffer();
    await log.open(dir);
    expect(old.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
    expect(log.sessions.length, 1);
  });
}
