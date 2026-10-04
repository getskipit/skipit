import 'package:flutter/services.dart';

import 'paths.dart';

/// Значок в системном трее. Сам значок и меню живут в C++-оболочке окна
/// (windows/runner/flutter_window.cpp), здесь — только канал управления.
class Tray {
  static const _channel = MethodChannel('skipit/tray');

  /// [onToggle] — пункт «Подключить/Отключить», [onExit] — «Выход».
  /// [onMode], [onCore] и [onServer] — выбор режима, ядра TUN и сервера в меню значка
  /// (приходит номер пункта).
  static void init({
    required Future<void> Function() onToggle,
    required Future<void> Function() onExit,
    required Future<void> Function(int index) onMode,
    required Future<void> Function(int index) onCore,
    required Future<void> Function(int index) onServer,
  }) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'toggle':
          await onToggle();
        case 'exit':
          await onExit();
        case 'mode':
          await onMode(call.arguments as int);
        case 'core':
          await onCore(call.arguments as int);
        case 'server':
          await onServer(call.arguments as int);
      }
      return null;
    });
  }

  static Future<void> _call(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // В тестах нет нативной оболочки — трей просто отсутствует.
    }
  }

  /// [status] и [server] — шапка меню значка, [state]: 0 — не подключено, 1 — идёт подключение
  /// или отключение, 2 — подключено; [dark] — тема программы (меню рисуется в её цветах).
  /// [cores] — ядра TUN; пустой список прячет их переключатель (режим без адаптера).
  static Future<void> update({
    required String tooltip,
    required bool connected,
    required bool closeToTray,
    required bool notifications,
    required String status,
    required String server,
    required int state,
    required bool dark,
    required List<String> modes,
    required int mode,
    required List<String> cores,
    required int core,
    required List<Map<String, String>> servers,
    required int selectedServer,
  }) =>
      _call('update', {
        'modeLabel': 'РЕЖИМ',
        'serversLabel': 'СЕРВЕР',
        'coreLabel': 'ЯДРО TUN',
        'modes': modes,
        'mode': mode,
        'cores': cores,
        'core': core,
        'servers': servers,
        'selectedServer': selectedServer,
        'title': AppPaths.appName,
        'status': status,
        'server': server,
        'state': state,
        'dark': dark,
        // У Windows ограничение подсказки — 127 символов.
        'tooltip': tooltip.length > 120 ? '${tooltip.substring(0, 119)}…' : tooltip,
        'open': 'Открыть ${AppPaths.appName}',
        'toggle': connected ? 'Отключить' : 'Подключить',
        'exit': 'Выход',
        'closeToTray': closeToTray,
        // Уведомление при закрытии окна крестиком (раз за запуск); пустая строка его выключает.
        'closeHint': notifications ? 'Продолжает работать в трее' : '',
      });

  static Future<void> show() => _call('show');

  /// Уведомление Windows у значка. Оболочка показывает его, только когда окно спрятано или свёрнуто.
  static Future<void> notify(String text) => _call('notify', {'title': AppPaths.appName, 'text': text});

  /// Убирает значок и закрывает окно. Перед вызовом всё уже должно быть остановлено.
  static Future<void> quit() => _call('quit');
}
