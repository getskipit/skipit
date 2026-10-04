import 'dart:convert';
import 'dart:io';

class AppPaths {
  static late Directory dataDir;
  static late Directory coreDir;
  static late Directory geoDir;

  /// Тестовая сборка разработчика: рядом с exe лежит файл-метка `dev-build` (его кладёт tools\dev.ps1).
  /// У такой копии всё своё — папка данных, автозапуск, положение окна, имя TUN-адаптера, —
  /// поэтому она не задевает SkipIt, установленный из релиза.
  static final bool isDev = File('${File(Platform.resolvedExecutable).parent.path}\\dev-build').existsSync();

  /// Имя программы в системе: папка данных, ключи реестра, TUN-адаптер.
  static String get appName => isDev ? 'SkipIt Dev' : 'SkipIt';

  static Future<void> init() async {
    final appData =
        Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    dataDir = Directory('$appData\\$appName');
    await dataDir.create(recursive: true);
    geoDir = Directory('${dataDir.path}\\geo');
    await geoDir.create(recursive: true);
    coreDir = _findCoreDir();
    if (isDev) {
      await _seedDevData(appData);
    } else {
      _removeOldConfigs();
    }
  }

  /// Конфиги ядер на диск больше не пишутся (их пишет только тестовая сборка), но от прежних версий
  /// могли остаться файлы с адресами серверов. Убираем их при запуске, не дожидаясь подключения.
  static void _removeOldConfigs() {
    for (final path in [configFile, tunConfigFile, testConfigFile]) {
      try {
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }
  }

  /// Первый запуск тестовой сборки: один раз копируем подписки и настройки из установленного SkipIt,
  /// чтобы не добавлять всё заново (и не занимать у провайдера ещё одно устройство новым HWID).
  /// Дальше данные живут отдельно; сами файлы установленной программы не меняются.
  static Future<void> _seedDevData(String appData) async {
    final target = File(stateFile);
    final source = File('$appData\\SkipIt\\state.json');
    if (target.existsSync() || !source.existsSync()) return;
    try {
      final j = jsonDecode(await source.readAsString()) as Map<String, dynamic>;
      // Состояние запущенного подключения не переносим: иначе тестовая копия при старте «вернула» бы
      // системный прокси, которым сейчас пользуется установленная программа.
      final settings = j['settings'];
      if (settings is Map<String, dynamic>) {
        settings
          ..['systemProxyActive'] = false
          ..remove('previousProxy')
          ..remove('lastXrayPid')
          ..remove('lastSingboxPid');
      }
      await target.writeAsString(jsonEncode(j), flush: true);
      for (final name in ['geoip.dat', 'geosite.dat']) {
        final geo = File('$appData\\SkipIt\\geo\\$name');
        if (geo.existsSync()) await geo.copy('${geoDir.path}\\$name');
      }
    } catch (_) {}
  }

  /// Ядра лежат в папке `core` рядом с exe (релиз) или в корне проекта (flutter run).
  static Directory _findCoreDir() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final candidates = [
      Directory('${exeDir.path}\\core'),
      Directory('${Directory.current.path}\\core'),
    ];
    for (final dir in candidates) {
      if (File('${dir.path}\\skipit-xray.exe').existsSync()) return dir;
    }
    return candidates.first;
  }

  static String get exe => Platform.resolvedExecutable;
  // У ядер свои имена: другие VPN-клиенты (например, Happ) закрывают чужие процессы xray.exe.
  static String get xrayExe => '${coreDir.path}\\skipit-xray.exe';
  static String get singboxExe => '${coreDir.path}\\skipit-sing-box.exe';

  /// Драйвер адаптера для Xray, когда он сам поднимает TUN (в sing-box драйвер встроен).
  static String get wintunDll => '${coreDir.path}\\wintun.dll';
  static String get configFile => '${dataDir.path}\\config.json';
  static String get tunConfigFile => '${dataDir.path}\\tun.json';
  static String get testConfigFile => '${dataDir.path}\\test.json';
  static String get stateFile => '${dataDir.path}\\state.json';
  /// Журнал: по файлу на каждое подключение, хранится 5 дней (см. LogBuffer).
  static Directory get logDir => Directory('${dataDir.path}\\logs');
  static String get geoipFile => '${geoDir.path}\\geoip.dat';
  static String get geositeFile => '${geoDir.path}\\geosite.dat';
}
