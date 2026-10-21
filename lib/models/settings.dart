import '../core/util.dart';
import '../core/windows.dart';
import '../version.dart';

enum ConnectionMode {
  /// Виртуальный адаптер (TUN, см. [TunCore]): весь трафик системы, нужны права администратора.
  tun,

  /// TUN + системный прокси: браузеры идут через HTTP-порт (точнее маршрутизация по доменам),
  /// остальное ловит TUN. Нужны права администратора.
  mixed,

  /// Системный прокси Windows (HTTP) — только программы, которые его уважают.
  systemProxy,

  /// Только локальные SOCKS/HTTP-порты, система не трогается.
  proxyOnly,
}

extension ConnectionModeLabel on ConnectionMode {
  /// Название режима, как на главной.
  String get label => switch (this) {
        ConnectionMode.mixed => 'Смешанный',
        ConnectionMode.tun => 'TUN',
        ConnectionMode.systemProxy => 'Прокси',
        ConnectionMode.proxyOnly => 'Только порты',
      };
}

/// Чем поднимается TUN-адаптер.
enum TunCore {
  /// Адаптер поднимает сам Xray, без sing-box.
  xray,

  /// sing-box держит адаптер и отдаёт трафик в SOCKS-порт Xray.
  singbox,
}

enum PingType { tcp, realDelay }

enum AppTheme { dark, light, system }

/// Канал обновлений SkipIt: только релизы или ещё и пре-релизы (бета).
enum UpdateChannel { stable, beta }

class AppSettings {
  ConnectionMode mode = ConnectionMode.mixed;
  TunCore tunCore = TunCore.xray;

  /// Сетевой стек адаптера sing-box: system, gvisor или mixed (TCP — стек Windows, UDP — gVisor).
  String singboxStack = 'mixed';
  static const singboxStacks = ['system', 'gvisor', 'mixed'];
  int socksPort = 10808;
  int httpPort = 10809;
  int apiPort = 10813;
  bool allowLan = false;

  /// Пароль на локальные порты: SOCKS и HTTP пускают только с логином [portUser] и паролем
  /// [portPassword] (свой на каждой установке). Включён по умолчанию. См. также [httpAuth].
  bool portAuth = true;
  String portPassword = randomPassword();
  String portUser = randomLogin();

  /// Логин служебного входа проверки DNS (пароль у него свой на каждое подключение).
  static const serviceUser = 'skipit';

  /// HTTP-порт закрыт паролем только в режиме «Только порты». В «Смешанном» и «Прокси» им пользуется
  /// системный прокси Windows, а он пароль передать не умеет. В «TUN» порт тоже открыт: программы,
  /// запомнившие системный прокси в «Смешанном» (Telegram, Steam), продолжают ходить через него и после
  /// смены режима — с паролем они остались бы без связи до перезапуска.
  bool get httpAuth => portAuth && mode == ConnectionMode.proxyOnly;
  bool ipv6 = false;
  bool sniffing = true;

  /// Фрагментация: начало соединения с сервером (по умолчанию — приветствие TLS) уходит частями
  /// [fragmentLength] байт с паузами [fragmentInterval] мс. Только серверы из ссылок, см. [XrayConfig.applyServerTweaks].
  bool fragment = false;
  String fragmentPackets = 'tlshello';
  String fragmentLength = '100-200';
  String fragmentInterval = '10-20';

  /// Шумы: перед первым пакетом соединения с сервером поверх UDP (Hysteria, mKCP) — пакет и пауза
  /// [noiseDelay] мс. Вид [noiseType]: `rand` — случайные байты, длина [noisePacket]; `str`, `hex`,
  /// `base64` — заданный пакет [noiseData] (см. [XrayConfig.noiseDataOk]).
  bool noise = false;
  String noiseType = 'rand';
  String noisePacket = '10-20';
  String noiseData = '';
  String noiseDelay = '10-16';

  /// Мультиплексирование: до [muxConcurrency] соединений TCP и до [muxXudp] — UDP (XUDP) по одному
  /// соединению с сервером. −1 — этот вид мимо mux; у XUDP 0 — вместе с TCP.
  bool mux = false;
  int muxConcurrency = 8;
  int muxXudp = 16;
  int mtu = 1500;
  bool autoSelect = false;
  bool autoReconnect = true;

  /// Kill Switch: в режимах с TUN не выпускать трафик мимо VPN, даже если ядро упало.
  bool killSwitch = false;
  bool connectOnStart = false;

  /// При запуске просить права администратора (нужны для TUN и «Смешанного» режима).
  bool runAsAdmin = true;
  String testUrl = 'https://www.gstatic.com/generate_204';
  PingType pingType = PingType.realDelay;
  String logLevel = 'warning';
  /// User-Agent по умолчанию несёт версию программы: провайдер видит, каким SkipIt пользуется клиент.
  static const defaultUserAgent = 'SkipIt/$appVersion';
  String userAgent = defaultUserAgent;

  /// Свой список исключений системного прокси (ProxyOverride в Windows). Пусто — стандартный список.
  String proxyBypass = '';
  bool sendHwid = true;
  String hwid = newId();
  bool updateSubsOnStart = true;
  bool updateViaProxy = true;
  bool sidebarCollapsed = false;
  bool closeToTray = true;

  /// Уведомления Windows о сбоях VPN, пока окно спрятано.
  bool notifications = true;

  /// «Меньше анимаций»: всё в окне переключается мгновенно (для слабых компьютеров).
  bool reduceMotion = false;

  /// Части главной, которые человек спрятал (Настройки → Внешний вид → «На главной»): ключи из [homeParts].
  Set<String> homeHidden = {};
  static const homeParts = {
    'timer': 'Время и страна',
    'mode': 'Режим',
    'speed': 'Скорость',
    'routing': 'Маршрутизация',
  };
  bool homeShows(String part) => !homeHidden.contains(part);

  /// Меню разделов вдоль верхнего края окна, а не слева.
  bool navTop = false;

  /// Масштаб интерфейса в процентах: 80, 90 или 100.
  int uiScale = 100;
  static const uiScales = [80, 90, 100];

  /// Предупреждать о запущенном zapret перед подключением (выключает галочка «Больше не спрашивать»).
  bool zapretWarn = true;
  bool preferJson = true;
  UpdateChannel updateChannel = UpdateChannel.stable;

  /// Версия, о которой фоновая проверка обновлений уже сообщила: второй раз о ней не напоминает.
  String? updateNotified;
  AppTheme theme = AppTheme.dark;

  String? selectedServerId;
  String? selectedRoutingId;

  /// Порядок серверов внутри подписки: `provider` — как прислал провайдер, `delay` — по задержке
  /// (непроверенные и недоступные в конце), `name` — по названию.
  String serverSort = 'provider';

  /// «Мой DNS»: вместо DNS провайдера (или профиля — у обычных серверов) работают два своих адреса:
  /// удалённый — через VPN, локальный — напрямую.
  bool ownDns = false;
  String ownDnsRemote = 'https://cloudflare-dns.com/dns-query';
  String ownDnsDomestic = '77.88.8.8';

  /// Состояние, которое нужно восстановить после сбоя.
  bool systemProxyActive = false;
  SystemProxyState? previousProxy;
  int? lastXrayPid;
  int? lastSingboxPid;

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        // Метка: режим уже выбран с «Смешанным» по умолчанию (см. fromJson).
        'mixedDefault': true,
        'tunCore': tunCore.name,
        'singboxStack': singboxStack,
        'socksPort': socksPort,
        'httpPort': httpPort,
        'apiPort': apiPort,
        'allowLan': allowLan,
        'portAuth': portAuth,
        'portUser': portUser,
        'portPassword': portPassword,
        'ipv6': ipv6,
        'sniffing': sniffing,
        'fragment': fragment,
        'fragmentPackets': fragmentPackets,
        'fragmentLength': fragmentLength,
        'fragmentInterval': fragmentInterval,
        'noise': noise,
        'noiseType': noiseType,
        'noisePacket': noisePacket,
        'noiseData': noiseData,
        'noiseDelay': noiseDelay,
        'mux': mux,
        'muxConcurrency': muxConcurrency,
        'muxXudp': muxXudp,
        'mtu': mtu,
        // Метка: MTU уже переведён с прежних 9000 на 1500 (см. fromJson).
        'mtu1500': true,
        'autoSelect': autoSelect,
        'autoReconnect': autoReconnect,
        'killSwitch': killSwitch,
        'connectOnStart': connectOnStart,
        'runAsAdmin': runAsAdmin,
        'testUrl': testUrl,
        'pingType': pingType.name,
        'logLevel': logLevel,
        'userAgent': userAgent,
        'proxyBypass': proxyBypass,
        'sendHwid': sendHwid,
        'hwid': hwid,
        'updateSubsOnStart': updateSubsOnStart,
        'updateViaProxy': updateViaProxy,
        'sidebarCollapsed': sidebarCollapsed,
        'closeToTray': closeToTray,
        'notifications': notifications,
        'reduceMotion': reduceMotion,
        'zapretWarn': zapretWarn,
        'uiScale': uiScale,
        'navTop': navTop,
        'homeHidden': homeHidden.toList(),
        'preferJson': preferJson,
        'updateChannel': updateChannel.name,
        'updateNotified': updateNotified,
        'theme': theme.name,
        'selectedServerId': selectedServerId,
        'selectedRoutingId': selectedRoutingId,
        'serverSort': serverSort,
        'ownDns': ownDns,
        'ownDnsRemote': ownDnsRemote,
        'ownDnsDomestic': ownDnsDomestic,
        'systemProxyActive': systemProxyActive,
        'previousProxy': previousProxy?.toJson(),
        'lastXrayPid': lastXrayPid,
        'lastSingboxPid': lastSingboxPid,
      };

  static AppSettings fromJson(Map<String, dynamic> j) {
    final s = AppSettings();
    s.mode = ConnectionMode.values.asNameMap()[j['mode']] ?? s.mode;
    // Раньше по умолчанию был TUN — один раз переводим такие настройки на «Смешанный».
    if (j['mixedDefault'] != true && s.mode == ConnectionMode.tun) s.mode = ConnectionMode.mixed;
    s.tunCore = TunCore.values.asNameMap()[j['tunCore']] ?? s.tunCore;
    if (singboxStacks.contains(j['singboxStack'])) s.singboxStack = j['singboxStack'] as String;
    s.socksPort = asInt(j['socksPort']) ?? s.socksPort;
    s.httpPort = asInt(j['httpPort']) ?? s.httpPort;
    s.apiPort = asInt(j['apiPort']) ?? s.apiPort;
    s.allowLan = parseBool(j['allowLan'], s.allowLan);
    final portUser = j['portUser'] as String? ?? '';
    if (portUser.isNotEmpty) s.portUser = portUser;
    final portPassword = j['portPassword'] as String? ?? '';
    if (portPassword.isNotEmpty) s.portPassword = portPassword;
    s.portAuth = parseBool(j['portAuth'], s.portAuth);
    s.ipv6 = parseBool(j['ipv6'], s.ipv6);
    s.sniffing = parseBool(j['sniffing'], s.sniffing);
    s.fragment = parseBool(j['fragment'], s.fragment);
    s.fragmentPackets = j['fragmentPackets'] as String? ?? s.fragmentPackets;
    s.fragmentLength = j['fragmentLength'] as String? ?? s.fragmentLength;
    s.fragmentInterval = j['fragmentInterval'] as String? ?? s.fragmentInterval;
    s.noise = parseBool(j['noise'], s.noise);
    s.noiseType = const ['str', 'hex', 'base64'].contains(j['noiseType']) ? j['noiseType'] as String : s.noiseType;
    s.noisePacket = j['noisePacket'] as String? ?? s.noisePacket;
    s.noiseData = j['noiseData'] as String? ?? s.noiseData;
    s.noiseDelay = j['noiseDelay'] as String? ?? s.noiseDelay;
    s.mux = parseBool(j['mux'], s.mux);
    s.muxConcurrency = asInt(j['muxConcurrency']) ?? s.muxConcurrency;
    s.muxXudp = asInt(j['muxXudp']) ?? s.muxXudp;
    s.mtu = asInt(j['mtu']) ?? s.mtu;
    // Раньше по умолчанию было 9000 — один раз переводим такие настройки на 1500.
    if (j['mtu1500'] != true && s.mtu == 9000) s.mtu = 1500;
    s.autoSelect = parseBool(j['autoSelect'], s.autoSelect);
    s.autoReconnect = parseBool(j['autoReconnect'], s.autoReconnect);
    s.killSwitch = parseBool(j['killSwitch'], s.killSwitch);
    s.connectOnStart = parseBool(j['connectOnStart'], s.connectOnStart);
    s.runAsAdmin = parseBool(j['runAsAdmin'], s.runAsAdmin);
    s.testUrl = j['testUrl'] as String? ?? s.testUrl;
    s.pingType = PingType.values.asNameMap()[j['pingType']] ?? s.pingType;
    s.logLevel = j['logLevel'] as String? ?? s.logLevel;
    // Сохранённое значение вида «SkipIt/<версия>» — это прежнее значение по умолчанию, а не выбор
    // пользователя: после обновления программы версия в нём должна обновиться сама.
    s.proxyBypass = (j['proxyBypass'] as String? ?? '').trim();
    final ua = (j['userAgent'] as String? ?? '').trim();
    s.userAgent = ua.isEmpty || RegExp(r'^SkipIt/[\w.]+$').hasMatch(ua) ? defaultUserAgent : ua;
    s.sendHwid = parseBool(j['sendHwid'], s.sendHwid);
    s.hwid = j['hwid'] as String? ?? s.hwid;
    s.updateSubsOnStart = parseBool(j['updateSubsOnStart'], s.updateSubsOnStart);
    s.updateViaProxy = parseBool(j['updateViaProxy'], s.updateViaProxy);
    s.sidebarCollapsed = parseBool(j['sidebarCollapsed'], s.sidebarCollapsed);
    s.closeToTray = parseBool(j['closeToTray'], s.closeToTray);
    s.notifications = parseBool(j['notifications'], s.notifications);
    s.reduceMotion = parseBool(j['reduceMotion'], s.reduceMotion);
    s.zapretWarn = parseBool(j['zapretWarn'], s.zapretWarn);
    s.navTop = parseBool(j['navTop'], s.navTop);
    final uiScale = asInt(j['uiScale']);
    if (uiScales.contains(uiScale)) s.uiScale = uiScale!;
    final homeHidden = j['homeHidden'];
    if (homeHidden is List) s.homeHidden = {for (final p in homeHidden) if (homeParts.containsKey(p)) p as String};
    s.preferJson = parseBool(j['preferJson'], s.preferJson);
    s.updateChannel = UpdateChannel.values.asNameMap()[j['updateChannel']] ?? s.updateChannel;
    s.updateNotified = j['updateNotified'] as String?;
    s.theme = AppTheme.values.asNameMap()[j['theme']] ?? s.theme;
    s.selectedServerId = j['selectedServerId'] as String?;
    s.selectedRoutingId = j['selectedRoutingId'] as String?;
    s.serverSort = const ['delay', 'name'].contains(j['serverSort']) ? j['serverSort'] as String : s.serverSort;
    s.ownDns = parseBool(j['ownDns'], s.ownDns);
    s.ownDnsRemote = j['ownDnsRemote'] as String? ?? s.ownDnsRemote;
    s.ownDnsDomestic = j['ownDnsDomestic'] as String? ?? s.ownDnsDomestic;
    s.systemProxyActive = parseBool(j['systemProxyActive']);
    final prev = j['previousProxy'];
    s.previousProxy = prev is Map<String, dynamic> ? SystemProxyState.fromJson(prev) : null;
    s.lastXrayPid = asInt(j['lastXrayPid']);
    s.lastSingboxPid = asInt(j['lastSingboxPid']);
    return s;
  }
}
