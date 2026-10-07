/// Расшифровка строк журнала ядер простыми словами: что произошло и нужно ли что-то делать.
/// Ядра пишут по-английски и для разработчиков; здесь — пояснения к самым частым сообщениям.
class LogExplain {
  static final _rules = <(RegExp, String Function(RegExpMatch))>[
    // Запуск и остановка.
    (RegExp(r'core: Xray .* started'), (_) => 'Ядро Xray запущено и готово к работе.'),
    (RegExp(r'sing-box started'), (_) => 'Ядро sing-box запущено: адаптер TUN работает.'),
    (RegExp(r'Reading config'), (_) => 'Ядро читает файл с настройками подключения.'),
    (RegExp(r'завершился с кодом (-?\d+)'), (m) => m.group(1) == '0'
        ? 'Ядро остановлено штатно.'
        : 'Ядро остановлено (при отключении это нормально; если само — см. строки выше).'),
    (
      RegExp(r'is deprecated'),
      (_) => 'В настройках сервера есть устаревший параметр. На работу сейчас не влияет; '
          'исчезнет, когда провайдер обновит конфиг.'
    ),

    // Адаптер TUN.
    (RegExp(r'Failed to find matching adapter name'), (_) => 'Готового адаптера VPN нет — ядро создаст новый. Это обычная строка, не ошибка.'),
    (RegExp(r'Creating adapter'), (_) => 'Ядро просит Windows создать сетевой адаптер VPN. Если следом нет строки о запуске — Windows его не создала.'),
    (RegExp(r'Removed orphaned adapter'), (_) => 'Убран брошенный адаптер, оставшийся от прошлого запуска. Работающие адаптеры не трогаются.'),
    (RegExp(r'Using existing driver'), (_) => 'Драйвер адаптера (Wintun) уже установлен в Windows.'),
    (
      RegExp(r'open interface take too much time|configure tun interface'),
      (_) => 'Windows не отдаёт сетевой адаптер VPN. Обычно помогает перезагрузка; пока можно подключиться в режиме «Прокси».'
    ),
    // Стоит раньше общего «Access is denied»: здесь отказ — про чужой процесс, а не про права программы.
    (
      RegExp(r'Unables to find local process name|failed to search process'),
      (_) => 'Ядро не смогло узнать, какая программа открыла соединение: Windows не дала доступа к её процессу '
          'или соединение уже закрылось. Правило по приложениям к нему не применилось — оно пошло общим путём.'
    ),
    (RegExp(r'[Aa]ccess is denied'), (_) => 'Windows отказала в доступе — нужны права администратора.'),

    // Файрвол.
    (
      RegExp(r'\b(10057|10013)\b|forbidden by its access permissions'),
      (_) => 'Выход в сеть заблокирован файрволом (например, simplewall). Разрешите в нём ядро SkipIt.'
    ),

    // Обычная работа ядра Xray (строки уровней info и debug): что оно делает с каждым соединением.
    (
      RegExp(r'proxy: (XtlsPadding|Xtls Unpadding|XtlsFilterTls|ReshapeMultiBuffer|CopyRawConn)'),
      (_) => 'Служебная строка: ядро упаковывает и шифрует данные для VPN-сервера. Видна только на уровне '
          'журнала debug, на работу не влияет.'
    ),
    (
      RegExp(r'proxy/dns: rejected type Type(\w+) query for domain'),
      (m) => m.group(1) == 'PTR'
          ? 'Программа спросила, какое имя у адреса (обратный запрос). VPN на такие запросы не отвечает — '
              'это нормально, сайтам не мешает.'
          : 'Программа запросила у DNS служебную запись (${m.group(1)}), а не адрес сайта. VPN на такие запросы '
              'не отвечает — это нормально.'
    ),
    (
      RegExp(r'app/dns: domain (\S+?)\.? will use DNS in order'),
      (m) => 'Ядро выбирает, у какого DNS-сервера спросить адрес ${m.group(1)}.'
    ),
    (
      RegExp(r'app/dns: \S+ cache (?:HIT|OPTIMISTE) (\S+?)\.? ->'),
      (m) => 'Адрес ${m.group(1)} взят из памяти ядра, без нового запроса.'
    ),
    (RegExp(r'app/dns: \S+ querying: (\S+?)\.?$'), (m) => 'Ядро спрашивает у DNS-сервера адрес ${m.group(1)}.'),
    (
      RegExp(r'app/dns: \S+ got answer: (\S+?)\.? .*rtt: ([\d.]+)ms'),
      (m) => 'DNS-сервер ответил, где находится ${m.group(1)} (за ${double.parse(m.group(2)!).round()} мс).'
    ),
    (
      RegExp(r'app/dispatcher: taking detour \[(.+?)\] for \[(.+?)\]'),
      (m) => 'Для соединения с ${_bare(m.group(2)!)} ядро выбрало путь «${m.group(1)}».'
    ),
    (
      RegExp(r'app/dispatcher: default route for (\S+)'),
      (m) => 'Для соединения с ${_bare(m.group(1)!)} особых правил нет — оно идёт путём по умолчанию.'
    ),
    (
      RegExp(r'tunneling request to (\S+) via'),
      (m) => 'Соединение с ${_bare(m.group(1)!)} отправлено через VPN-сервер.'
    ),
    (
      RegExp(r'proxy/freedom: (?:dialing|opening connection|connection opened) to (\S+)'),
      (m) => 'Соединение с ${_bare(m.group(1)!)} идёт напрямую, мимо VPN.'
    ),
    (
      RegExp(r'proxy/http: request to Method \[\w+\] Host \[(.+?)\]'),
      (m) => 'Программа обратилась к ${m.group(1)} через системный прокси.'
    ),
    (
      RegExp(r'app/router: least load: no qualified outbound|fallback to \[.+?\], due to empty tag'),
      (_) => 'Автовыбор сервера ещё не набрал замеров и пока использует сервер по умолчанию.'
    ),
    (
      RegExp(r'observatory/burst: perform one-time health check'),
      (_) => 'Ядро проверяет серверы провайдера, чтобы выбрать лучший.'
    ),
    (
      RegExp(r'API server listening'),
      (_) => 'Открыт служебный вход ядра для счётчиков трафика — только для этого компьютера.'
    ),

    // Обычная работа sing-box (уровни info и debug).
    (RegExp(r'inbound/tun\[.*?\]: started at'), (_) => 'Адаптер VPN создан и работает.'),
    (
      RegExp(r'network: updated default interface (.+?), index'),
      (m) => 'sing-box определил, через какую сетевую карту выходить в интернет: ${m.group(1)}.'
    ),
    (
      RegExp(r'clash-api: restful api listening'),
      (_) => 'Открыт служебный вход sing-box для счётчика трафика — только для этого компьютера.'
    ),
    (
      RegExp(r'router: found process path: (.+)$'),
      (m) => 'Соединение открыла программа ${m.group(1)!.trim().split(r'\').last}.'
    ),
    (
      RegExp(r'inbound/tun\[.*?\]: inbound DNS packet'),
      (_) => 'Программа спрашивает адрес сайта — запрос попал в адаптер VPN.'
    ),
    (
      RegExp(r'inbound/tun\[.*?\]: inbound (?:packet )?connection to (\S+)'),
      (m) => 'Программа на компьютере соединяется с ${m.group(1)} — трафик попал в адаптер VPN.'
    ),
    (
      RegExp(r'outbound/socks\[proxy\]: outbound (?:packet )?connection to (\S+)'),
      (m) => 'Соединение с ${m.group(1)} передано ядру Xray — дальше оно идёт по правилам маршрутизации.'
    ),
    (
      RegExp(r'outbound/direct\[direct\]: outbound (?:packet )?connection to (\S+)'),
      (m) => 'Соединение с ${m.group(1)} идёт напрямую, мимо VPN.'
    ),
    (
      RegExp(r'router: sniffed (?:packet )?protocol: (\w+)(?:, domain: (\S+))?'),
      (m) => m.group(2) == null
          ? 'Ядро определило вид соединения: ${m.group(1)}.'
          : 'Ядро определило, к какому сайту идёт соединение: ${m.group(2)}.'
    ),
    (
      RegExp(r'router: match\[\d+\].*=> route\((\w+)\)'),
      (m) => m.group(1) == 'direct'
          ? 'Сработало правило: соединение идёт напрямую, мимо VPN.'
          : 'Сработало правило: соединение идёт через VPN.'
    ),
    (RegExp(r'dns: exchanged (\S+?)\.? NOERROR'), (m) => 'DNS ответил на запрос об адресе ${m.group(1)}.'),
    (
      RegExp(r'dns: exchanged (\S+?)\.? (NXDOMAIN|SERVFAIL)'),
      (m) => 'DNS ответил, что имени ${m.group(1)} не существует или узнать его не удалось.'
    ),
    (
      RegExp(r'connection: connection (?:upload|download) (?:finished|closed)'),
      (_) => 'Соединение завершено.'
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
      (_) => 'Программа на компьютере сама оборвала своё соединение (закрыли вкладку, отменили загрузку, '
          'программа передумала). Обычная строка — на работу VPN не влияет.'
    ),
    (
      RegExp(r'proxy/tun: connection was refused'),
      (_) => 'Программа на компьютере закрыла соединение раньше, чем оно установилось. '
          'Обычная строка — на работу VPN не влияет.'
    ),
    (
      RegExp(r'proxy/tun: operation timed out'),
      (_) => 'Соединение программы долго молчало и закрыто по времени. Разовые случаи — норма.'
    ),
    // Связь с VPN-сервером.
    (
      RegExp(r'observatory.*error ping .* with (\S+):'),
      (m) => 'Ядро само проверяет серверы провайдера, чтобы выбрать лучший: сервер «${m.group(1)}» не ответил '
          'на проверку. Сразу после подключения это обычное дело; если повторяется постоянно — сервер недоступен.'
    ),
    (
      RegExp(r'failed to find an available destination|all retry attempts failed|failed to dial'),
      (_) => 'Не удалось соединиться с VPN-сервером: он недоступен или заблокирован. Попробуйте другой сервер.'
    ),
    (
      RegExp(r'REALITY|reality.*(verify|handshake)|tls: |x509|certificate'),
      (_) => 'Ошибка защищённого соединения с сервером: не сошлись ключи или сертификат. '
          'Обновите подписку; если не поможет — напишите провайдеру.'
    ),
    // Не ответил один DNS-сервер из списка, а не весь DNS: есть ли за ним запасной, по строке не видно.
    (
      RegExp(r'app/dns: failed to retrieve response'),
      (_) => 'Этот DNS-сервер не ответил вовремя. Если в настройках есть запасной, ядро спросит его. '
          'Если таких строк много и сайты не открываются — DNS не отвечает совсем.'
    ),
    (
      RegExp(r'no such host|failed to lookup|lookup .* (timeout|failed)|dns: .*fail'),
      (_) => 'Не удалось узнать адрес сайта (DNS не ответил).'
    ),

    // Windows сама проверяет, есть ли интернет по IPv6 (от этого зависит значок сети), а у этих её
    // адресов есть только IPv6. При выключенном IPv6 ядру некуда подключиться — это не сбой.
    (
      RegExp(r'ipv6\.(msftncsi|msftconnecttest)\.com'),
      (_) => 'Windows проверяет, есть ли интернет по IPv6. Пока IPv6 выключен в настройках, проверка '
          'не проходит — так и должно быть, на работу VPN не влияет.'
    ),

    // DNS ответил «такого имени нет» (код 3): программа стучится на адрес, которого не существует.
    (
      RegExp(r'failed to resolve ip.*domain (\S+) > rcode: 3'),
      (m) => 'Программа запросила адрес ${m.group(1)}, а такого имени не существует — так ответил DNS. '
          'Это не сбой VPN: без него она получила бы тот же отказ.'
    ),

    // Отдельные соединения — обычно не требуют действий.
    (
      RegExp(r'failed to read response from (\S+)'),
      (m) => 'Сайт ${m.group(1)} закрыл соединение, не ответив. Разовые случаи — норма, на VPN не влияют.'
    ),
    (RegExp(r'i/o timeout|deadline exceeded|timed? ?out'), (_) => 'Другая сторона не ответила вовремя.'),
    (
      RegExp(r'connection refused|actively refused'),
      (_) => 'Другая сторона отказала в соединении: порт закрыт или сервис не работает.'
    ),
    (
      RegExp(r'connection reset|forcibly closed|wsarecv|wsasend'),
      (_) => 'Соединение оборвано другой стороной или по пути. Если повторяется на всех сайтах — мешает блокировка или сервер.'
    ),
    (
      RegExp(r'context canceled|closed pipe|use of closed network connection|unexpected EOF|\bEOF\b'),
      (_) => 'Соединение закрыто раньше времени — чаще всего самой программой (закрыли вкладку, отменили загрузку).'
    ),
    (RegExp(r'rejected|blocked'), (_) => 'Соединение отклонено правилами.'),
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
