import 'package:flutter/services.dart';

import 'core_manager.dart';
import 'paths.dart';
import 'service_client.dart';
import 'windows.dart';
import 'xray_config.dart';

/// Kill Switch: пока он включён, Windows не выпускает трафик мимо VPN. В сеть могут выходить только
/// ядра, соединения через адаптер VPN и локальная сеть (без DNS). Если адаптер пропал — ядро упало —
/// программы остаются без интернета, а не идут напрямую со своего настоящего адреса.
///
/// Сами фильтры Windows ставит C++-оболочка окна (windows/runner/kill_switch.cpp), здесь — канал
/// управления. Фильтры живут, пока работает программа: при выходе, даже аварийном, Windows убирает их сама.
/// Без прав администратора те же фильтры ставит служба SkipIt (windows\service): она держит их, пока к ней
/// подключена программа, и снимает, если программа закрылась.
class KillSwitch {
  static const _channel = MethodChannel('skipit/killswitch');

  /// Фильтры сейчас стоят.
  static bool active = false;

  /// Куда писать события Kill Switch (журнал программы).
  static void Function(String text)? onLog;

  /// Фильтры поставила служба SkipIt (у программы нет прав администратора).
  static bool _viaService = false;

  /// Ставит фильтры: сама программа, если у неё есть права администратора, иначе — служба SkipIt.
  static Future<void> engage() async {
    if (active) return;
    if (!WinSys.isAdmin()) {
      final reply = await ServiceClient.hold('ks engage\n${XrayConfig.tunV4}\n${XrayConfig.tunV6}');
      if (reply != 'ok') {
        throw CoreException('Не удалось включить Kill Switch (${reply == null ? 'служба SkipIt не отвечает' : reply.replaceFirst('error ', '')}). '
            'Подключение остановлено, чтобы не работать без обещанной защиты. '
            'Выключить его можно в Настройки → Подключение.');
      }
      active = true;
      _viaService = true;
      onLog?.call('Kill Switch включён (службой SkipIt)');
      return;
    }
    _viaService = false;
    try {
      await _channel.invokeMethod<void>('engage', {
        'apps': [AppPaths.xrayExe, AppPaths.singboxExe],
        'v4': XrayConfig.tunV4,
        'v6': XrayConfig.tunV6,
      });
      active = true;
      onLog?.call('Kill Switch включён');
    } on PlatformException catch (e) {
      throw CoreException('Не удалось включить Kill Switch (${e.message}). '
          'Подключение остановлено, чтобы не работать без обещанной защиты. '
          'Выключить его можно в Настройки → Подключение.');
    } on MissingPluginException {
      throw CoreException('Kill Switch недоступен в этой сборке.');
    }
  }

  /// Снимает фильтры: интернет снова открыт и без VPN.
  static Future<void> release() async {
    if (!active) return;
    active = false;
    try {
      int code, left;
      if (_viaService) {
        final parts = (await ServiceClient.command('ks release'))?.split(' ') ?? const [];
        code = parts.length == 3 ? int.tryParse(parts[1]) ?? -1 : -1;
        left = parts.length == 3 ? int.tryParse(parts[2]) ?? -1 : -1;
      } else {
        final r = await _channel.invokeMapMethod<String, Object?>('release');
        code = r?['code'] as int? ?? 0;
        left = r?['left'] as int? ?? -1;
      }
      onLog?.call('Kill Switch снят');
      // Windows должна убрать все фильтры разом. Если нет — интернет остался бы закрытым без причины на экране.
      if (code != 0 || left > 0) {
        onLog?.call('Ошибка: Kill Switch снят не полностью — ответ Windows 0x${code.toRadixString(16)}, '
            'фильтров осталось: $left');
      }
    } catch (_) {}
  }

  /// Проверка после отключения: программа считает Kill Switch снятым — так ли это в Windows.
  /// Расхождение пишется в журнал.
  static Future<void> verifyReleased() async {
    if (active) return;
    try {
      bool engaged;
      int left;
      if (_viaService) {
        final parts = (await ServiceClient.command('ks status'))?.split(' ') ?? const [];
        engaged = parts.isNotEmpty && parts[0] == '1';
        left = parts.length == 2 ? int.tryParse(parts[1]) ?? -1 : -1;
      } else {
        final r = await _channel.invokeMapMethod<String, Object?>('status');
        engaged = r?['engaged'] == true;
        left = r?['left'] as int? ?? -1;
      }
      if (engaged || left > 0) {
        onLog?.call('Ошибка: Kill Switch считается снятым, но фильтры в Windows остались '
            '(сеанс открыт: ${engaged ? 'да' : 'нет'}, фильтров: $left)');
      }
    } catch (_) {}
  }
}
