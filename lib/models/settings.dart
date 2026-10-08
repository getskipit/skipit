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
  /// sing-box держит адаптер и отдаёт трафик в SOCKS-порт Xray.
  singbox,

  /// Адаптер поднимает сам Xray, без sing-box.
  xray,
}

enum PingType { tcp, realDelay }

enum AppTheme { dark, light, system }

/// Канал обновлений SkipIt: только релизы или ещё и пре-релизы (бета).
enum UpdateChannel { stable, beta }

class AppSettings {
  ConnectionMode mode = ConnectionMode.mixed;
  TunCore tunCore = TunCore.xray;
  int socksPort = 10808;
  int httpPort = 10809;
  int apiPort = 10813;
  bool allowLan = false;

  /// Пароль на локальные порты: SOCKS и HTTP пускают только с логином [portUser] и паролем
  /// [portPassword] (свой на каждой установке). Включён по умолчанию. См. также [httpAuth].
  bool portAuth = true;
  String portPassword = randomPassword();
  static const portUser = 'skipit';

  /// HTTP-порт остаётся без пароля в режимах «Смешанный» и «Прокси»: им пользуется системный прокси
  /// Windows, а он пароль передать не умеет.
  bool get httpAuth => portAuth && mode != ConnectionMode.mixed && mode != ConnectionMode.systemProxy;
  bool ipv6 = false;
  bool sniffing = true;
  int mtu = 9000;
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
  bool preferJson = true;
  UpdateChannel updateChannel = UpdateChannel.stable;

  /// Версия, о которой фоновая проверка обновлений уже сообщила: второй раз о ней не напоминает.
  String? updateNotified;
  AppTheme theme = AppTheme.dark;

  String? selectedServerId;
  String? selectedRoutingId;

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
        'socksPort': socksPort,
        'httpPort': httpPort,
        'apiPort': apiPort,
        'allowLan': allowLan,
        'portAuth': portAuth,
        'portPassword': portPassword,
        'ipv6': ipv6,
        'sniffing': sniffing,
        'mtu': mtu,
        'autoSelect': autoSelect,
        'autoReconnect': autoReconnect,
        'killSwitch': killSwitch,
        'connectOnStart': connectOnStart,
        'runAsAdmin': runAsAdmin,
        'testUrl': testUrl,
        'pingType': pingType.name,
        'logLevel': logLevel,
        'userAgent': userAgent,
        'sendHwid': sendHwid,
        'hwid': hwid,
        'updateSubsOnStart': updateSubsOnStart,
        'updateViaProxy': updateViaProxy,
        'sidebarCollapsed': sidebarCollapsed,
        'closeToTray': closeToTray,
        'notifications': notifications,
        'reduceMotion': reduceMotion,
        'preferJson': preferJson,
        'updateChannel': updateChannel.name,
        'updateNotified': updateNotified,
        'theme': theme.name,
        'selectedServerId': selectedServerId,
        'selectedRoutingId': selectedRoutingId,
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
    s.socksPort = asInt(j['socksPort']) ?? s.socksPort;
    s.httpPort = asInt(j['httpPort']) ?? s.httpPort;
    s.apiPort = asInt(j['apiPort']) ?? s.apiPort;
    s.allowLan = parseBool(j['allowLan'], s.allowLan);
    final portPassword = j['portPassword'] as String? ?? '';
    if (portPassword.isNotEmpty) s.portPassword = portPassword;
    s.portAuth = parseBool(j['portAuth'], s.portAuth);
    s.ipv6 = parseBool(j['ipv6'], s.ipv6);
    s.sniffing = parseBool(j['sniffing'], s.sniffing);
    s.mtu = asInt(j['mtu']) ?? s.mtu;
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
    s.preferJson = parseBool(j['preferJson'], s.preferJson);
    s.updateChannel = UpdateChannel.values.asNameMap()[j['updateChannel']] ?? s.updateChannel;
    s.updateNotified = j['updateNotified'] as String?;
    s.theme = AppTheme.values.asNameMap()[j['theme']] ?? s.theme;
    s.selectedServerId = j['selectedServerId'] as String?;
    s.selectedRoutingId = j['selectedRoutingId'] as String?;
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
