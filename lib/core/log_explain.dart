import '../l10n/l10n.dart';

/// Расшифровка строк журнала ядер простыми словами: что произошло и нужно ли что-то делать.
/// Ядра пишут по-английски и для разработчиков; здесь — пояснения к самым частым сообщениям.
class LogExplain {
  static final _rules = <(RegExp, String Function(RegExpMatch))>[
    // Запуск и остановка.
    (RegExp(r'core: Xray .* started'), (_) => tr('Ядро Xray запущено и готово к работе.')),
    (RegExp(r'sing-box started'), (_) => tr('Ядро sing-box запущено: адаптер TUN работает.')),
    (RegExp(r'Reading config'), (_) => tr('Ядро читает файл с настройками подключения.')),
    (RegExp(r'(?:завершился с кодом|exited with code) (-?\d+)'), (m) => m.group(1) == '0'
        ? tr('Ядро остановлено штатно.')
        : tr('Ядро остановлено (при отключении это нормально; если само — см. строки выше).')),
    (
      RegExp(r'is deprecated'),
      (_) => tr('В настройках сервера есть устаревший параметр. На работу сейчас не влияет; '
          'исчезнет, когда провайдер обновит конфиг.')
    ),

    // Адаптер TUN.
    (RegExp(r'Failed to find matching adapter name'), (_) => tr('Готового адаптера VPN нет — ядро создаст новый. Это обычная строка, не ошибка.')),
    (RegExp(r'Creating adapter'), (_) => tr('Ядро просит Windows создать сетевой адаптер VPN. Если следом нет строки о запуске — Windows его не создала.')),
    (RegExp(r'Removed orphaned adapter'), (_) => tr('Убран брошенный адаптер, оставшийся от прошлого запуска. Работающие адаптеры не трогаются.')),
    (RegExp(r'Using existing driver'), (_) => tr('Драйвер адаптера (Wintun) уже установлен в Windows.')),
    (
      RegExp(r'open interface take too much time|configure tun interface'),
      (_) => tr('Windows не отдаёт сетевой адаптер VPN. Обычно помогает перезагрузка; пока можно подключиться в режиме «Прокси».')
    ),
    // Стоит раньше общего «Access is denied»: здесь отказ — про чужой процесс, а не про права программы.
    (
      RegExp(r'Unables to find local process name|failed to search process'),
      (_) => tr('Ядро не смогло узнать, какая программа открыла соединение: Windows не дала доступа к её процессу '
          'или соединение уже закрылось. Правило по приложениям к нему не применилось — оно пошло общим путём.')
    ),
    (RegExp(r'[Aa]ccess is denied'), (_) => tr('Windows отказала в доступе — нужны права администратора.')),

    // Файрвол.
    (
      RegExp(r'\b(10057|10013)\b|forbidden by its access permissions'),
      (_) => tr('Выход в сеть заблокирован файрволом (например, simplewall). Разрешите в нём ядро SkipIt.')
    ),

    // Обычная работа ядра Xray (строки уровней info и debug): что оно делает с каждым соединением.
    (
      RegExp(r'proxy: (XtlsPadding|Xtls Unpadding|XtlsFilterTls|ReshapeMultiBuffer|CopyRawConn)'),
      (_) => tr('Служебная строка: ядро упаковывает и шифрует данные для VPN-сервера. Видна только на уровне '
          'журнала debug, на работу не влияет.')
    ),
    (
      RegExp(r'proxy/dns: rejected type Type(\w+) query for domain'),
      (m) => m.group(1) == 'PTR'
          ? tr('Программа спросила, какое имя у адреса (обратный запрос). VPN на такие запросы не отвечает — '
              'это нормально, сайтам не мешает.')
          : tr('Программа запросила у DNS служебную запись ({0}), а не адрес сайта. VPN на такие запросы '
              'не отвечает — это нормально.', [m.group(1)])
    ),
    (
      RegExp(r'app/dns: domain (\S+?)\.? will use DNS in order'),
      (m) => tr('Ядро выбирает, у какого DNS-сервера спросить адрес {0}.', [m.group(1)])
    ),
    (
      RegExp(r'app/dns: \S+ cache (?:HIT|OPTIMISTE) (\S+?)\.? ->'),
      (m) => tr('Адрес {0} взят из памяти ядра, без нового запроса.', [m.group(1)])
    ),
    (RegExp(r'app/dns: \S+ querying: (\S+?)\.?$'), (m) => tr('Ядро спрашивает у DNS-сервера адрес {0}.', [m.group(1)])),
    (
      RegExp(r'app/dns: \S+ got answer: (\S+?)\.? .*rtt: ([\d.]+)ms'),
      (m) => tr('DNS-сервер ответил, где находится {0} (за {1} мс).', [m.group(1), double.parse(m.group(2)!).round()])
    ),
    (
      RegExp(r'app/dispatcher: taking detour \[(.+?)\] for \[(.+?)\]'),
      (m) => tr('Для соединения с {0} ядро выбрало путь «{1}».', [_bare(m.group(2)!), m.group(1)])
    ),
    (
      RegExp(r'app/dispatcher: default route for (\S+)'),
      (m) => tr('Для соединения с {0} особых правил нет — оно идёт путём по умолчанию.', [_bare(m.group(1)!)])
    ),
    (
      RegExp(r'tunneling request to (\S+) via'),
      (m) => tr('Соединение с {0} отправлено через VPN-сервер.', [_bare(m.group(1)!)])
    ),
    (
      RegExp(r'proxy/freedom: (?:dialing|opening connection|connection opened) to (\S+)'),
      (m) => tr('Соединение с {0} идёт напрямую, мимо VPN.', [_bare(m.group(1)!)])
    ),
    (
      RegExp(r'proxy/http: request to Method \[\w+\] Host \[(.+?)\]'),
      (m) => tr('Программа обратилась к {0} через системный прокси.', [m.group(1)])
    ),
    (
      RegExp(r'app/router: least load: no qualified outbound|fallback to \[.+?\], due to empty tag'),
      (_) => tr('Автовыбор сервера ещё не набрал замеров и пока использует сервер по умолчанию.')
    ),
    (
      RegExp(r'observatory/burst: perform one-time health check'),
      (_) => tr('Ядро проверяет серверы провайдера, чтобы выбрать лучший.')
    ),
    (
      RegExp(r'API server listening'),
      (_) => tr('Открыт служебный вход ядра для счётчиков трафика — только для этого компьютера.')
    ),

    // Обычная работа sing-box (уровни info и debug).
    (RegExp(r'inbound/tun\[.*?\]: started at'), (_) => tr('Адаптер VPN создан и работает.')),
    (
      RegExp(r'network: updated default interface (.+?), index'),
      (m) => tr('sing-box определил, через какую сетевую карту выходить в интернет: {0}.', [m.group(1)])
    ),
    (
      RegExp(r'clash-api: restful api listening'),
      (_) => tr('Открыт служебный вход sing-box для счётчика трафика — только для этого компьютера.')
    ),
    (
      RegExp(r'router: found process path: (.+)$'),
      (m) => tr('Соединение открыла программа {0}.', [m.group(1)!.trim().split(r'\').last])
    ),
    (
      RegExp(r'inbound/tun\[.*?\]: inbound DNS packet'),
      (_) => tr('Программа спрашивает адрес сайта — запрос попал в адаптер VPN.')
    ),
    (
      RegExp(r'inbound/tun\[.*?\]: inbound (?:packet )?connection to (\S+)'),
      (m) => tr('Программа на компьютере соединяется с {0} — трафик попал в адаптер VPN.', [m.group(1)])
    ),
    (
      RegExp(r'outbound/socks\[proxy\]: outbound (?:packet )?connection to (\S+)'),
      (m) => tr('Соединение с {0} передано ядру Xray — дальше оно идёт по правилам маршрутизации.', [m.group(1)])
    ),
    (
      RegExp(r'outbound/direct\[direct\]: outbound (?:packet )?connection to (\S+)'),
      (m) => tr('Соединение с {0} идёт напрямую, мимо VPN.', [m.group(1)])
    ),
    (
      RegExp(r'router: sniffed (?:packet )?protocol: (\w+)(?:, domain: (\S+))?'),
      (m) => m.group(2) == null
          ? tr('Ядро определило вид соединения: {0}.', [m.group(1)])
          : tr('Ядро определило, к какому сайту идёт соединение: {0}.', [m.group(2)])
    ),
    (
      RegExp(r'router: match\[\d+\].*=> route\((\w+)\)'),
      (m) => m.group(1) == 'direct'
          ? tr('Сработало правило: соединение идёт напрямую, мимо VPN.')
          : tr('Сработало правило: соединение идёт через VPN.')
    ),
    (RegExp(r'dns: exchanged (\S+?)\.? NOERROR'), (m) => tr('DNS ответил на запрос об адресе {0}.', [m.group(1)])),
    (
      RegExp(r'dns: exchanged (\S+?)\.? (NXDOMAIN|SERVFAIL)'),
      (m) => tr('DNS ответил, что имени {0} не существует или узнать его не удалось.', [m.group(1)])
    ),
    (
      RegExp(r'connection: connection (?:upload|download) (?:finished|closed)'),
      (_) => tr('Соединение завершено.')
    ),
  ];

  /// Адрес без приставки сети: `tcp:example.com:443` → `example.com:443`.
  static String _bare(String address) => address.replaceFirst(RegExp(r'^(tcp|udp):'), '');

  /// Пояснения к сбоям: показываются только у предупреждений и ошибок — иначе обычная строка,
  /// где просто упомянут сертификат или REALITY, выглядела бы как поломка.
  static final _problems = <(RegExp, String Function(RegExpMatch))>[
    // Соединения программ через адаптер: «другая сторона» здесь — сама программа на компьютере.
    (
      RegExp(r'proxy/tun: connection reset by peer'),
      (_) => tr('Программа на компьютере сама оборвала своё соединение (закрыли вкладку, отменили загрузку, '
          'программа передумала). Обычная строка — на работу VPN не влияет.')
    ),
    (
      RegExp(r'proxy/tun: connection was refused'),
      (_) => tr('Программа на компьютере закрыла соединение раньше, чем оно установилось. '
          'Обычная строка — на работу VPN не влияет.')
    ),
    (
      RegExp(r'proxy/tun: operation timed out'),
      (_) => tr('Соединение программы долго молчало и закрыто по времени. Разовые случаи — норма.')
    ),
    // Связь с VPN-сервером.
    (
      RegExp(r'observatory.*error ping .* with (\S+):'),
      (m) => tr('Ядро само проверяет серверы провайдера, чтобы выбрать лучший: сервер «{0}» не ответил '
          'на проверку. Сразу после подключения это обычное дело; если повторяется постоянно — сервер недоступен.',
          [m.group(1)])
    ),
    (
      RegExp(r'failed to find an available destination|all retry attempts failed|failed to dial'),
      (_) => tr('Не удалось соединиться с VPN-сервером: он недоступен или заблокирован. Попробуйте другой сервер.')
    ),
    (
      RegExp(r'REALITY|reality.*(verify|handshake)|tls: |x509|certificate'),
      (_) => tr('Ошибка защищённого соединения с сервером: не сошлись ключи или сертификат. '
          'Обновите подписку; если не поможет — напишите провайдеру.')
    ),
    // Не ответил один DNS-сервер из списка, а не весь DNS: есть ли за ним запасной, по строке не видно.
    (
      RegExp(r'app/dns: failed to retrieve response'),
      (_) => tr('Этот DNS-сервер не ответил вовремя. Если в настройках есть запасной, ядро спросит его. '
          'Если таких строк много и сайты не открываются — DNS не отвечает совсем.')
    ),
    (
      RegExp(r'no such host|failed to lookup|lookup .* (timeout|failed)|dns: .*fail'),
      (_) => tr('Не удалось узнать адрес сайта (DNS не ответил).')
    ),

    // Windows сама проверяет, есть ли интернет по IPv6 (от этого зависит значок сети), а у этих её
    // адресов есть только IPv6. При выключенном IPv6 ядру некуда подключиться — это не сбой.
    (
      RegExp(r'ipv6\.(msftncsi|msftconnecttest)\.com'),
      (_) => tr('Windows проверяет, есть ли интернет по IPv6. Пока IPv6 выключен в настройках, проверка '
          'не проходит — так и должно быть, на работу VPN не влияет.')
    ),

    // DNS ответил «такого имени нет» (код 3): программа стучится на адрес, которого не существует.
    (
      RegExp(r'failed to resolve ip.*domain (\S+) > rcode: 3'),
      (m) => tr('Программа запросила адрес {0}, а такого имени не существует — так ответил DNS. '
          'Это не сбой VPN: без него она получила бы тот же отказ.', [m.group(1)])
    ),

    // Отдельные соединения — обычно не требуют действий.
    (
      RegExp(r'failed to read response from (\S+)'),
      (m) => tr('Сайт {0} закрыл соединение, не ответив. Разовые случаи — норма, на VPN не влияют.', [m.group(1)])
    ),
    (RegExp(r'i/o timeout|deadline exceeded|timed? ?out'), (_) => tr('Другая сторона не ответила вовремя.')),
    (
      RegExp(r'connection refused|actively refused'),
      (_) => tr('Другая сторона отказала в соединении: порт закрыт или сервис не работает.')
    ),
    (
      RegExp(r'connection reset|forcibly closed|wsarecv|wsasend'),
      (_) => tr('Соединение оборвано другой стороной или по пути. Если повторяется на всех сайтах — мешает блокировка или сервер.')
    ),
    (
      RegExp(r'context canceled|closed pipe|use of closed network connection|unexpected EOF|\bEOF\b'),
      (_) => tr('Соединение закрыто раньше времени — чаще всего самой программой (закрыли вкладку, отменили загрузку).')
    ),
    (RegExp(r'rejected|blocked'), (_) => tr('Соединение отклонено правилами.')),
  ];

  static final _problem = RegExp(r'\[(Warning|Error)\]|\b(WARN|ERROR|FATAL)\b|fail', caseSensitive: false);

  /// Пояснение к строке или null, если сказать нечего. Строки самой программы уже написаны по-русски.
  static String? of(String source, String text) {
    if (source != 'xray' && source != 'sing-box' && source != 'test') return null;
    for (final (pattern, explain) in [..._rules, if (_problem.hasMatch(text)) ..._problems]) {
      final m = pattern.firstMatch(text);
      if (m != null) return explain(m);
    }
    return null;
  }
}
