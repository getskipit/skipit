import 'package:flutter/services.dart';

import 'paths.dart';
import '../l10n/l10n.dart';

/// Значок в системном трее. Сам значок и меню живут в C++-оболочке окна
/// (windows/runner/flutter_window.cpp), здесь — только канал управления.
class Tray {
  static const _channel = MethodChannel('skipit/tray');

  /// [onToggle] — пункт «Подключить/Отключить», [onExit] — «Выход».
  /// [onMode], [onCore] и [onServer] — выбор режима, ядра TUN и сервера в меню значка
  /// (приходит номер пункта). [onNetwork] — компьютер проснулся ([resume] — true) или сменилась сеть.
  static void init({
    required Future<void> Function() onToggle,
    required Future<void> Function() onExit,
    required Future<void> Function(int index) onMode,
    required Future<void> Function(int index) onCore,
    required Future<void> Function(int index) onServer,
    required Future<void> Function() onKillSwitch,
    required void Function(bool resume) onNetwork,
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
        case 'killSwitch':
          await onKillSwitch();
        case 'network':
          onNetwork(call.arguments == true);
      }
      return null;
    });
  }

  /// Снимок всех мониторов (окно SkipIt на это время прячется) в оттенках серого; null — снять не удалось.
  static Future<({Uint8List gray, int w, int h})?> captureScreen() => _image('captureScreen');

  /// Картинка из буфера обмена в оттенках серого; null — картинки там нет.
  static Future<({Uint8List gray, int w, int h})?> clipboardImage() => _image('clipboardImage');

  static Future<({Uint8List gray, int w, int h})?> _image(String method) async {
    try {
      final r = await _channel.invokeMethod<Map<Object?, Object?>>(method);
      if (r == null) return null;
      return (gray: r['gray'] as Uint8List, w: r['w'] as int, h: r['h'] as int);
    } on MissingPluginException {
      return null;
    }
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
  /// [killSwitch] — выключатель Kill Switch; null прячет его (он действует только в режимах с адаптером).
  static Future<void> update({
    required String tooltip,
    required bool connected,
    required bool closeToTray,
    required bool notifications,
    required String status,
    required String server,
    required int state,
    required bool dark,
    required Color accent,
    required Color accentLight,
    required List<String> modes,
    required int mode,
    required List<String> cores,
    required int core,
    required bool? killSwitch,
    required List<Map<String, String>> servers,
    required int selectedServer,
    required double uiScale,
  }) =>
      _call('update', {
        'modeLabel': tr('РЕЖИМ'),
        'serversLabel': tr('СЕРВЕР'),
        'coreLabel': tr('РЕЖИМ TUN'),
        'modes': modes,
        'mode': mode,
        'cores': cores,
        'core': core,
        // Выключатель Kill Switch: −1 — пункта в меню нет.
        'killSwitch': killSwitch == null ? -1 : (killSwitch ? 1 : 0),
        'servers': servers,
        'selectedServer': selectedServer,
        'title': AppPaths.appName,
        'status': status,
        'server': server,
        'state': state,
        'dark': dark,
        // Цвет акцента для своего меню в трее: 0xRRGGBB.
        'accent': accent.toARGB32() & 0xFFFFFF,
        'accentLight': accentLight.toARGB32() & 0xFFFFFF,
        // У Windows ограничение подсказки — 127 символов.
        'tooltip': tooltip.length > 120 ? '${tooltip.substring(0, 119)}…' : tooltip,
        'open': tr('Открыть {0}', [AppPaths.appName]),
        'toggle': connected ? tr('Отключить') : tr('Подключить'),
        'exit': tr('Выход'),
        'closeToTray': closeToTray,
        // Масштаб интерфейса: во столько же раз меньше наименьший размер окна.
        'uiScale': uiScale,
        // Уведомление при закрытии окна крестиком (раз за запуск); пустая строка его выключает.
        'closeHint': notifications ? tr('Продолжает работать в трее') : '',
      });

  static Future<void> show() => _call('show');

  /// Свой значок окна и трея: картинки RGBA нескольких размеров; пустой список — обычный.
  static Future<void> setIcon(List<({int size, Uint8List rgba})> images) =>
      _call('setIcon', [for (final i in images) {'size': i.size, 'rgba': i.rgba}]);

  /// Уведомление Windows у значка. Оболочка показывает его, только когда окно спрятано или свёрнуто.
  /// [kind] — цвет отметки на значке уведомления: ok — связь вернулась, warn — сбой, error — ошибка, info — без отметки.
  static Future<void> notify(String text, {String kind = 'info'}) =>
      _call('notify', {'title': AppPaths.appName, 'text': text, 'kind': kind});

  /// Убирает значок и закрывает окно. Перед вызовом всё уже должно быть остановлено.
  static Future<void> quit() => _call('quit');
}
