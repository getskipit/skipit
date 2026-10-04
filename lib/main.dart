import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/paths.dart';
import 'core/tray.dart';
import 'core/windows.dart';
import 'models/server.dart';
import 'models/settings.dart';
import 'state/app_scope.dart';
import 'state/app_state.dart';
import 'ui/flag_text.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

/// Режимы в меню значка — в том же порядке, что на главной.
const trayModes = [ConnectionMode.mixed, ConnectionMode.tun, ConnectionMode.systemProxy, ConnectionMode.proxyOnly];

/// Серверы, показанные в меню значка (id по порядку): меню сообщает номер выбранного пункта.
var trayServers = <String>[];

// У тестовой сборки свой порт: она запускается рядом с установленной программой и не передаёт ей ссылки.
final _instancePort = AppPaths.isDev ? 47814 : 47813;

/// Защита от подмены аргументов через ссылку. Windows запускает программу как `SkipIt.exe "%1"`,
/// и ссылка с кавычкой внутри (`skipit://x" --quit "`) могла бы добавить свои ключи — например,
/// закрыть программу и оборвать VPN или запустить подключение. Поэтому запуск со ссылкой
/// считается только запуском по ссылке: всё, что не похоже на ссылку, отбрасывается.
List<String> sanitizeArgs(List<String> args) =>
    args.any((a) => a.contains('://')) ? [for (final a in args) if (a.contains('://')) a] : args;

/// Второй запуск (например, по ссылке skipit://…) передаёт аргументы первому и выходит.
Future<ServerSocket?> _acquireSingleInstance(List<String> args) async {
  // `SkipIt.exe --quit` (так делает установщик перед обновлением/удалением): попросить запущенную
  // копию корректно выйти — отключить VPN и вернуть системный прокси — и завершиться самим.
  if (args.contains('--quit')) {
    try {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, _instancePort, timeout: const Duration(seconds: 1));
      s.write(jsonEncode(['--quit']));
      await s.flush();
      await s.close();
    } catch (_) {}
    exit(0);
  }
  final elevated = args.contains('--elevated');
  final deadline = DateTime.now().add(Duration(seconds: elevated ? 8 : 0));
  while (true) {
    try {
      return await ServerSocket.bind(InternetAddress.loopbackIPv4, _instancePort);
    } catch (_) {}
    if (!elevated) {
      try {
        final s = await Socket.connect(InternetAddress.loopbackIPv4, _instancePort,
            timeout: const Duration(seconds: 1));
        s.write(jsonEncode(args));
        await s.flush();
        await s.close();
        exit(0);
      } catch (_) {
        return null; // Порт занят кем-то другим — просто работаем без защиты от дублей.
      }
    }
    if (DateTime.now().isAfter(deadline)) return null;
    await Future.delayed(const Duration(milliseconds: 250));
  }
}

Future<void> main(List<String> rawArgs) async {
  WidgetsFlutterBinding.ensureInitialized();
  final args = sanitizeArgs(rawArgs);
  var server = await _acquireSingleInstance(args);
  await AppPaths.init();

  final state = AppState();
  await state.load();
  // «Запускать от имени администратора»: перезапускаемся с правами ещё до показа окна.
  // Если в окне Windows ответили «Нет», работаем дальше без прав (TUN будет недоступен).
  if (state.needsElevation(args)) {
    await server?.close();
    if (await WinSys.relaunchAsAdmin(args)) {
      await Tray.quit();
      exit(0);
    }
    server = await _acquireSingleInstance([...args, '--no-elevate']);
  }
  server?.listen((socket) async {
    try {
      // Порт слушает только этот компьютер, но постучаться в него может любая программа и даже
      // страница в браузере. Принимаем только то, что прислала вторая копия SkipIt: короткий JSON-список.
      final text = await utf8.decoder.bind(socket).take(64).join().timeout(const Duration(seconds: 3));
      if (text.length > 16 * 1024) return;
      final forwarded = sanitizeArgs((jsonDecode(text) as List).map((e) => e.toString()).toList());
      if (forwarded.contains('--quit')) {
        await state.shutdown();
        await Tray.quit();
        exit(0);
      }
      await state.handleArgs(forwarded);
      // Повторный запуск (ярлык, ссылка skipit://) — показываем окно, даже если оно в трее.
      await Tray.show();
    } catch (_) {
      // Не наш формат — молча игнорируем (и окно не показываем).
    } finally {
      socket.destroy();
    }
  });

  Tray.init(
    onToggle: () async {
      // Найден другой подключённый VPN — показываем окно: там спросят, что с ним делать.
      if (!state.isConnected && !state.isBusy && state.findVpnConflicts().isNotEmpty) {
        await Tray.show();
        state.requestConnect();
        return;
      }
      try {
        await state.toggle();
      } on NeedAdminException catch (e) {
        await Tray.show();
        state.toast('$e — нажмите кнопку подключения в окне');
      }
    },
    onExit: () async {
      await state.shutdown();
      await Tray.quit();
    },
    // Режим, ядро TUN и сервер, выбранные в меню значка. Если VPN подключён, он переподключится сам.
    onMode: (index) async {
      if (index < 0 || index >= trayModes.length) return;
      try {
        await state.setMode(trayModes[index]);
      } on NeedAdminException catch (e) {
        await Tray.show();
        state.toast('$e — нажмите кнопку подключения в окне');
      }
    },
    onCore: (index) async {
      if (index < 0 || index >= TunCore.values.length) return;
      try {
        await state.setTunCore(TunCore.values[index]);
      } on NeedAdminException catch (e) {
        await Tray.show();
        state.toast('$e — нажмите кнопку подключения в окне');
      }
    },
    onServer: (index) async {
      if (index < 0 || index >= trayServers.length) return;
      try {
        await state.selectServer(trayServers[index]);
      } on NeedAdminException catch (e) {
        await Tray.show();
        state.toast('$e — нажмите кнопку подключения в окне');
      }
    },
  );
  // Подсказка и меню трея следят за состоянием подключения.
  var lastTray = '';
  // Картинки флагов лежат рядом с программой — меню значка рисует их само, вне окна Flutter.
  final flagsDir = '${File(Platform.resolvedExecutable).parent.path}\\data\\flutter_assets\\assets\\flags';
  void syncTray() {
    final name = state.selectedServer?.name;
    final server = name == null ? null : Flags.forTray(name);
    final status = switch (state.status) {
      ConnStatus.connected => 'Подключено',
      ConnStatus.connecting => 'Подключение…',
      ConnStatus.disconnecting => 'Отключение…',
      ConnStatus.disconnected => state.killSwitchHolding ? 'Интернет закрыт: Kill Switch' : 'Не подключено',
    };
    final tooltip = '${AppPaths.appName} — $status${server != null ? '\n$server' : ''}';
    // Тема берётся из настроек, а не из уже применённой палитры: этот обработчик срабатывает раньше,
    // чем окно перекрасится.
    final dark = switch (state.settings.theme) {
      AppTheme.dark => true,
      AppTheme.light => false,
      AppTheme.system => WidgetsBinding.instance.platformDispatcher.platformBrightness != Brightness.light,
    };
    // Серверы для меню — в том же порядке, что на главной (не больше 60: меню прокручивается колесом).
    final servers = state.servers.take(60).toList();
    // Провайдер каждого сервера — для заголовков в списке. Если провайдер один, заголовки не нужны.
    String groupOf(ServerProfile s) {
      final sub = state.subscriptionById(s.subscriptionId);
      return sub == null ? 'Свои серверы' : Flags.forTray(sub.displayName);
    }

    final groups = [for (final s in servers) groupOf(s)];
    final grouped = groups.toSet().length > 1;
    final key = '$tooltip|${state.status.name}|${state.settings.closeToTray}|${state.settings.notifications}|$dark|${state.settings.mode.name}|'
        '${state.usesTun ? state.settings.tunCore.name : ''}|${grouped ? groups.join(',') : ''}|'
        '${state.settings.selectedServerId}|${servers.map((s) => '${s.id}:${s.name}').join(',')}';
    if (key == lastTray) return;
    lastTray = key;
    trayServers = [for (final s in servers) s.id];
    Tray.update(
      tooltip: tooltip,
      connected: state.isConnected,
      closeToTray: state.settings.closeToTray,
      notifications: state.settings.notifications,
      status: status,
      server: server ?? 'Сервер не выбран',
      state: state.isConnected ? 2 : (state.isBusy ? 1 : 0),
      dark: dark,
      modes: [for (final m in trayModes) m == ConnectionMode.proxyOnly ? 'Порты' : m.label],
      mode: trayModes.indexOf(state.settings.mode),
      // Ядро TUN выбирается только в режимах с адаптером — в остальных переключателя в меню нет.
      cores: state.usesTun ? const ['sing-box', 'Xray'] : const [],
      core: TunCore.values.indexOf(state.settings.tunCore),
      servers: [
        for (final (i, s) in servers.indexed)
          () {
            final (country, rest) = Flags.leading(s.name);
            final flag = country == null ? '' : '$flagsDir\\$country.png';
            return {
              'name': Flags.forTray(rest),
              'flag': flag.isNotEmpty && File(flag).existsSync() ? flag : '',
              'group': grouped ? groups[i] : '',
            };
          }(),
      ],
      selectedServer: servers.indexWhere((s) => s.id == state.settings.selectedServerId),
    );
  }

  state.addListener(syncTray);
  syncTray();

  runApp(SkipItApp(state: state));
  unawaited(state.init(args));
}

class SkipItApp extends StatefulWidget {
  const SkipItApp({super.key, required this.state});
  final AppState state;

  @override
  State<SkipItApp> createState() => _SkipItAppState();
}

class _SkipItAppState extends State<SkipItApp> with WidgetsBindingObserver {
  late final AppLifecycleListener _lifecycle;
  late Palette _palette = _resolvePalette();

  Palette _resolvePalette() => switch (widget.state.settings.theme) {
        AppTheme.dark => Palette.dark,
        AppTheme.light => Palette.light,
        AppTheme.system => WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.light
            ? Palette.light
            : Palette.dark,
      };

  /// Тема меняется в настройках или в Windows («Как в системе»). Цвета читаются при построении
  /// виджетов, поэтому перестраиваем все виджеты окна — но не пересоздаём их: состояние (открытый
  /// раздел, прокрутка, анимация переключателей) сохраняется, и смена темы выглядит плавно.
  void _syncTheme() {
    final p = _resolvePalette();
    if (identical(p, _palette)) return;
    void apply() {
      if (!mounted) return;
      setState(() => _palette = p);
      C.use(p);
      void rebuild(Element e) {
        e.markNeedsBuild();
        e.visitChildren(rebuild);
      }

      (context as Element).visitChildren(rebuild);
    }

    // Во время построения кадра помечать виджеты нельзя — откладываем до его конца.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null) didChangeAppLifecycleState(lifecycle);
    widget.state.addListener(_syncTheme);
    // При закрытии окна обязательно гасим ядро и возвращаем системный прокси.
    _lifecycle = AppLifecycleListener(onExitRequested: () async {
      await widget.state.shutdown();
      return AppExitResponse.exit;
    });
  }

  @override
  void didChangePlatformBrightness() => _syncTheme();

  /// Окно свернули или спрятали в трей — Windows сообщает состояние «hidden».
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.state.windowVisible = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.state.removeListener(_syncTheme);
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    C.use(_palette);
    return AppScope(
      state: widget.state,
      child: MaterialApp(
        title: AppPaths.appName,
        debugShowCheckedModeBanner: false,
        // Интерфейс на русском: встроенные подписи Flutter (меню полей ввода, подсказки кнопок) — тоже.
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: buildTheme(),
        home: const Shell(),
      ),
    );
  }
}