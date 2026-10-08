import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'paths.dart';

const _internetSettingsKey =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
String get _runValue => AppPaths.appName;
const urlScheme = 'skipit';

/// Состояние системного прокси до подключения — чтобы вернуть как было.
class SystemProxyState {
  SystemProxyState({required this.enabled, this.server = '', this.override = ''});

  final bool enabled;
  final String server;
  final String override;

  Map<String, dynamic> toJson() =>
      {'enabled': enabled, 'server': server, 'override': override};

  factory SystemProxyState.fromJson(Map<String, dynamic> j) => SystemProxyState(
        enabled: j['enabled'] == true,
        server: j['server'] as String? ?? '',
        override: j['override'] as String? ?? '',
      );
}

/// Другой VPN, который сейчас подключён и помешает SkipIt.
class VpnConflict {
  VpnConflict(this.name);

  /// Название для пользователя: «Happ», «SkipIt (другая копия)», имя адаптера.
  final String name;

  /// Процессы, которые нужно закрыть. Пусто — закрыть сами не можем (найден только сетевой адаптер).
  final pids = <int>[];

  /// Пути этих процессов на момент проверки (номер процесса → файл).
  final paths = <int, String>{};

  /// Вторая копия SkipIt: её сначала просим выйти по-хорошему, а не «убиваем».
  bool isSkipIt = false;

  bool get canClose => pids.isNotEmpty;
}

class WinSys {
  // ---------- права ----------

  static bool isAdmin() {
    try {
      final shell32 = DynamicLibrary.open('shell32.dll');
      final fn = shell32.lookupFunction<Int32 Function(), int Function()>('IsUserAnAdmin');
      return fn() != 0;
    } catch (_) {
      return false;
    }
  }

  /// Перезапуск приложения с UAC. true — пользователь согласился.
  static Future<bool> relaunchAsAdmin(List<String> extraArgs) async {
    // Каждый аргумент — в двойных кавычках: Start-Process склеивает список пробелами, и без кавычек
    // аргумент с пробелом (например, ссылка) распался бы на несколько, в том числе на ключи.
    String quote(String a) => "'\"${a.replaceAll('"', '').replaceAll("'", "''")}\"'";
    final args = ['--elevated', ...extraArgs].map(quote).join(',');
    final script =
        "Start-Process -FilePath '${AppPaths.exe.replaceAll("'", "''")}' -ArgumentList $args -Verb RunAs";
    final r = await Process.run(AppPaths.powershell, ['-NoProfile', '-NonInteractive', '-Command', script]);
    return r.exitCode == 0;
  }

  // ---------- системный прокси ----------

  static Future<String?> _regQuery(String key, String value) async {
    final r = await Process.run(AppPaths.system('reg'), ['query', key, '/v', value]);
    if (r.exitCode != 0) return null;
    for (final line in (r.stdout as String).split(RegExp(r'\r?\n'))) {
      final m = RegExp('^\\s*${RegExp.escape(value)}\\s+REG_\\w+\\s*(.*)\$').firstMatch(line);
      if (m != null) return m.group(1)!.trim();
    }
    return null;
  }

  static Future<void> _regSet(String key, String value, String type, String data) =>
      Process.run(AppPaths.system('reg'), ['add', key, '/v', value, '/t', type, '/d', data, '/f']);

  static Future<void> _regDelete(String key, String value) =>
      Process.run(AppPaths.system('reg'), ['delete', key, '/v', value, '/f']);

  static Future<SystemProxyState> readProxy() async {
    final enable = await _regQuery(_internetSettingsKey, 'ProxyEnable');
    return SystemProxyState(
      enabled: enable != null && enable != '0x0',
      server: await _regQuery(_internetSettingsKey, 'ProxyServer') ?? '',
      override: await _regQuery(_internetSettingsKey, 'ProxyOverride') ?? '',
    );
  }

  static Future<void> setProxy(String server) async {
    await _regSet(_internetSettingsKey, 'ProxyServer', 'REG_SZ', server);
    await _regSet(_internetSettingsKey, 'ProxyOverride', 'REG_SZ',
        'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.2*;172.30.*;172.31.*;192.168.*;<local>');
    await _regSet(_internetSettingsKey, 'ProxyEnable', 'REG_DWORD', '1');
    _refreshInternetSettings();
  }

  static Future<void> restoreProxy(SystemProxyState? prev) async {
    if (prev == null || !prev.enabled) {
      await _regSet(_internetSettingsKey, 'ProxyEnable', 'REG_DWORD', '0');
    } else {
      await _regSet(_internetSettingsKey, 'ProxyEnable', 'REG_DWORD', '1');
    }
    if (prev != null && prev.server.isNotEmpty) {
      await _regSet(_internetSettingsKey, 'ProxyServer', 'REG_SZ', prev.server);
    }
    if (prev != null && prev.override.isNotEmpty) {
      await _regSet(_internetSettingsKey, 'ProxyOverride', 'REG_SZ', prev.override);
    }
    _refreshInternetSettings();
  }

  /// InternetSetOption(SETTINGS_CHANGED / REFRESH), чтобы браузеры сразу подхватили прокси.
  static void _refreshInternetSettings() {
    try {
      final wininet = DynamicLibrary.open('wininet.dll');
      final fn = wininet.lookupFunction<
          Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Uint32),
          int Function(Pointer<Void>, int, Pointer<Void>, int)>('InternetSetOptionW');
      fn(nullptr, 39, nullptr, 0);
      fn(nullptr, 37, nullptr, 0);
    } catch (_) {}
  }

  // ---------- автозапуск и ссылки ----------

  static Future<bool> isAutostartEnabled() async => await _regQuery(_runKey, _runValue) != null;

  static Future<void> setAutostart(bool enabled) async {
    if (enabled) {
      await _regSet(_runKey, _runValue, 'REG_SZ', '"${AppPaths.exe}" --autostart');
    } else {
      await _regDelete(_runKey, _runValue);
    }
  }

  /// Регистрирует `skipit://` — ссылки вида skipit://add/<url подписки> откроются в приложении.
  static Future<void> registerUrlScheme() async {
    // Тестовая сборка ссылки на себя не переключает — они остаются за установленной программой.
    if (AppPaths.isDev) return;
    final base = 'HKCU\\Software\\Classes\\$urlScheme';
    await _regSet(base, '', 'REG_SZ', 'URL:SkipIt');
    await _regSet(base, 'URL Protocol', 'REG_SZ', '');
    await _regSet('$base\\shell\\open\\command', '', 'REG_SZ', '"${AppPaths.exe}" "%1"');
  }

  // ---------- диалоги и процессы ----------

  static Future<String?> _powershell(String script) async {
    final r = await Process.run(
      AppPaths.powershell,
      ['-NoProfile', '-STA', '-Command', '[Console]::OutputEncoding=[Text.Encoding]::UTF8; $script'],
      stdoutEncoding: utf8,
    );
    final out = (r.stdout as String).trim();
    return r.exitCode == 0 && out.isNotEmpty ? out : null;
  }

  static Future<String?> pickFile({String filter = 'Все файлы (*.*)|*.*'}) => _powershell(
        'Add-Type -AssemblyName System.Windows.Forms; '
        '\$d = New-Object System.Windows.Forms.OpenFileDialog; '
        "\$d.Filter = '$filter'; "
        "if (\$d.ShowDialog() -eq 'OK') { \$d.FileName }",
      );

  static Future<String?> pickFolder() => _powershell(
        'Add-Type -AssemblyName System.Windows.Forms; '
        '\$d = New-Object System.Windows.Forms.FolderBrowserDialog; '
        "if (\$d.ShowDialog() -eq 'OK') { \$d.SelectedPath }",
      );

  /// Запущенные программы (имя + путь) для выбора в правилах приложений.
  /// Напрямую через WinAPI (EnumProcesses + QueryFullProcessImageName) — мгновенно, без запуска PowerShell.
  /// Системные процессы из папки Windows отфильтрованы: для правил VPN они не нужны.
  static Future<List<({String name, String path})>> runningApps() async {
    final windowsDir = '${(Platform.environment['WINDIR'] ?? r'C:\Windows').toLowerCase()}\\';
    final ownDir = File(AppPaths.exe).parent.path.toLowerCase();
    final byPath = <String, String>{};
    for (final p in _processes()) {
      final lower = p.path.toLowerCase();
      if (!lower.startsWith(windowsDir) && !lower.startsWith(ownDir)) byPath.putIfAbsent(lower, () => p.path);
    }
    final apps = [
      for (final path in byPath.values)
        (name: path.split('\\').last.replaceAll(RegExp(r'\.exe$', caseSensitive: false), ''), path: path),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return apps;
  }

  /// PID процессов, запущенных из папки [dir] (например, зависшие ядра из core).
  static List<int> processesUnder(String dir) {
    final prefix = '${dir.toLowerCase()}\\';
    return [
      for (final p in _processes())
        if (p.path.toLowerCase().startsWith(prefix)) p.pid,
    ];
  }

  /// Все процессы, к которым есть доступ: PID и полный путь к exe.
  static List<({int pid, String path})> _processes() {
    final k32 = DynamicLibrary.open('kernel32.dll');
    final getHeap = k32.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('GetProcessHeap');
    final heapAlloc = k32.lookupFunction<Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
        Pointer<Void> Function(Pointer<Void>, int, int)>('HeapAlloc');
    final heapFree = k32.lookupFunction<Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Void>)>('HeapFree');
    final enumProcesses = k32.lookupFunction<Int32 Function(Pointer<Uint32>, Uint32, Pointer<Uint32>),
        int Function(Pointer<Uint32>, int, Pointer<Uint32>)>('K32EnumProcesses');
    final openProcess = k32.lookupFunction<Pointer<Void> Function(Uint32, Int32, Uint32),
        Pointer<Void> Function(int, int, int)>('OpenProcess');
    final queryImageName = k32.lookupFunction<Int32 Function(Pointer<Void>, Uint32, Pointer<Uint16>, Pointer<Uint32>),
        int Function(Pointer<Void>, int, Pointer<Uint16>, Pointer<Uint32>)>('QueryFullProcessImageNameW');
    final closeHandle = k32.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('CloseHandle');

    const heapZeroMemory = 0x8;
    const processQueryLimitedInformation = 0x1000;
    const maxPids = 8192;
    const bufChars = 1024;
    final heap = getHeap();
    final pids = heapAlloc(heap, heapZeroMemory, maxPids * 4).cast<Uint32>();
    final needed = heapAlloc(heap, heapZeroMemory, 4).cast<Uint32>();
    final buf = heapAlloc(heap, heapZeroMemory, bufChars * 2).cast<Uint16>();
    final size = heapAlloc(heap, heapZeroMemory, 4).cast<Uint32>();

    final result = <({int pid, String path})>[];
    try {
      if (enumProcesses(pids, maxPids * 4, needed) == 0) return result;
      for (final pid in pids.asTypedList(needed.value ~/ 4)) {
        if (pid == 0) continue;
        final h = openProcess(processQueryLimitedInformation, 0, pid);
        if (h.address == 0) continue;
        size.value = bufChars;
        if (queryImageName(h, 0, buf, size) != 0) {
          result.add((pid: pid, path: String.fromCharCodes(buf.asTypedList(size.value))));
        }
        closeHandle(h);
      }
    } finally {
      for (final p in [pids.cast<Void>(), needed.cast<Void>(), buf.cast<Void>(), size.cast<Void>()]) {
        heapFree(heap, 0, p);
      }
    }
    return result;
  }

  /// Имена exe всех процессов (строчными буквами). В отличие от [_processes], видит и те, чей путь
  /// узнать нельзя: службы и программы, запущенные с правами выше наших.
  static List<String> processNames() {
    final k32 = DynamicLibrary.open('kernel32.dll');
    final getHeap = k32.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('GetProcessHeap');
    final heapAlloc = k32.lookupFunction<Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
        Pointer<Void> Function(Pointer<Void>, int, int)>('HeapAlloc');
    final heapFree = k32.lookupFunction<Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Void>)>('HeapFree');
    final snapshot = k32.lookupFunction<Pointer<Void> Function(Uint32, Uint32), Pointer<Void> Function(int, int)>(
        'CreateToolhelp32Snapshot');
    final first = k32.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>)>('Process32FirstW');
    final next = k32.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>)>('Process32NextW');
    final closeHandle = k32.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('CloseHandle');

    // PROCESSENTRY32W (x64): размер 568 байт, имя файла — 260 символов со смещения 44.
    const entrySize = 568, nameOffset = 44, nameChars = 260;
    const snapProcess = 0x2;
    final names = <String>[];
    final snap = snapshot(snapProcess, 0);
    if (snap.address == 0 || snap.address == -1) return names;
    final heap = getHeap();
    final entry = heapAlloc(heap, 0x8, entrySize);
    try {
      entry.cast<Uint32>().value = entrySize;
      var ok = first(snap, entry);
      while (ok != 0) {
        final chars = Pointer<Uint16>.fromAddress(entry.address + nameOffset).asTypedList(nameChars);
        final end = chars.indexOf(0);
        names.add(String.fromCharCodes(chars, 0, end < 0 ? nameChars : end).toLowerCase());
        ok = next(snap, entry);
      }
    } finally {
      heapFree(heap, 0, entry);
      closeHandle(snap);
    }
    return names;
  }

  /// Шифрует данные ключом учётной записи Windows (DPAPI — им же браузеры защищают сохранённые пароли).
  /// Расшифровать их может только тот же пользователь на том же компьютере. null — не получилось.
  static Uint8List? protect(Uint8List data) => _dpapi(data, 'CryptProtectData');

  /// Расшифровывает то, что зашифровал [protect]. null — данные чужие (другой пользователь или
  /// компьютер) или повреждены.
  static Uint8List? unprotect(Uint8List data) => _dpapi(data, 'CryptUnprotectData');

  static Uint8List? _dpapi(Uint8List data, String function) {
    try {
      final k32 = DynamicLibrary.open('kernel32.dll');
      final getHeap = k32.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('GetProcessHeap');
      final heapAlloc = k32.lookupFunction<Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
          Pointer<Void> Function(Pointer<Void>, int, int)>('HeapAlloc');
      final heapFree = k32.lookupFunction<Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
          int Function(Pointer<Void>, int, Pointer<Void>)>('HeapFree');
      final localFree =
          k32.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('LocalFree');
      // У обеих функций одинаковый набор параметров: вход, описание, доп. ключ, резерв, окно, флаги, выход.
      final crypt = DynamicLibrary.open('crypt32.dll').lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<Void>),
          int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>, int,
              Pointer<Void>)>(function);

      // DATA_BLOB (x64): длина — 4 байта, указатель на данные — со смещения 8.
      const blobSize = 16, uiForbidden = 0x1;
      final heap = getHeap();
      final input = heapAlloc(heap, 0x8, data.isEmpty ? 1 : data.length);
      final inBlob = heapAlloc(heap, 0x8, blobSize);
      final outBlob = heapAlloc(heap, 0x8, blobSize);
      try {
        input.cast<Uint8>().asTypedList(data.length).setAll(0, data);
        inBlob.cast<Uint32>().value = data.length;
        Pointer<IntPtr>.fromAddress(inBlob.address + 8).value = input.address;
        if (crypt(inBlob, nullptr, nullptr, nullptr, nullptr, uiForbidden, outBlob) == 0) return null;
        final length = outBlob.cast<Uint32>().value;
        final out = Pointer<Uint8>.fromAddress(Pointer<IntPtr>.fromAddress(outBlob.address + 8).value);
        final result = Uint8List.fromList(out.asTypedList(length));
        localFree(out.cast());
        return result;
      } finally {
        for (final p in [input, inBlob, outBlob]) {
          heapFree(heap, 0, p);
        }
      }
    } catch (_) {
      return null;
    }
  }

  /// Очищает кэш DNS Windows (то же, что `ipconfig /flushdns`). В кэше остаются ответы от прежнего
  /// состояния сети: до подключения — от обычного DNS, после — от DNS VPN. Со старыми ответами
  /// программы ходили бы на серверы, выбранные для другой сети.
  static bool flushDnsCache() {
    try {
      final flush = DynamicLibrary.open('dnsapi.dll')
          .lookupFunction<Int32 Function(), int Function()>('DnsFlushResolverCache');
      return flush() != 0;
    } catch (_) {
      return false;
    }
  }

  /// Запущенный zapret (обход блокировок, который вмешивается в пакеты): его название или null.
  /// С ним VPN не подключается: zapret правит и соединение с VPN-сервером.
  static String? zapretRunning() {
    try {
      return zapretIn(processNames());
    } catch (_) {
      return null;
    }
  }

  /// Рабочие процессы zapret: winws.exe — zapret, winws2.exe — zapret 2.
  static String? zapretIn(Iterable<String> names) {
    final found = names.map((n) => n.toLowerCase()).toSet();
    if (found.contains('winws2.exe')) return 'zapret 2';
    if (found.contains('winws.exe')) return 'zapret';
    return null;
  }

  /// Можно ли открывать такой адрес из данных провайдера: только веб-ссылки и Telegram.
  /// Иначе провайдер (или тот, кто подменил его ответ) мог бы подсунуть путь к программе —
  /// «Проводник» запустил бы её по клику на «Поддержка».
  static bool isSafeUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    return uri != null && const {'http', 'https', 'tg'}.contains(uri.scheme.toLowerCase()) && !url.contains('"');
  }

  static Future<void> openUrl(String url) async {
    if (!isSafeUrl(url)) return;
    await Process.run(AppPaths.explorer, [url.trim()]);
  }

  /// Сетевой адаптер, через который сейчас идёт трафик в интернет (лучший маршрут до 8.8.8.8).
  /// Напрямую через WinAPI (GetBestInterface + GetIfEntry2) — мгновенно, без запуска PowerShell.
  /// null — определить не удалось.
  static ({String alias, String description, int type, bool hardware})? defaultRouteAdapter() {
    try {
      final iphlp = DynamicLibrary.open('iphlpapi.dll');
      final k32 = DynamicLibrary.open('kernel32.dll');
      final getHeap = k32.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('GetProcessHeap');
      final heapAlloc = k32.lookupFunction<Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
          Pointer<Void> Function(Pointer<Void>, int, int)>('HeapAlloc');
      final heapFree = k32.lookupFunction<Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
          int Function(Pointer<Void>, int, Pointer<Void>)>('HeapFree');
      final getBestInterface = iphlp.lookupFunction<Uint32 Function(Uint32, Pointer<Uint32>),
          int Function(int, Pointer<Uint32>)>('GetBestInterface');
      final getIfEntry2 =
          iphlp.lookupFunction<Uint32 Function(Pointer<Uint8>), int Function(Pointer<Uint8>)>('GetIfEntry2');

      // Раскладка MIB_IF_ROW2: индекс, имя (Alias), описание, тип и флаги адаптера.
      const rowSize = 1352, offIndex = 8, offAlias = 28, offDescription = 542, offType = 1128, offFlags = 1152;
      const nameChars = 257;
      final heap = getHeap();
      final index = heapAlloc(heap, 0x8, 4).cast<Uint32>();
      final row = heapAlloc(heap, 0x8, rowSize).cast<Uint8>();
      try {
        if (getBestInterface(0x08080808, index) != 0) return null;
        (row + offIndex).cast<Uint32>().value = index.value;
        if (getIfEntry2(row) != 0) return null;
        String text(int offset) {
          final chars = (row + offset).cast<Uint16>().asTypedList(nameChars);
          final end = chars.indexOf(0);
          return String.fromCharCodes(end < 0 ? chars : chars.sublist(0, end));
        }

        return (
          alias: text(offAlias),
          description: text(offDescription),
          type: (row + offType).cast<Uint32>().value,
          hardware: (row + offFlags).value & 1 != 0,
        );
      } finally {
        heapFree(heap, 0, index.cast());
        heapFree(heap, 0, row.cast());
      }
    } catch (_) {
      return null;
    }
  }

  /// Имена нашего TUN-адаптера (у тестовой копии имя своё). Списком — чтобы уборка зависших
  /// адаптеров знала и имена, которые пробовали прежние версии.
  static List<String> get tunNames => [
        AppPaths.appName,
        for (var i = 2; i <= 4; i++) '${AppPaths.appName} $i',
      ];

  /// Кусок PowerShell: в `$own` — идентификаторы устройств наших адаптеров. sing-box выводит GUID
  /// адаптера из его имени (MD5 от "wintun" + имя), поэтому свои устройства известны заранее,
  /// даже если Windows их сейчас не показывает.
  static String get _ownTunIds =>
      r"$md5 = [Security.Cryptography.MD5]::Create(); "
      "\$own = @(${tunNames.map((n) => "'${n.replaceAll("'", "''")}'").join(',')}) | ForEach-Object { "
      r"('SWD\WINTUN\{' + ([Guid]::new($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes('wintun' + $_)))).ToString() + '}').ToUpper() }; ";

  static Future<void> _runTunCleanup(String script) async {
    // Удалять устройства может только администратор; без прав TUN всё равно не используется.
    if (!isAdmin()) return;
    try {
      await Process.run(AppPaths.powershell, ['-NoProfile', '-NonInteractive', '-Command', _ownTunIds + script])
          .timeout(const Duration(seconds: 20));
    } catch (_) {}
  }

  /// Убирает собственные зависшие адаптеры SkipIt, оставшиеся после сбоя. Чужие не трогает.
  /// Вызывать, только когда наш sing-box не запущен: работающий адаптер тоже был бы удалён.
  static Future<void> removeOwnTunAdapters() =>
      _runTunCleanup(r"foreach ($id in $own) { pnputil /remove-device $id 2>$null | Out-Null }");

  /// Убирает адаптеры, оставшиеся от закрытых VPN-клиентов: туннельные устройства, которые сейчас
  /// не работают. Действующие адаптеры (например, включённый WireGuard) и свои собственные не трогает.
  /// Вызывается только после согласия пользователя закрыть другой VPN.
  static Future<void> removeStaleForeignTunAdapters() => _runTunCleanup(
      r"Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | "
      r"Where-Object { $_.InstanceId -like 'SWD\WINTUN\*' -and $_.Status -ne 'OK' -and $own -notcontains $_.InstanceId.ToUpper() } | "
      r"ForEach-Object { pnputil /remove-device $_.InstanceId 2>$null | Out-Null }");

  /// Виртуальный адаптер, который сейчас забирает весь трафик (наш, второй копии программы или чужого
  /// VPN): имя такого адаптера или null. На соединение через него отвечает он сам, а не сервер.
  /// PPP сюда не входит: так подключаются и к обычному провайдеру.
  static String? tunnelOnDefaultRoute() {
    final a = defaultRouteAdapter();
    if (a == null) return null;
    final ours = tunNames.contains(a.alias);
    return ours || (!a.hardware && const {53, 131}.contains(a.type)) ? a.alias : null;
  }

  /// Другой VPN, который сейчас забирает весь трафик: маршрут в интернет идёт через виртуальный
  /// туннельный адаптер (Wintun, WireGuard, TAP, PPP). Свой адаптер не считается. При любой ошибке —
  /// пустой список: проверка не должна мешать подключению.
  static List<String> otherVpnAdapters() {
    final a = defaultRouteAdapter();
    if (a == null || a.hardware || tunNames.contains(a.alias)) return const [];
    // Типы адаптеров: 23 — PPP, 53 — виртуальный (Wintun/WireGuard), 131 — туннель.
    final tunnel = const {23, 53, 131}.contains(a.type) ||
        RegExp(r'\b(tap|tun|vpn|wintun|wireguard|openvpn)\b', caseSensitive: false).hasMatch(a.description);
    return tunnel ? [a.description.isNotEmpty ? a.description : a.alias] : const [];
  }

  /// Ядра чужих VPN-клиентов (имена exe без расширения). Работающее ядро значит, что другой VPN
  /// сейчас подключён: он занимает порты, маршруты и системный прокси.
  static const _foreignCores = {
    'xray', 'v2ray', 'sing-box', 'mihomo', 'clash', 'clash-meta', 'verge-mihomo', 'hysteria', 'hysteria2',
    'tun2socks', 'hiddifycli', 'nekobox_core', 'skipit-xray', 'skipit-sing-box',
  };

  /// Известные VPN-клиенты: имя exe без расширения → название для пользователя.
  static const _knownClients = {
    'happ': 'Happ', 'incy': 'Incy', 'v2rayn': 'v2rayN', 'hiddify': 'Hiddify', 'nekoray': 'NekoRay',
    'nekobox': 'NekoBox', 'throne': 'Throne', 'v2raytun': 'v2RayTun', 'karing': 'Karing',
    'clash-verge': 'Clash Verge', 'clash for windows': 'Clash for Windows', 'amneziavpn': 'AmneziaVPN',
    'skipit': 'SkipIt (другая копия)',
  };

  /// Другие VPN, которые сейчас подключены и будут мешать. Определяются по работающим ядрам
  /// (xray, sing-box и т. п. не из нашей папки) и по туннельному адаптеру, через который идёт трафик.
  /// Клиент, который просто открыт, но не подключён, помехой не считается.
  static List<VpnConflict> vpnConflicts() {
    final ownDir = '${File(AppPaths.exe).parent.path.toLowerCase()}\\';
    final ownCore = '${AppPaths.coreDir.path.toLowerCase()}\\';
    String base(String path) =>
        path.split('\\').last.toLowerCase().replaceAll(RegExp(r'\.exe$'), '');
    final others = [
      for (final p in _processes())
        if (!p.path.toLowerCase().startsWith(ownDir) && !p.path.toLowerCase().startsWith(ownCore)) p,
    ];
    final byName = <String, VpnConflict>{};
    for (final core in others.where((p) => _foreignCores.contains(base(p.path)))) {
      // Хозяин ядра — известный клиент, из папки которого (или выше) оно запущено.
      final corePath = core.path.toLowerCase();
      final owners = others.where((p) {
        if (!_knownClients.containsKey(base(p.path))) return false;
        final dir = p.path.toLowerCase();
        return corePath.startsWith(dir.substring(0, dir.lastIndexOf('\\') + 1));
      }).toList();
      final name = owners.isNotEmpty
          ? _knownClients[base(owners.first.path)]!
          : base(core.path).startsWith('skipit-')
              ? _knownClients['skipit']!
              : 'другой VPN (${core.path.split('\\').last})';
      final c = byName.putIfAbsent(name, () => VpnConflict(name));
      c.pids.add(core.pid);
      for (final o in owners) {
        if (!c.pids.contains(o.pid)) c.pids.add(o.pid);
      }
      for (final pid in c.pids) {
        c.paths[pid] = others.firstWhere((p) => p.pid == pid).path;
      }
      // Вторую копию SkipIt сначала просим выйти по-хорошему (она вернёт системный прокси).
      if (name == _knownClients['skipit']) c.isSkipIt = true;
    }
    if (byName.isEmpty) {
      // Ядер не нашли, но трафик идёт через чужой туннель (WireGuard, OpenVPN, корпоративный VPN) —
      // закрыть его сами не можем, только предупредить.
      for (final adapter in otherVpnAdapters()) {
        byName[adapter] = VpnConflict(adapter);
      }
    }
    return byName.values.toList();
  }

  /// Закрывает мешающие VPN, найденные [vpnConflicts].
  static Future<void> closeVpnConflicts(List<VpnConflict> conflicts) async {
    for (final c in conflicts) {
      if (c.isSkipIt) {
        // Команду выхода шлём сами по локальному порту второй копии. Чужой SkipIt.exe не запускаем:
        // мы работаем с правами администратора, а файл с таким именем мог подложить кто угодно.
        // 47813 — установленная программа, 47814 — тестовая копия; себе команду не шлём.
        for (final port in [47813, 47814].where((p) => p != (AppPaths.isDev ? 47814 : 47813))) {
          try {
            final s = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 1));
            s.write(jsonEncode(['--quit']));
            await s.flush();
            await s.close();
          } catch (_) {}
        }
        await Future.delayed(const Duration(seconds: 3));
      }
      // Закрываем только те процессы, что видели при проверке: за это время номер процесса мог
      // достаться другой программе, поэтому сверяем и путь.
      final alive = {for (final p in _processes()) p.pid: p.path};
      for (final pid in c.pids) {
        if (alive[pid] != null && alive[pid] == c.paths[pid]) await killPid(pid);
      }
    }
    // Закрытый клиент мог оставить системный прокси, указывающий на свой уже мёртвый порт, —
    // тогда у браузеров пропал бы интернет. Такой прокси выключаем.
    final proxy = await readProxy();
    final m = RegExp(r'^(?:https?=)?(?:127\.0\.0\.1|localhost):(\d+)').firstMatch(proxy.server);
    if (proxy.enabled && m != null) {
      try {
        final s = await Socket.connect(InternetAddress.loopbackIPv4, int.parse(m.group(1)!),
            timeout: const Duration(milliseconds: 400));
        s.destroy();
      } catch (_) {
        await restoreProxy(null);
      }
    }
    // И адаптеры, оставшиеся от закрытых клиентов (пользователь согласился их закрыть).
    await removeStaleForeignTunAdapters();
  }

  /// Поднялся ли наш TUN-адаптер: трафик в интернет уже идёт через него.
  static bool ownTunActive() => tunNames.contains(defaultRouteAdapter()?.alias);

  static Future<void> killPid(int pid) async {
    await Process.run(AppPaths.system('taskkill'), ['/F', '/T', '/PID', '$pid']);
  }
}
