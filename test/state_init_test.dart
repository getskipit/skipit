import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/kill_switch.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/models/settings.dart';
import 'package:skipit/state/app_state.dart';

/// Файл данных может быть занят при запуске (антивирус, выходящая копия программы).
/// Подписки не должны теряться, а пустое состояние — затирать файл.
void main() {
  test('занятый на секунду state.json всё равно загружается', () async {
    await AppPaths.init();
    final tmp = await Directory.systemTemp.createTemp('skipit-test');
    AppPaths.dataDir = tmp;
    final file = File(AppPaths.stateFile);
    await file.writeAsString('{"subscriptions":[{"id":"s1","url":"https://example.com/sub","name":"Test"}],'
        '"servers":[{"id":"a","name":"A","protocol":"vless","address":"1.1.1.1","port":443,"link":"vless://x","outbound":{},"subscriptionId":"s1"}]}');

    final raf = await file.open(mode: FileMode.append);
    await raf.lock(FileLock.exclusive);
    Future.delayed(const Duration(seconds: 1), () async {
      await raf.unlock();
      await raf.close();
    });

    final state = AppState();
    await state.loadForTest();
    expect(state.subscriptions.length, 1);
    expect(state.servers.length, 1);
    await tmp.delete(recursive: true);
  });

  test('Kill Switch выключен по умолчанию и сохраняется в настройках', () async {
    expect(AppSettings().killSwitch, isFalse);
    expect(AppSettings.fromJson(const {}).killSwitch, isFalse);
    final on = AppSettings()..killSwitch = true;
    expect(AppSettings.fromJson(on.toJson()).killSwitch, isTrue);

    // Пока фильтры не стоят, окно не должно показывать, что интернет закрыт.
    final state = AppState();
    expect(state.killSwitchHolding, isFalse);
    // Выключение Kill Switch без подключения ничего не ломает (в тестах нет оболочки окна).
    await state.releaseKillSwitch();
    expect(KillSwitch.active, isFalse);
  });

  test('MTU по умолчанию 1500; сохранённые прежние 9000 один раз заменяются на 1500', () {
    expect(AppSettings().mtu, 1500);
    expect(AppSettings.fromJson(const {'mtu': 9000}).mtu, 1500);
    expect(AppSettings.fromJson(const {'mtu': 1400}).mtu, 1400);
    // После замены 9000, выбранные вручную, остаются.
    final own = AppSettings()..mtu = 9000;
    expect(AppSettings.fromJson(own.toJson()).mtu, 9000);
  });
}
