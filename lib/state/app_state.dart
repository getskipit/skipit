import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/core_manager.dart';
import '../core/kill_switch.dart';
import '../core/link_parser.dart';
import '../core/net.dart';
import '../core/paths.dart';
import '../core/ping.dart';
import '../core/singbox_config.dart';
import '../core/updates.dart';
import '../core/util.dart';
import '../core/windows.dart';
import '../core/xray_config.dart';
import '../models/app_rules.dart';
import '../models/routing.dart';
import '../models/server.dart';
import '../models/settings.dart';
import '../models/subscription.dart';
import '../version.dart';

enum ConnStatus { disconnected, connecting, connected, disconnecting }

/// Вид всплывающего сообщения: от него зависят значок и время показа.
enum ToastKind { success, error, info }

class ToastMessage {
  ToastMessage(this.text, this.kind);
  final String text;
  final ToastKind kind;

  static final _error = RegExp(r'не удалось|ошибк|не найден|не действует|заблокирован|отказ|сначала |не файл|повреждён',
      caseSensitive: false);
  static final _success = RegExp(r'обновлен|добавлен|сохранен|скопирован|загружен|последняя версия',
      caseSensitive: false);

  /// Сообщения программа пишет сама, поэтому вид узнаётся по словам: «не удалось», «ошибка» — сбой,
  /// «обновлена», «скопирован», «сохранено» — успех. Остальное — просто сведение.
  static ToastKind kindOf(String text) =>
      _error.hasMatch(text) ? ToastKind.error : (_success.hasMatch(text) ? ToastKind.success : ToastKind.info);
}

class NeedAdminException implements Exception {
  @override
  String toString() => 'Для режима TUN нужны права администратора';
}

class AppState extends ChangeNotifier {
  AppSettings settings = AppSettings();
  final subscriptions = <Subscription>[];
  final servers = <ServerProfile>[];
  final routingProfiles = <RoutingProfile>[];
  AppRules appRules = AppRules();

  final log = LogBuffer();
  final stats = TrafficStats();
  final _messages = StreamController<ToastMessage>.broadcast();
  Stream<ToastMessage> get messages => _messages.stream;

  late final CoreProcess _xray = CoreProcess('xray', log)
    ..onUnexpectedExit = _onCoreCrash
    ..intercept = _onXrayLine;

  /// Что означает каждый выход текущего конфига Xray: через VPN, напрямую, блокировка.
  final _routes = <String, ConnRoute>{};

  /// Строки журнала доступа Xray — это соединения программ: они идут в список «Подключения»,
  /// а не в общий журнал. Служебные (запросы DNS к самому ядру, статистика) пропускаются.
  bool _onXrayLine(String line) {
    // Ядро не всегда может узнать, какая программа открыла соединение (служебный трафик Windows),
    // и пишет об этом ошибкой на каждое такое соединение. Правилам это не мешает, а журнал забивает.
    // Сама строка в журнал не идёт, но такие соединения считаются и помечаются в «Соединениях»:
    // к ним не применилось правило по приложениям, и это может быть игра из списка «напрямую».
    if (line.contains('Unables to find local process name')) {
      // Первая такая строка за подключение остаётся в журнале как образец — с причиной от Windows.
      final first = (log.current?.unknownProcess ?? 0) == 0;
      _noteUnknownProcess(unknownProcessSource(line));
      return !first;
    }
    final c = ConnEntry.tryParse(line, _routes);
    if (c == null) {
      _watchFirewall('skipit-xray.exe', line);
      return false;
    }
    final failedAt = _unknownSources.remove(c.source);
    if (failedAt != null && DateTime.now().difference(failedAt) < const Duration(seconds: 3)) c.unknownProcess = true;
    // Собственная проверка связи — не соединение программы.
    if (c.route != ConnRoute.dns && c.inbound != 'api' && c.inbound != XrayConfig.checkInTag) log.addConnection(c);
    return true;
  }
  late final CoreProcess _singbox = CoreProcess('sing-box', log)
    ..onUnexpectedExit = _onCoreCrash
    ..intercept = (line) {
      _watchFirewall('skipit-sing-box.exe', line);
      // Та же ситуация у sing-box (строка видна на уровне журнала info и подробнее).
      if (line.contains('failed to search process')) _noteUnknownProcess(null);
      return false;
    };

  /// Адреса программ, для которых ядро только что не узнало программу: следующая строка журнала
  /// доступа с тем же адресом — это то самое соединение.
  final _unknownSources = <String, DateTime>{};

  static final _address = RegExp(r'((?:\d{1,3}\.){3}\d{1,3}|\[[0-9a-fA-F:]+\]):(\d{1,5})');

  /// Локальный адрес программы из строки ядра «Unables to find local process name: …»;
  /// null — адреса в строке нет.
  static String? unknownProcessSource(String line) {
    final at = line.indexOf('Unables to find local process name');
    if (at < 0) return null;
    final m = _address.allMatches(line.substring(at)).lastOrNull;
    return m == null ? null : '${m.group(1)}:${m.group(2)}';
  }

  void _noteUnknownProcess(String? source) {
    if (source != null) {
      if (_unknownSources.length > 500) _unknownSources.clear();
      _unknownSources[source] = DateTime.now();
    }
    final n = log.addUnknownProcess();
    // В журнал — на 1-м, 10-м, 100-м… соединении: иначе строк было бы столько же, сколько соединений.
    if (appRules.mode != AppRoutingMode.off && const {1, 10, 100, 1000, 10000}.contains(n)) {
      log.add('app', 'Ядро не узнало, какая программа открыла соединение (таких уже $n). Правила по приложениям '
          'к ним не применились — какие это соединения, отмечено на вкладке «Соединения»');
    }
  }

  /// Так в журнале ядра выглядит запрет файрвола на выход в сеть (ошибки Windows 10013 и 10057) —
  /// по-английски и по-русски, как их печатает Windows.
  static final _firewallLine = RegExp(
      r'forbidden by its access permissions|socket is not connected|'
      r'запрещенным правами доступа|сокет не подключен',
      caseSensitive: false);

  static bool looksLikeFirewall(String line) => _firewallLine.hasMatch(line);

  /// Ядро, которому файрвол не даёт выйти в сеть (имя файла), и сколько раз это встретилось
  /// в журнале текущего подключения. Одна такая строка бывает случайной, несколько подряд — нет.
  String? _firewallCore;
  var _firewallHits = 0;

  void _watchFirewall(String exe, String line) {
    if (!looksLikeFirewall(line)) return;
    _firewallCore = exe;
    if (++_firewallHits == 3) {
      // Не ждём очередной проверки связи: если ядро и правда не выпускают, это видно сразу.
      _linkTimer?.cancel();
      unawaited(_checkLink());
    }
  }

  /// Файл ядра, который нужно разрешить в файрволе; null — признаков блокировки нет.
  /// Показывается, только когда связи через VPN действительно нет.
  String? get firewallBlockedCore => linkDown && _firewallHits >= 3 ? _firewallCore : null;

  Future<void> showCoreFile(String exe) =>
      Process.run('explorer', ['/select,${AppPaths.coreDir.path}\\$exe']);

  // --- Проверка связи через VPN ---

  /// Порт входа проверки связи в ядре (см. [XrayConfig.addCheckInbound]).
  int? _checkPort;
  Timer? _linkTimer;
  var _linkFails = 0;

  /// Страна, из которой сайты видят этот компьютер через VPN (код `fi`); null — ещё не узнали.
  String? exitCountry;

  /// VPN числится подключённым, но запросы через сервер не проходят (две проверки подряд).
  /// С признаками блокировки файрволом хватает и одной неудачной проверки.
  bool get linkDown => isConnected && (_linkFails >= 2 || (_linkFails >= 1 && _firewallHits >= 3));

  @visibleForTesting
  set linkFailsForTest(int value) => _linkFails = value;

  void _startLinkCheck() {
    _linkTimer?.cancel();
    _linkFails = 0;
    exitCountry = null;
    _linkTimer = Timer(const Duration(seconds: 1), _checkLink);
  }

  void _stopLinkCheck() {
    _linkTimer?.cancel();
    _linkTimer = null;
    _checkPort = null;
    _linkFails = 0;
    exitCountry = null;
    _firewallCore = null;
    _firewallHits = 0;
  }

  Future<void> _checkLink() async {
    final port = _checkPort;
    if (port == null || status != ConnStatus.connected) return;
    String? country;
    var ok = true;
    try {
      country = await Net.exitCountry(XrayConfig.checkHost, port);
    } catch (_) {
      ok = false;
    }
    // Пока шёл запрос, подключение могло смениться — его результат уже не про текущее.
    if (port != _checkPort || status != ConnStatus.connected) return;
    final wasDown = linkDown;
    if (ok) {
      _linkFails = 0;
      if (country != null) exitCountry = country;
      if (wasDown) log.add('app', 'Связь через VPN восстановилась');
    } else {
      _linkFails++;
      if (!wasDown && linkDown) log.add('app', 'Ошибка: VPN подключён, но связи через сервер нет');
    }
    notifyListeners();
    // После неудачи перепроверяем быстрее: и чтобы не тревожить зря, и чтобы скорее снять тревогу.
    _linkTimer?.cancel();
    _linkTimer = Timer(Duration(seconds: ok ? 30 : 3), _checkLink);
  }

  ConnStatus status = ConnStatus.disconnected;

  /// Открытый раздел меню — живёт здесь, чтобы пережить перестройку окна при смене темы.
  int pageIndex = 0;

  /// Разделы меню по порядку: главная, маршрутизация, логи, настройки.
  static const routingPage = 1;

  void openPage(int index) {
    pageIndex = index;
    notifyListeners();
  }

  /// Какая маршрутизация сейчас действует — коротко, для главной.
  /// У серверов с JSON-конфигом провайдера работают его правила, выбранный профиль не применяется.
  /// [sites] — правила для сайтов и IP, [apps] — правила по программам (null, если их нет
  /// или режим подключения их не применяет).
  ({String sites, String? apps}) get routingSummary {
    final server = selectedServer;
    final sites = server != null && XrayConfig.providerConfig(server) != null ? 'Правила провайдера' : selectedRouting.name;
    final count = appRules.enabledMatches.length;
    final apps = !usesTun
        ? null
        : switch (appRules.mode) {
            AppRoutingMode.off => null,
            AppRoutingMode.allExcept => count == 0 ? null : 'Программ напрямую, мимо VPN: $count',
            AppRoutingMode.onlySelected => 'Через VPN только выбранные программы: $count',
          };
    return (sites: sites, apps: apps);
  }
  String? lastError;
  DateTime? connectedAt;
  bool pinging = false;
  final updatingSubs = <String>{};
  bool autostart = false;
  final isAdmin = WinSys.isAdmin();

  Timer? _statsTimer;

  /// Запрос счётчиков трафика у ядер текущего подключения.
  Future<void> Function({bool xray})? _pollStats;

  /// Окно на экране (не свёрнуто и не спрятано в трей). Пока его не видно, счётчики трафика
  /// у ядра Xray не запрашиваются.
  bool get windowVisible => _windowVisible;
  bool _windowVisible = true;

  set windowVisible(bool value) {
    if (_windowVisible == value) return;
    _windowVisible = value;
    // Окно открыли — цифры обновляются сразу, а не через секунду.
    if (value && status == ConnStatus.connected) {
      unawaited(_pollStats?.call().then((_) => notifyListeners()));
    }
  }
  Timer? _subsTimer;
  Timer? _saveTimer;
  final _crashTimes = <DateTime>[];

  // ---------------------------------------------------------------------------
  // Загрузка / сохранение
  // ---------------------------------------------------------------------------

  /// Читает сохранённые настройки и подписки. Вызывается до показа окна: по настройкам решается,
  /// нужно ли сначала перезапуститься с правами администратора.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    await _load();
  }

  bool _loaded = false;

  /// Настройка «Запускать от имени администратора» включена, а прав нет — нужно перезапуститься.
  /// После отказа в окне Windows (ключ --no-elevate) повторно не спрашиваем.
  bool needsElevation(List<String> args) =>
      settings.runAsAdmin && !isAdmin && !args.contains('--elevated') && !args.contains('--no-elevate');

  Future<void> init(List<String> args) async {
    unawaited(log.open(AppPaths.logDir));
    KillSwitch.onLog = (text) => log.add('app', text);
    await load();
    if (protectedUnreadable) {
      lastError = 'Сохранённые подписки зашифрованы для другой учётной записи Windows и не читаются. '
          'Добавьте подписки заново или загрузите файл экспорта: Настройки → О приложении → Импорт.';
    }
    // Окно должно узнать о данных сразу, даже если дальше что-то пойдёт не так.
    notifyListeners();

    // Каждый шаг запуска изолирован: сбой одного не должен оставлять окно пустым.
    Future<void> step(String name, Future<void> Function() f) async {
      try {
        await f();
      } catch (e) {
        log.add('app', 'Сбой при запуске ($name): $e');
      }
    }

    await step('восстановление', _recoverAfterCrash);
    // Установщик прошлого обновления больше не нужен.
    await step('уборка обновлений', () async {
      final dir = Directory('${File(AppPaths.exe).parent.path}\\update');
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    await step('ссылки skipit://', WinSys.registerUrlScheme);
    await step('автозапуск', () async => autostart = await WinSys.isAutostartEnabled());
    unawaited(step('версии ядер', detectCoreVersions));
    // Тихая проверка обновлений через несколько секунд после запуска.
    Timer(const Duration(seconds: 8), () => step('обновления', () => checkUpdates(silent: true)));
    notifyListeners();

    // Раз в минуту смотрим, не пора ли обновить подписки (проверка дешёвая — сравнение времени).
    _subsTimer = Timer.periodic(const Duration(minutes: 1), (_) => _updateDueSubscriptions());

    await handleArgs(args);
    final wantConnect = args.contains('--connect') ||
        (settings.connectOnStart && (args.contains('--autostart') || args.contains('--elevated')));
    if (wantConnect && selectedServer != null) {
      // Подписки обновляем после подключения, а не одновременно с ним: запросы, начатые напрямую,
      // оборвались бы на полпути, когда трафик уходит в адаптер (а Kill Switch их просто не выпустит).
      unawaited(() async {
        try {
          await connect();
        } catch (_) {
          // Нет прав администратора — об этом уже написано в журнале и на главной.
        }
        if (settings.updateSubsOnStart) await _updateDueSubscriptions(force: true);
      }());
    } else if (settings.updateSubsOnStart) {
      unawaited(_updateDueSubscriptions(force: true));
    }
  }

  /// true — файл данных есть, но прочитать его не удалось. Тогда ничего не сохраняем,
  /// чтобы не затереть подписки пустым состоянием.
  bool _stateUnreadable = false;

  /// Читает файл, переживая кратковременные блокировки (антивирус, выходящая копия программы).
  static Future<String> _readWithRetry(File file) async {
    for (var attempt = 1;; attempt++) {
      try {
        return await file.readAsString();
      } on FileSystemException {
        if (attempt >= 15) rethrow;
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  Future<void> _load() async {
    final file = File(AppPaths.stateFile);
    if (file.existsSync()) {
      String text;
      try {
        text = await _readWithRetry(file);
      } catch (e) {
        _stateUnreadable = true;
        log.add('app', 'Файл данных занят или недоступен, сохранение отключено до перезапуска: $e');
        text = '';
      }
      if (text.isNotEmpty) try {
        final j = jsonDecode(text) as Map<String, dynamic>;
        _applyData(j, secret: await _readSecret(j, file));
      } catch (e) {
        // Файл повреждён: откладываем копию и продолжаем с чистого листа.
        log.add('app', 'Не удалось разобрать файл данных, копия сохранена как state.json.broken: $e');
        try {
          await file.copy('${file.path}.broken');
        } catch (_) {}
      }
    }
    routingProfiles.removeWhere((r) => RoutingProfile.legacyPresetIds.contains(r.id));
    if (!routingProfiles.any((r) => r.id == RoutingProfile.globalPresetId)) {
      routingProfiles.insert(0, RoutingProfile.global());
    }
    if (!routingProfiles.any((r) => r.id == settings.selectedRoutingId)) {
      settings.selectedRoutingId = RoutingProfile.globalPresetId;
    }
  }

  /// Раскладывает прочитанные данные по спискам. Подписки и серверы берутся из [secret]:
  /// в файле они зашифрованы, в старом файле и в файле экспорта лежат открыто рядом с настройками.
  void _applyData(Map<String, dynamic> j, {required Map<String, dynamic> secret}) {
    settings = AppSettings.fromJson(j['settings'] as Map<String, dynamic>? ?? const {});
    subscriptions.addAll(((secret['subscriptions'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(Subscription.fromJson));
    servers.addAll(
        ((secret['servers'] as List?) ?? const []).whereType<Map<String, dynamic>>().map(ServerProfile.fromJson));
    routingProfiles.addAll(
        ((j['routing'] as List?) ?? const []).whereType<Map<String, dynamic>>().map(RoutingProfile.fromJson));
    appRules = AppRules.fromJson(j['apps'] as Map<String, dynamic>? ?? const {});
  }

  /// Подписки и серверы хранятся зашифрованными ключом учётной записи Windows (поле `protected`):
  /// файл, скопированный на другой компьютер или открытый другим пользователем, их не выдаст.
  /// Старый файл без шифрования читается как есть и шифруется при первом сохранении.
  Future<Map<String, dynamic>> _readSecret(Map<String, dynamic> j, File file) async {
    final blob = j['protected'];
    if (blob is! String) return j;
    final plain = WinSys.unprotect(base64Decode(blob));
    if (plain != null) return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    // Чужой ключ: файл принесли с другого компьютера или из-под другой учётной записи.
    // Зашифрованную часть откладываем — вдруг её ещё откроют там, где она была создана.
    protectedUnreadable = true;
    log.add('app', 'Ошибка: подписки в файле данных зашифрованы для другой учётной записи Windows и не читаются. '
        'Копия сохранена как state.json.locked');
    try {
      final locked = File('${file.path}.locked');
      if (!locked.existsSync()) await file.copy(locked.path);
    } catch (_) {}
    return const {};
  }

  /// Конфиг ядра на диск не пишется: в нём адреса и ключи серверов. Исключение — тестовая копия
  /// разработчика: ей файл нужен для разбора неполадок. Файл, оставшийся от прежних версий, удаляется.
  static Future<void> _debugCopy(String path, String text) async {
    try {
      final file = File(path);
      if (AppPaths.isDev) {
        await file.writeAsString(text);
      } else if (file.existsSync()) {
        await file.delete();
      }
    } catch (_) {}
  }

  /// Подписки из файла данных прочитать не удалось: они зашифрованы не для этой учётной записи.
  /// Окно предлагает импортировать файл экспорта.
  bool protectedUnreadable = false;

  /// Что записывается в файл данных. [encrypt] false — всё открытым текстом (файл экспорта).
  Map<String, dynamic> _dataForFile({required bool encrypt}) {
    final secret = {
      'subscriptions': subscriptions.map((e) => e.toJson()).toList(),
      'servers': servers.map((e) => e.toJson()).toList(),
    };
    final blob = encrypt ? WinSys.protect(utf8.encode(jsonEncode(secret))) : null;
    return {
      'settings': settings.toJson(),
      // Зашифровать не удалось — пишем открыто: потерять подписки хуже, чем хранить их как раньше.
      if (blob != null) 'protected': base64Encode(blob) else ...secret,
      'routing': routingProfiles.map((e) => e.toJson()).toList(),
      'apps': appRules.toJson(),
    };
  }

  /// Сохраняет все настройки, подписки и серверы в файл в папке [dir] — открытым текстом, чтобы его
  /// можно было перенести на другой компьютер. Возвращает путь к файлу.
  Future<String> exportData(String dir) async {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final path = '$dir\\${AppPaths.appName} — настройки ${now.year}-${two(now.month)}-${two(now.day)}.json';
    final data = _dataForFile(encrypt: false);
    // Состояние текущего подключения в перенос не идёт.
    (data['settings'] as Map<String, dynamic>)
      ..['systemProxyActive'] = false
      ..remove('previousProxy')
      ..remove('lastXrayPid')
      ..remove('lastSingboxPid');
    await File(path).writeAsString(const JsonEncoder.withIndent('  ').convert({'skipitExport': 1, ...data}), flush: true);
    log.add('app', 'Настройки сохранены в файл экспорта');
    return path;
  }

  /// Заменяет настройки, подписки и серверы содержимым файла экспорта (или старого state.json).
  /// Возвращает текст ошибки или null, если всё получилось.
  Future<String?> importData(String path) async {
    if (status != ConnStatus.disconnected) return 'Сначала отключите VPN';
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return 'Это не файл настроек SkipIt';
    }
    if (j['settings'] is! Map || (j['subscriptions'] is! List && j['protected'] is! String)) {
      return 'Это не файл настроек SkipIt';
    }
    final Map<String, dynamic> secret;
    if (j['protected'] is String) {
      final plain = WinSys.unprotect(base64Decode(j['protected'] as String));
      if (plain == null) {
        return 'Файл зашифрован для другой учётной записи Windows. Нужен файл, сохранённый кнопкой «Экспорт»';
      }
      secret = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    } else {
      secret = j;
    }
    // Прежние данные держим до конца разбора: если файл окажется повреждённым, всё вернётся как было.
    final before = (settings, List.of(subscriptions), List.of(servers), List.of(routingProfiles), appRules);
    subscriptions.clear();
    servers.clear();
    routingProfiles.clear();
    try {
      _applyData(j, secret: secret);
    } catch (_) {
      settings = before.$1;
      subscriptions
        ..clear()
        ..addAll(before.$2);
      servers
        ..clear()
        ..addAll(before.$3);
      routingProfiles
        ..clear()
        ..addAll(before.$4);
      appRules = before.$5;
      return 'Файл настроек повреждён';
    }
    // Состояние системы — от этого компьютера, а не из файла.
    settings
      ..systemProxyActive = before.$1.systemProxyActive
      ..previousProxy = before.$1.previousProxy
      ..lastXrayPid = null
      ..lastSingboxPid = null;
    if (!routingProfiles.any((r) => r.id == RoutingProfile.globalPresetId)) {
      routingProfiles.insert(0, RoutingProfile.global());
    }
    if (!routingProfiles.any((r) => r.id == settings.selectedRoutingId)) {
      settings.selectedRoutingId = RoutingProfile.globalPresetId;
    }
    protectedUnreadable = false;
    _stateUnreadable = false;
    log.add('app', 'Настройки загружены из файла: подписок — ${subscriptions.length}, серверов — ${servers.length}');
    await saveNow();
    notifyListeners();
    return null;
  }

  @visibleForTesting
  Future<void> loadForTest() => _load();

  void save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), saveNow);
  }

  Future<void> saveNow() async {
    _saveTimer?.cancel();
    if (_stateUnreadable) return;
    final data = _dataForFile(encrypt: true);
    final text = const JsonEncoder.withIndent('  ').convert(data);
    // Пишем во временный файл и подменяем; если файл занят — несколько попыток, потом прямая запись.
    for (var attempt = 1; attempt <= 10; attempt++) {
      try {
        final tmp = File('${AppPaths.stateFile}.tmp');
        await tmp.writeAsString(text, flush: true);
        await tmp.rename(AppPaths.stateFile);
        return;
      } on FileSystemException catch (e) {
        if (attempt == 10) {
          try {
            await File(AppPaths.stateFile).writeAsString(text, flush: true);
          } catch (_) {
            log.add('app', 'Не удалось сохранить данные: $e');
          }
          return;
        }
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
  }

  void changed() {
    save();
    notifyListeners();
  }

  /// Уборка своих зависших адаптеров, начатая при запуске (см. [_recoverAfterCrash]).
  Future<void>? _tunCleanup;

  /// Если прошлый запуск упал — вернуть системный прокси и добить процессы ядра.
  Future<void> _recoverAfterCrash() async {
    // Ядра, оставшиеся от прошлого запуска (например, после принудительного закрытия), держат порты.
    for (final pid in WinSys.processesUnder(AppPaths.coreDir.path)) {
      await WinSys.killPid(pid);
    }
    if (settings.systemProxyActive) {
      await WinSys.restoreProxy(settings.previousProxy);
      settings.systemProxyActive = false;
    }
    settings.lastXrayPid = settings.lastSingboxPid = null;
    await saveNow();
    // Свои адаптеры, зависшие после сбоя (ядра уже остановлены выше). В фоне: запуск окна не ждёт,
    // но подключение дождётся конца уборки — иначе она могла бы удалить только что созданный адаптер.
    _tunCleanup = WinSys.removeOwnTunAdapters();
  }

  Future<void> shutdown() async {
    await disconnect();
    // Kill Switch мог держать интернет закрытым и без подключения — при выходе снимаем его.
    await KillSwitch.release();
    await saveNow();
    log.close();
  }

  /// Всплывающее сообщение внизу окна. [kind] не задан — определяется по тексту (см. [ToastMessage.kindOf]).
  void toast(String msg, {ToastKind? kind}) => _messages.add(ToastMessage(msg, kind ?? ToastMessage.kindOf(msg)));

  // ---------------------------------------------------------------------------
  // Выборки
  // ---------------------------------------------------------------------------

  ServerProfile? get selectedServer {
    final id = settings.selectedServerId;
    for (final s in servers) {
      if (s.id == id) return s;
    }
    return null;
  }

  RoutingProfile get selectedRouting => routingProfiles.firstWhere(
        (r) => r.id == settings.selectedRoutingId,
        orElse: () => routingProfiles.firstWhere((r) => r.id == RoutingProfile.globalPresetId),
      );

  List<ServerProfile> serversOf(String? subscriptionId) =>
      servers.where((s) => s.subscriptionId == subscriptionId).toList();

  Subscription? subscriptionById(String? id) {
    for (final s in subscriptions) {
      if (s.id == id) return s;
    }
    return null;
  }

  bool get usesTun => settings.mode == ConnectionMode.tun || settings.mode == ConnectionMode.mixed;

  /// TUN поднимает само ядро Xray, sing-box не запускается.
  bool get xrayTun => usesTun && settings.tunCore == TunCore.xray;
  bool get isConnected => status == ConnStatus.connected;
  bool get isBusy => status == ConnStatus.connecting || status == ConnStatus.disconnecting;

  // ---------------------------------------------------------------------------
  // Импорт
  // ---------------------------------------------------------------------------

  /// Ссылки, пришедшие извне (клик по skipit:// на сайте, второй запуск программы). Их не импортируем
  /// молча — окно спрашивает подтверждение: иначе любой сайт мог бы подсунуть свою подписку и сервер.
  final pendingLinks = <String>[];

  Future<void> handleArgs(List<String> args) async {
    final links = [for (final a in args) if (a.contains('://')) a];
    if (links.isEmpty) return;
    pendingLinks.addAll(links);
    notifyListeners();
  }

  /// Ответ пользователя на запрос о внешней ссылке.
  Future<void> resolvePendingLink(String link, {required bool accept}) async {
    pendingLinks.remove(link);
    notifyListeners();
    if (accept) await importText(link);
  }

  /// Вставка из буфера, диплинк или ручной ввод. Возвращает краткий итог.
  Future<String> importText(String text) async {
    final r = LinkParser.parseText(text);
    final parts = <String>[];

    if (r.servers.isNotEmpty) {
      servers.addAll(r.servers);
      settings.selectedServerId ??= r.servers.first.id;
      parts.add('серверов: ${r.servers.length}');
    }
    for (final rd in r.routing) {
      parts.add(_applyRoutingDeeplink(rd));
    }
    for (final url in r.subscriptionUrls) {
      final existing = subscriptions.where((s) => s.url == url).firstOrNull;
      if (existing != null) {
        // Без отдельного сообщения: итог вставки скажет то же самое одним сообщением.
        await updateSubscription(existing, silent: true);
        parts.add(existing.error == null ? 'подписка обновлена' : 'подписка с ошибкой: ${existing.error}');
      } else {
        final sub = Subscription(url: url);
        subscriptions.add(sub);
        await updateSubscription(sub, silent: true);
        parts.add(sub.error == null ? 'подписка «${sub.displayName}»' : 'подписка с ошибкой: ${sub.error}');
      }
    }
    changed();

    final summary = parts.isEmpty
        ? (r.errors.isNotEmpty ? r.errors.first : 'Ничего не найдено')
        : 'Добавлено: ${parts.join(', ')}${r.errors.isNotEmpty ? ' (ошибок: ${r.errors.length})' : ''}';
    for (final e in r.errors) {
      log.add('import', e);
    }
    toast(summary);
    return summary;
  }

  String _applyRoutingDeeplink(RoutingDeeplink rd, {String? subscriptionId}) {
    if (rd.off) {
      setRouting(RoutingProfile.globalPresetId);
      return 'маршрутизация отключена';
    }
    final p = rd.profile!..subscriptionId = subscriptionId;
    final idx = routingProfiles.indexWhere((e) =>
        (subscriptionId != null && e.subscriptionId == subscriptionId) ||
        (e.name == p.name && !e.id.startsWith('preset-')));
    if (idx >= 0) {
      p.id = routingProfiles[idx].id;
      routingProfiles[idx] = p;
    } else {
      routingProfiles.add(p);
    }
    if (rd.activate || subscriptionId != null) setRouting(p.id);
    return 'маршрутизация «${p.name}»';
  }

  // ---------------------------------------------------------------------------
  // Подписки
  // ---------------------------------------------------------------------------

  Future<void> _updateDueSubscriptions({bool force = false}) async {
    for (final s in List.of(subscriptions)) {
      if (!force && !s.isDue) continue;
      // После неудачи повторяем не чаще раза в 5 минут, а не каждую минуту.
      final failed = _subRetryAfter[s.id];
      if (!force && failed != null && DateTime.now().isBefore(failed)) continue;
      await updateSubscription(s, silent: true);
      if (s.error != null) {
        // Сервер отказал по существу (подписка закончилась, ссылка не действует) — частые повторы
        // ничего не изменят, пробуем раз в час.
        _subRetryAfter[s.id] = DateTime.now().add(Duration(minutes: _subsRefused.contains(s.id) ? 60 : 5));
      } else {
        _subRetryAfter.remove(s.id);
        if (!force) log.add('subscription', '«${s.displayName}» обновлена автоматически');
      }
    }
  }

  final _subRetryAfter = <String, DateTime>{};

  /// Подписки, на последний запрос которых сервер ответил отказом.
  final _subsRefused = <String>{};

  /// Загрузка подписки с общим ограничением по времени: зависший запрос не должен навсегда
  /// блокировать следующие обновления. Если через VPN не получилось — пробуем напрямую.
  Future<FetchedSubscription> _fetchSubscription(Subscription sub) async {
    const limit = Duration(seconds: 45);
    final viaProxy = isConnected && settings.updateViaProxy ? (_session ?? settings).httpPort : null;
    // Пока VPN подключён, «напрямую» — это через ядро мимо VPN-сервера (см. XrayConfig.addDirectInbound):
    // обычный запрос в режиме TUN ушёл бы в тот же туннель, а Kill Switch его не выпустил бы вовсе.
    // Так идут только подписки по https: по http ссылка с ключом ушла бы открытым текстом через
    // интернет-провайдера. Для них остаётся обычный запрос — в режиме TUN он идёт через туннель.
    // Порт берётся в момент запроса: за время первой попытки VPN могли отключить.
    Future<FetchedSubscription> direct() => Net.fetchSubscription(sub.url, settings,
            proxyPort: isConnected && directSubscriptionHost(sub.url) != null ? _directPort : null)
        .timeout(limit);
    // Сервер подписки уже не ответил через VPN, а напрямую ответил — не ждём таймаута ещё раз.
    if (viaProxy != null && !_subsDirectOnly.contains(sub.id)) {
      try {
        return await Net.fetchSubscription(sub.url, settings, proxyPort: viaProxy).timeout(limit);
      } catch (e) {
        // Сервер ответил отказом — запрос дошёл, идти другим путём незачем.
        if (e is ServerRefused && e.isFinal) rethrow;
        log.add('subscription', '${sub.displayName}: через VPN не удалось (${scrubUrls('$e')}), пробую напрямую');
      }
      final fetched = await direct();
      _subsDirectOnly.add(sub.id);
      return fetched;
    }
    return direct();
  }

  /// Сервер подписки, к которому можно обращаться мимо VPN-сервера: только для ссылок по https.
  static String? directSubscriptionHost(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty ? uri.host : null;
  }

  /// Подписки, чей сервер не отвечает через VPN, но отвечает напрямую (до перезапуска программы).
  final _subsDirectOnly = <String>{};

  /// Порт входа «мимо VPN-сервера» в текущем подключении (null — не подключены).
  int? _directPort;

  Future<void> updateAllSubscriptions() => _updateDueSubscriptions(force: true);

  Future<void> updateSubscription(Subscription sub, {bool silent = false}) async {
    if (!updatingSubs.add(sub.id)) return;
    notifyListeners();
    try {
      final fetched = await _fetchSubscription(sub);
      sub.applyMeta(fetched.meta);
      sub.lastUpdated = DateTime.now();
      sub.error = null;
      _subsRefused.remove(sub.id);

      final old = {for (final s in serversOf(sub.id)) s.link: s};
      // Если формат сменился (ссылки → JSON), ссылки не совпадут — узнаём сервер по названию,
      // чтобы не сбросить выбор и замеры задержки.
      final oldByName = {for (final s in serversOf(sub.id)) s.name: s};
      final fresh = <ServerProfile>[];
      for (final s in fetched.result.servers) {
        final prev = old[s.link] ?? oldByName[s.name];
        fresh.add(prev == null
            ? (s..subscriptionId = sub.id)
            : ServerProfile(
                id: prev.id,
                name: s.name,
                protocol: s.protocol,
                address: s.address,
                port: s.port,
                link: s.link,
                outbound: s.outbound,
                subscriptionId: sub.id,
                delayMs: prev.delayMs,
                warning: s.warning,
              ));
      }
      if (fresh.isEmpty && fetched.result.servers.isEmpty) {
        sub.error = fetched.result.errors.isNotEmpty ? fetched.result.errors.first : 'Подписка пуста';
      } else {
        final insertAt = servers.indexWhere((s) => s.subscriptionId == sub.id);
        servers.removeWhere((s) => s.subscriptionId == sub.id);
        servers.insertAll(insertAt < 0 ? servers.length : insertAt, fresh);
        if (selectedServer == null && fresh.isNotEmpty) settings.selectedServerId = fresh.first.id;
      }

      // Провайдер может прислать профиль маршрутизации заголовком `routing`.
      final routingLink = fetched.meta['routing'];
      if (routingLink != null && RoutingProfile.isDeeplink(routingLink)) {
        final rd = RoutingProfile.parseDeeplink(routingLink);
        if (rd != null) _applyRoutingDeeplink(rd, subscriptionId: sub.id);
      }
      if (!silent) toast('Подписка «${sub.displayName}» обновлена — серверов: ${fresh.length}');
    } catch (e) {
      sub.error = describeNetError(e);
      final refused = e is ServerRefused && e.isFinal;
      refused ? _subsRefused.add(sub.id) : _subsRefused.remove(sub.id);
      // Адрес подписки — ключ доступа: в журнал он не пишется, даже если попал в текст ошибки.
      log.add('subscription',
          '${sub.displayName}: не удалось обновить подписку — ${e is ServerRefused ? e.reason : scrubUrls('$e')}');
      if (!silent) toast('Не удалось обновить «${sub.displayName}»: ${sub.error}');
    } finally {
      updatingSubs.remove(sub.id);
      changed();
    }
  }

  void deleteSubscription(Subscription sub) {
    subscriptions.remove(sub);
    servers.removeWhere((s) => s.subscriptionId == sub.id);
    routingProfiles.removeWhere((r) => r.subscriptionId == sub.id);
    if (selectedServer == null) settings.selectedServerId = servers.firstOrNull?.id;
    changed();
  }

  void deleteServer(ServerProfile s) {
    servers.remove(s);
    if (settings.selectedServerId == s.id) settings.selectedServerId = servers.firstOrNull?.id;
    changed();
  }

  // ---------------------------------------------------------------------------
  // Пинг
  // ---------------------------------------------------------------------------

  PingCancel? _pingCancel;

  /// Останавливает идущую проверку задержки (повторное нажатие на её кнопку).
  Future<void> cancelPing() async => _pingCancel?.cancel();

  Future<void> ping(List<ServerProfile> list) async {
    if (pinging || list.isEmpty) return;
    pinging = true;
    final cancel = _pingCancel = PingCancel();
    // Прежние значения: если проверку остановят, у непроверенных серверов они вернутся.
    final before = {for (final s in list) s: s.delayMs};
    for (final s in list) {
      s.delayMs = null;
    }
    notifyListeners();
    void onResult(ServerProfile s, int ms) {
      s.delayMs = ms;
      notifyListeners();
    }

    try {
      if (settings.pingType == PingType.tcp) {
        await Pinger.tcpAll(list, onResult, cancel);
      } else {
        await Pinger.realDelayAll(list, settings.testUrl, log, onResult, cancel);
      }
    } catch (e) {
      if (!cancel.cancelled) toast('Ошибка проверки: $e');
    } finally {
      if (cancel.cancelled) {
        for (final s in list) {
          s.delayMs ??= before[s];
        }
      }
      _pingCancel = null;
      pinging = false;
      changed();
    }
  }

  ServerProfile? bestOf(List<ServerProfile> list) {
    final ok = list.where((s) => (s.delayMs ?? -1) > 0).toList()
      ..sort((a, b) => a.delayMs!.compareTo(b.delayMs!));
    return ok.firstOrNull;
  }

  // ---------------------------------------------------------------------------
  // Подключение
  // ---------------------------------------------------------------------------

  Future<void> selectServer(String id) async {
    settings.selectedServerId = id;
    changed();
    if (isConnected) await reconnect();
  }

  /// Действует ли сейчас выбранный профиль маршрутизации: у серверов с JSON-конфигом провайдера
  /// работают его правила, профиль не применяется.
  bool get routingApplies {
    final server = selectedServer;
    return server == null || XrayConfig.providerConfig(server) == null;
  }

  void setRouting(String id) {
    final same = settings.selectedRoutingId == id;
    settings.selectedRoutingId = id;
    changed();
    // Переподключаемся, только если это что-то меняет: профиль другой и он действует.
    if (isConnected && !same && routingApplies) unawaited(reconnect());
  }

  Future<void> setMode(ConnectionMode mode) async {
    settings.mode = mode;
    changed();
    if (isConnected) await reconnect();
  }

  /// Смена ядра TUN с главной: как и смена режима, сразу переподключает, если TUN сейчас работает.
  Future<void> setTunCore(TunCore core) async {
    if (settings.tunCore == core) return;
    settings.tunCore = core;
    changed();
    if (isConnected && usesTun) await reconnect();
  }

  Future<void> toggle({bool ignoreOtherVpn = false}) async {
    // Повторное нажатие, пока идёт подключение, отменяет его.
    if (status == ConnStatus.connecting) return cancelConnect();
    if (isBusy) return;
    isConnected ? await disconnect() : await connect(ignoreOtherVpn: ignoreOtherVpn);
  }

  Future<void> reconnect() async {
    // Kill Switch на время переподключения не снимается — иначе в паузе трафик пошёл бы напрямую.
    await disconnect(keepError: true, hold: true);
    await connect();
  }

  /// Kill Switch держит интернет закрытым, а VPN не подключён: ядро упало и не поднялось,
  /// или переподключение не удалось. Окно показывает это и предлагает открыть интернет.
  /// Kill Switch сейчас стоит (отметка на главной).
  bool get killSwitchOn => KillSwitch.active;

  bool get killSwitchHolding => KillSwitch.active && status == ConnStatus.disconnected;

  /// Включение и выключение Kill Switch в настройках действует сразу, без переподключения.
  Future<void> setKillSwitch(bool on) async {
    settings.killSwitch = on;
    changed();
    if (!on) {
      await KillSwitch.release();
    } else if (isConnected && usesTun) {
      try {
        await KillSwitch.engage();
      } catch (e) {
        settings.killSwitch = false;
        toast('$e', kind: ToastKind.error);
      }
    }
    changed();
  }

  /// Пользователь решил открыть интернет без VPN (кнопка на главной).
  Future<void> releaseKillSwitch() async {
    await KillSwitch.release();
    log.add('app', 'Интернет открыт без VPN');
    notifyListeners();
  }

  /// Правила по приложениям, с которыми поднят текущий TUN (null — TUN не запущен).
  String? _appliedAppRules;

  /// Правила по приложениям в окне отличаются от тех, что сейчас действуют: нужно переподключение.
  /// Считается сравнением, а не флажком «что-то трогали»: вернули всё как было или переподключились
  /// любым способом — и просьба применить исчезает сама.
  bool get appRulesPending => _appliedAppRules != null && _appliedAppRules != appRules.signature;

  /// Настройки текущего подключения: те же, что в [settings], но с реально занятыми портами
  /// (если порт из настроек держит другая программа, берётся свободный).
  AppSettings? _session;

  /// Свободен ли локальный порт (его никто не слушает).
  static Future<bool> _portFree(int port) async {
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await s.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Порт для подключения: из настроек, а если он занят — ближайший свободный.
  /// В режиме «Только порты» порты видит пользователь, поэтому там занятый порт — ошибка.
  Future<int> _pickPort(int preferred, Set<int> taken, String what) async {
    if (!taken.contains(preferred) && await _portFree(preferred)) return preferred;
    if (settings.mode == ConnectionMode.proxyOnly) {
      throw CoreException('Порт $preferred ($what) уже занят другой программой — например, другим VPN-клиентом. '
          'Закройте её или смените порт в Настройки → Дополнительно.');
    }
    for (var p = preferred + 1000; p < preferred + 1100; p++) {
      if (!taken.contains(p) && await _portFree(p)) {
        log.add('app', 'Порт $preferred ($what) занят другой программой, использую $p');
        return p;
      }
    }
    throw CoreException('Не нашлось свободного порта для $what');
  }

  /// Другие подключённые VPN, которые помешают (проверяется перед подключением).
  /// В режиме «Только порты» система не меняется — там мешать нечему.
  List<VpnConflict> findVpnConflicts() =>
      settings.mode == ConnectionMode.proxyOnly ? const [] : WinSys.vpnConflicts();

  /// Закрывает мешающие VPN по выбору пользователя.
  Future<void> closeVpnConflicts(List<VpnConflict> conflicts) async {
    log.add('app', 'Закрываю мешающие VPN: ${conflicts.map((c) => c.name).join(', ')}');
    await WinSys.closeVpnConflicts(conflicts);
  }

  /// Подключение попросили не из окна (значок в трее), а нужен вопрос пользователю —
  /// окно увидит этот флаг и само проведёт проверку с диалогом.
  bool connectRequested = false;

  void requestConnect() {
    connectRequested = true;
    notifyListeners();
  }

  /// Пользователь отменил подключение, пока оно шло (см. [cancelConnect]).
  bool _cancelConnect = false;

  /// Отмена идущего подключения. Ядра останавливаются сразу — ожидания в [connect] на этом
  /// заканчиваются, и он сам возвращает всё как было, без сообщения об ошибке.
  Future<void> cancelConnect() async {
    if (status != ConnStatus.connecting || _cancelConnect) return;
    _cancelConnect = true;
    log.add('app', 'Подключение отменено');
    // Автовыбор сервера мог ещё мерить задержку — останавливаем и его.
    await cancelPing();
    await _singbox.stop();
    await _xray.stop();
  }

  /// Между шагами подключения: если его отменили, дальше не идём.
  void _checkCancel() {
    if (_cancelConnect) throw CoreException('Подключение отменено');
  }

  /// [ignoreOtherVpn] — пользователь уже предупреждён о другом VPN и решил подключаться всё равно.
  Future<void> connect({bool ignoreOtherVpn = false}) async {
    if (isBusy || isConnected) return;
    // Kill Switch уже держит интернет закрытым (переподключение или сбой ядра): если подключиться
    // не выйдет, он так и останется закрытым.
    final held = KillSwitch.active;
    _cancelConnect = false;
    lastError = null;
    tunFailed = false;
    status = ConnStatus.connecting;
    notifyListeners();
    // Каждое подключение — отдельный отрезок журнала (раздел «Логи»).
    log.startSession(selectedServer?.name ?? 'Сервер не выбран', detail: xrayTun ? '${settings.mode.label} · Xray' : settings.mode.label);
    log.add('app', 'Подключение…');
    try {
      // С запущенным zapret не подключаемся вовсе: он правит пакеты, в том числе на пути к VPN-серверу.
      final zapret = WinSys.zapretRunning();
      if (zapret != null) {
        throw CoreException('Запущен $zapret — с ним VPN не подключается: он вмешивается в соединения, '
            'в том числе с VPN-сервером. Закройте $zapret и подключитесь снова.');
      }
      if (usesTun && !isAdmin) throw NeedAdminException();

      // Два VPN с TUN одновременно дерутся за маршруты — сеть ломается до перезагрузки.
      if (usesTun && !ignoreOtherVpn) {
        final other = WinSys.otherVpnAdapters();
        if (other.isNotEmpty) {
          throw CoreException('Включён другой VPN (${other.join(', ')}). Отключите его и подключитесь снова — '
              'два VPN одновременно мешают друг другу и ломают сеть.');
        }
      }

      if (settings.autoSelect && selectedServer != null) {
        final group = serversOf(selectedServer!.subscriptionId);
        await ping(group);
        final best = bestOf(group);
        if (best != null) settings.selectedServerId = best.id;
      }
      _checkCancel();
      final server = selectedServer;
      if (server == null) throw CoreException('Сначала добавьте и выберите сервер');

      final routing = selectedRouting;
      // У серверов с JSON-конфигом провайдера действуют его правила, профиль не применяется.
      final provider = XrayConfig.providerConfig(server);
      if (provider != null) {
        if (XrayConfig.configNeedsGeoFiles(provider)) await _ensureGeoFiles(routing, force: true);
      } else {
        await _ensureGeoFiles(routing);
      }

      _checkCancel();
      // Порты проверяются ДО запуска: иначе «порт открыт» мог бы означать чужую программу
      // (например, Happ на тех же 10808/10809), а не наш Xray.
      final session = AppSettings.fromJson(settings.toJson());
      final taken = <int>{};
      session.socksPort = await _pickPort(settings.socksPort, taken, 'SOCKS');
      taken.add(session.socksPort);
      session.httpPort = await _pickPort(settings.httpPort, taken, 'HTTP');
      taken.add(session.httpPort);
      session.apiPort = await _pickPort(settings.apiPort, taken, 'статистика');
      _session = session;

      final config = XrayConfig.build(server: server, routing: routing, settings: session);
      final xrayTun = this.xrayTun;
      if (xrayTun) {
        if (!File(AppPaths.wintunDll).existsSync()) {
          throw CoreException('Не найден файл wintun.dll рядом с ядром Xray — без него Xray не может создать адаптер. '
              'Переустановите SkipIt или выберите ядро TUN «sing-box».');
        }
        final domestic = Uri.tryParse(routing.domesticDnsAddress);
        XrayConfig.addTun(config, settings: session, apps: appRules, directDomains: [
          if (domestic != null && domestic.scheme == 'https' && InternetAddress.tryParse(domestic.host) == null)
            domestic.host,
        ]);
        _appliedAppRules = appRules.signature;
        await _tunCleanup;
      } else if (usesTun) {
        XrayConfig.addProxyAppRules(config, settings: session, apps: appRules);
      }
      // Вход «мимо VPN-сервера» для обновления подписок: пропускает только адреса их серверов.
      taken.add(session.apiPort);
      var directPort = session.apiPort + 1;
      while (taken.contains(directPort) || !await _portFree(directPort)) {
        if (++directPort > session.apiPort + 200) throw CoreException('Не нашлось свободного порта для обновления подписок');
      }
      XrayConfig.addDirectInbound(config, port: directPort, settings: session, hosts: [
        for (final s in subscriptions)
          if (directSubscriptionHost(s.url) != null) directSubscriptionHost(s.url)!,
      ]);
      _directPort = directPort;
      // Вход проверки связи: через него программа сама убеждается, что VPN-сервер отвечает.
      taken.add(directPort);
      var checkPort = directPort + 1;
      while (taken.contains(checkPort) || !await _portFree(checkPort)) {
        if (++checkPort > directPort + 200) throw CoreException('Не нашлось свободного порта для проверки связи');
      }
      taken.add(checkPort);
      XrayConfig.addCheckInbound(config, port: checkPort);
      // С Kill Switch имя VPN-сервера ядро узнаёт само: запрос Windows к DNS обычной сети был бы
      // заблокирован, и подключение «висело» бы секунд двенадцать.
      if (usesTun && settings.killSwitch) XrayConfig.resolveServersInside(config, settings: session);
      _routes
        ..clear()
        ..addEntries([
          for (final o in (config['outbounds'] as List).whereType<Map>())
            if (o['tag'] is String)
              MapEntry(
                  o['tag'] as String,
                  switch (o['protocol']) {
                    'freedom' => ConnRoute.direct,
                    'blackhole' => ConnRoute.block,
                    'dns' => ConnRoute.dns,
                    _ => ConnRoute.proxy,
                  }),
        ]);
      final statsSkip = XrayConfig.chainedOutbounds(config);
      int? tunStatsPort;
      var tunStatsSecret = '';
      // Конфиг с адресами и ключами серверов ядро получает напрямую, а не из файла на диске.
      final configText = const JsonEncoder.withIndent('  ').convert(config);
      await _debugCopy(AppPaths.configFile, configText);
      _checkCancel();
      // Kill Switch ставится до запуска ядер: с этой минуты мимо VPN ничего не выходит.
      if (usesTun && settings.killSwitch) {
        await KillSwitch.engage();
      } else {
        await KillSwitch.release();
      }
      await _xray.start(AppPaths.xrayExe, ['run', '-c', 'stdin:'],
          env: {'XRAY_LOCATION_ASSET': AppPaths.geoDir.path}, input: configText);
      settings.lastXrayPid = _xray.pid;
      await saveNow();

      if (!await waitForPort(session.socksPort, alive: () => _xray.running)) {
        _checkCancel();
        throw CoreException('Xray не запустился:\n${log.tail(8, source: 'xray')}');
      }
      // Ядро могло открыть порт и тут же упасть на следующей ошибке конфига — проверяем, что оно живо.
      await Future.delayed(const Duration(milliseconds: 250));
      _checkCancel();
      if (!_xray.running) throw CoreException('Xray завершился сразу после запуска:\n${log.tail(8, source: 'xray')}');

      if (xrayTun) {
        // Адаптер поднимает сам Xray: ждём, пока трафик пойдёт через него.
        final deadline = DateTime.now().add(Duration(seconds: ignoreOtherVpn ? 5 : 12));
        while (_xray.running && !WinSys.ownTunActive() && DateTime.now().isBefore(deadline)) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
        _checkCancel();
        if (!_xray.running || (!ignoreOtherVpn && !WinSys.ownTunActive())) {
          tunFailed = true;
          throw CoreException(_tunFailure('xray'));
        }
      } else if (usesTun) {
        final domains = <String>[
          if (InternetAddress.tryParse(server.address) == null && server.address.isNotEmpty) server.address,
        ];
        _appliedAppRules = appRules.signature;
        await _tunCleanup;
        // Порт списка соединений sing-box — для счётчика трафика, который он выпускает напрямую сам.
        var port = checkPort + 1;
        while (taken.contains(port) || !await _portFree(port)) {
          if (++port > checkPort + 200) throw CoreException('Не нашлось свободного порта для счётчика трафика');
        }
        final random = Random.secure();
        tunStatsPort = port;
        tunStatsSecret = [for (var i = 0; i < 16; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
        final tun = SingboxConfig.build(
            settings: session,
            routing: routing,
            apps: appRules,
            serverDomains: domains,
            statsPort: tunStatsPort,
            statsSecret: tunStatsSecret);
        final tunText = const JsonEncoder.withIndent('  ').convert(tun);
        await _debugCopy(AppPaths.tunConfigFile, tunText);
        final logStart = log.lines.length;
        _checkCancel();
        await _singbox.start(AppPaths.singboxExe, ['run', '-c', 'stdin'], input: tunText);
        settings.lastSingboxPid = _singbox.pid;
        // «Подключено» сообщаем, только когда трафик действительно пошёл через наш адаптер. Обычно это
        // доли секунды. Если Windows не может включить адаптер, sing-box через 10 секунд пишет об этом
        // предупреждение — дальше не ждём и сразу сообщаем об ошибке, а не держим человека минуту.
        // (Если пользователь решил подключаться при чужом VPN, маршрут может остаться за тем VPN —
        // тогда достаточно, что sing-box жив.)
        final deadline = DateTime.now().add(Duration(seconds: ignoreOtherVpn ? 5 : 12));
        bool stuck() => log.lines.skip(logStart).any((l) => l.source == 'sing-box' && _adapterTrouble(l.text));
        while (_singbox.running && !WinSys.ownTunActive() && !stuck() && DateTime.now().isBefore(deadline)) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
        _checkCancel();
        if (!_singbox.running || stuck() || (!ignoreOtherVpn && !WinSys.ownTunActive())) {
          tunFailed = true;
          throw CoreException(_tunFailure('sing-box'));
        }
      }
      _checkCancel();
      if (settings.mode == ConnectionMode.systemProxy || settings.mode == ConnectionMode.mixed) {
        if (!settings.systemProxyActive) settings.previousProxy = await WinSys.readProxy();
        await WinSys.setProxy('127.0.0.1:${session.httpPort}');
        settings.systemProxyActive = true;
      }
      await saveNow();

      status = ConnStatus.connected;
      connectedAt = DateTime.now();
      log.add('app', 'Подключено');
      WinSys.flushDnsCache();
      stats.reset();
      _statsTimer?.cancel();
      _checkPort = checkPort;
      _startLinkCheck();
      _pollStats = ({bool xray = true}) => stats.poll(session.apiPort, _routes,
          skip: statsSkip, tunPort: tunStatsPort, tunSecret: tunStatsSecret, xray: xray);
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
        // Окно спрятано — цифры никто не видит: ядро Xray не опрашивается, главная не перерисовывается.
        final visible = windowVisible;
        if (!visible && tunStatsPort == null) return;
        await _pollStats?.call(xray: visible);
        if (visible) notifyListeners();
      });
      notifyListeners();
    } catch (e) {
      // Отмена пользователем — не ошибка: просто возвращаем всё как было.
      final cancelled = _cancelConnect;
      if (cancelled) {
        tunFailed = false;
      } else {
        lastError = e.toString();
        log.add('app', 'Ошибка подключения: $e');
      }
      await _teardown();
      // Подключались с открытым интернетом — возвращаем как было. Если же Kill Switch уже держал
      // его закрытым, оставляем закрытым: решение открыть — за пользователем.
      if (!held) await KillSwitch.release();
      if (KillSwitch.active) log.add('app', 'Kill Switch держит интернет закрытым');
      log.endSession();
      status = ConnStatus.disconnected;
      notifyListeners();
      if (e is NeedAdminException && !cancelled) rethrow;
    }
  }

  /// sing-box сообщает, что Windows не отдаёт ему сетевой адаптер.
  static bool _adapterTrouble(String line) {
    final l = line.toLowerCase();
    return l.contains('configure tun interface') || l.contains('open interface take too much time');
  }

  /// Xray начал создавать адаптер и на этом застрял: ядро так и не сообщило о запуске.
  bool _xrayAdapterStuck() {
    final text = log.lines.where((l) => l.source == 'xray').map((l) => l.text).join('\n');
    final creating = text.lastIndexOf('Creating adapter');
    return creating >= 0 && !text.substring(creating).contains('started');
  }

  /// Последняя ошибка — не поднялся адаптер TUN: на главной предлагается режим «Прокси».
  bool tunFailed = false;

  /// Скрыть сообщение об ошибке на главной (крестик или истёкшее время показа).
  void clearError() {
    if (lastError == null) return;
    lastError = null;
    tunFailed = false;
    notifyListeners();
  }

  /// Понятное объяснение, почему не поднялся TUN, по последним строкам ядра, которое его поднимает.
  String _tunFailure(String core) {
    final tail = log.tail(8, source: core);
    final lower = tail.toLowerCase();
    if (_adapterTrouble(lower) || tail.trim().isEmpty || (core == 'xray' && _xrayAdapterStuck())) {
      return 'Windows не смогла включить сетевой адаптер VPN — это сбой на стороне Windows, не настроек. '
          'Обычно помогает перезагрузка компьютера. Прямо сейчас можно подключиться в режиме «Прокси»: '
          'он работает без адаптера.';
    }
    if (lower.contains('access is denied')) {
      return 'Windows не разрешила создать сетевой адаптер VPN — запустите SkipIt от имени администратора.';
    }
    return 'Не удалось поднять TUN:\n$tail';
  }

  /// [hold] — не снимать Kill Switch: отключение не по воле пользователя (сбой ядра, переподключение).
  Future<void> disconnect({bool keepError = false, bool hold = false}) async {
    if (status == ConnStatus.disconnected) return;
    // Подключение ещё идёт — отменяем его; всё уберёт сам connect().
    if (status == ConnStatus.connecting) return cancelConnect();
    status = ConnStatus.disconnecting;
    notifyListeners();
    // Последний замер, пока ядра ещё работают: итог сеанса остаётся в журнале.
    _statsTimer?.cancel();
    if (_xray.running) await _pollStats?.call();
    final summary = trafficSummary(stats);
    await _teardown();
    if (!hold) await KillSwitch.release();
    await KillSwitch.verifyReleased();
    WinSys.flushDnsCache();
    log.add('app', 'Отключено');
    if (summary != null) log.add('app', summary);
    if (KillSwitch.active) log.add('app', 'Kill Switch держит интернет закрытым');
    log.endSession();
    if (!keepError) lastError = null;
    status = ConnStatus.disconnected;
    connectedAt = null;
    notifyListeners();
  }

  /// Строка журнала с трафиком за подключение; null — трафика не было.
  static String? trafficSummary(TrafficStats s) {
    if (s.up + s.down == 0) return null;
    String part(int down, int up) => '${formatBytes(down)} получено, ${formatBytes(up)} отправлено';
    return 'Трафик за подключение — через VPN: ${part(s.vpnDown, s.vpnUp)}; '
        'напрямую: ${part(s.directDown, s.directUp)}';
  }

  Future<void> _teardown() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    _pollStats = null;
    _stopLinkCheck();
    if (settings.systemProxyActive) {
      await WinSys.restoreProxy(settings.previousProxy);
      settings.systemProxyActive = false;
    }
    await _singbox.stop();
    await _xray.stop();
    _session = null;
    _directPort = null;
    _appliedAppRules = null;
    settings.lastXrayPid = settings.lastSingboxPid = null;
    await saveNow();
  }

  /// Ядро завершилось само. Сначала сразу отключаемся — иначе TUN продолжает перехватывать трафик
  /// и отправлять его в пустоту, и у пользователя пропадает интернет. Переподключаемся не больше
  /// одного раза за 5 минут и только если ядро успело нормально поработать: частые падения
  /// обычно значат, что его закрывает другая программа, и повторы лишь дёргают сеть.
  void _onCoreCrash(int code) {
    if (status != ConnStatus.connected) return;
    final now = DateTime.now();
    final uptime = connectedAt == null ? Duration.zero : now.difference(connectedAt!);
    _crashTimes
      ..add(now)
      ..removeWhere((t) => now.difference(t) > const Duration(minutes: 5));
    final retry = settings.autoReconnect && _crashTimes.length <= 1 && uptime > const Duration(seconds: 30);
    log.add('app', 'Ядро завершилось (код $code) через ${uptime.inSeconds} с работы${retry ? ', переподключаюсь' : ''}');
    unawaited(() async {
      // Включённый Kill Switch остаётся стоять: пока VPN не вернулся, трафик напрямую не идёт.
      await disconnect(keepError: true, hold: true);
      if (retry) {
        await Future.delayed(const Duration(seconds: 3));
        await connect();
      } else {
        lastError = 'Ядро VPN неожиданно закрылось, подключение остановлено. Если запущен другой VPN-клиент '
            '(например, Happ) — закройте его: он может закрывать ядро SkipIt.';
        notifyListeners();
      }
    }());
  }

  Future<void> _ensureGeoFiles(RoutingProfile routing, {bool force = false}) async {
    if (!force && !XrayConfig.needsGeoFiles(routing)) return;
    if (File(AppPaths.geoipFile).existsSync() && File(AppPaths.geositeFile).existsSync()) return;
    await updateGeoFiles(routing);
  }

  bool updatingGeo = false;

  Future<void> updateGeoFiles([RoutingProfile? routing]) async {
    final r = routing ?? selectedRouting;
    updatingGeo = true;
    notifyListeners();
    try {
      final proxy = isConnected ? (_session ?? settings).httpPort : null;
      log.add('app', 'Загрузка geoip/geosite…');
      await Net.download(r.geoipUrl, AppPaths.geoipFile, proxyPort: proxy);
      await Net.download(r.geositeUrl, AppPaths.geositeFile, proxyPort: proxy);
      log.add('app', 'Геофайлы обновлены');
    } finally {
      updatingGeo = false;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Версии и обновления
  // ---------------------------------------------------------------------------

  /// Версии вложенных ядер: CoreSpec.name → версия (null — ядро не найдено). Только для показа:
  /// ядра обновляются вместе с программой, сама она их не скачивает.
  final coreVersions = <String, String?>{};

  /// Найденная новая версия SkipIt (null — обновлений нет или ещё не проверяли).
  Release? appUpdate;
  bool checkingUpdates = false;
  DateTime? lastUpdateCheck;

  Future<void> detectCoreVersions() async {
    for (final core in CoreSpec.all) {
      coreVersions[core.name] = await Updates.installedVersion(core);
    }
    notifyListeners();
  }

  int? get _updateProxy => isConnected ? (_session ?? settings).httpPort : null;

  /// [silent] — фоновая проверка при запуске: сообщает только о найденном обновлении.
  Future<void> checkUpdates({bool silent = false}) async {
    if (checkingUpdates) return;
    // Тестовая сборка не обновляется из релизов: установщик заменил бы установленную программу.
    if (AppPaths.isDev || appRepo.isEmpty) {
      if (!silent) toast('Тестовая сборка не обновляется из релизов');
      return;
    }
    checkingUpdates = true;
    appUpdate = null;
    notifyListeners();
    try {
      final r = await Updates.latest(appRepo,
          proxyPort: _updateProxy, prerelease: settings.updateChannel == UpdateChannel.beta);
      // Релиз без установщика — значит, GitHub его ещё собирает: не предлагаем, пока не будет готов.
      if (Updates.compare(r.version, appVersion) > 0 && await Updates.hasInstaller(r, proxyPort: _updateProxy)) {
        appUpdate = r;
      }
      lastUpdateCheck = DateTime.now();
      if (appUpdate != null) {
        toast('Доступна новая версия SkipIt: ${appUpdate!.version}');
      } else if (!silent) {
        toast('У вас последняя версия');
      }
    } catch (e) {
      log.add('update', 'Проверка обновлений: $e');
      if (!silent) {
        toast(e is UpdateLimitedException ? '$e' : 'Не удалось проверить обновления: ${describeNetError(e)}');
      }
    } finally {
      checkingUpdates = false;
      notifyListeners();
    }
  }

  bool downloadingAppUpdate = false;

  /// Сколько установщика уже скачано, от 0 до 1; null — размер неизвестен или скачивание не идёт.
  double? updateProgress;

  /// Подпись хода скачивания для окна: «Скачиваю обновление… 43 %».
  String get updateProgressLabel => updateProgress == null
      ? 'Скачиваю обновление…'
      : 'Скачиваю обновление… ${(updateProgress! * 100).round()} %';

  /// То же коротко — для строки версии в боковом меню: длинная подпись не помещается в её рамку.
  String get updateProgressShort =>
      updateProgress == null ? 'Скачиваю…' : 'Скачиваю… ${(updateProgress! * 100).round()} %';

  /// Скачивает установщик новой версии SkipIt из релиза на GitHub и сверяет его контрольную сумму.
  Future<String?> downloadAppUpdate() async {
    final release = appUpdate;
    if (release == null || downloadingAppUpdate) return null;
    downloadingAppUpdate = true;
    updateProgress = null;
    notifyListeners();
    try {
      // Программа обычно работает с правами администратора и запускает установщик с ними же. Поэтому
      // качаем его не во временную папку пользователя (там файл успела бы подменить любая программа),
      // а в папку рядом с программой: в Program Files писать могут только администраторы.
      var dir = Directory.systemTemp;
      if (isAdmin) {
        try {
          final own = Directory('${File(AppPaths.exe).parent.path}\\update');
          await own.create(recursive: true);
          dir = own;
        } catch (_) {}
      }
      final path = '${dir.path}\\${release.installerName}';
      await Net.download(release.installerUrl, path, proxyPort: _updateProxy, onProgress: (received, total) {
        if (total <= 0) return;
        final p = (received / total).clamp(0.0, 1.0);
        // Окно перерисовывается на каждый процент, а не на каждый полученный кусок файла.
        if (updateProgress != null && (p * 100).floor() == (updateProgress! * 100).floor()) return;
        updateProgress = p;
        notifyListeners();
      });
      // Запускаем только то, что совпало с контрольной суммой из релиза.
      final expected = await Updates.expectedSha256(release, proxyPort: _updateProxy);
      await Updates.verify(path, expected);
      log.add('update', 'Скачан установщик ${release.version}${expected != null ? ', контрольная сумма совпала' : ''}');
      return path;
    } finally {
      downloadingAppUpdate = false;
      updateProgress = null;
      notifyListeners();
    }
  }

  Future<void> setAutostart(bool v) async {
    await WinSys.setAutostart(v);
    autostart = v;
    notifyListeners();
  }

  @override
  void dispose() {
    _subsTimer?.cancel();
    _statsTimer?.cancel();
    _messages.close();
    super.dispose();
  }
}
