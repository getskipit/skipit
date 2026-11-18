import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/core/windows.dart';

void main() {
  test('Список запущенных программ строится быстро и без системных процессов', () async {
    await AppPaths.init();
    final sw = Stopwatch()..start();
    final apps = await WinSys.runningApps();
    sw.stop();
    // ignore: avoid_print
    print('программ: ${apps.length}, за ${sw.elapsedMilliseconds} мс; пример: ${apps.take(5).map((a) => a.name).join(', ')}');
    expect(apps, isNotEmpty);
    expect(sw.elapsedMilliseconds, lessThan(1000));
    expect(apps.any((a) => a.path.toLowerCase().contains(r'\windows\system32\')), isFalse);
  });
  test('Проверка на другие VPN и на адаптер по умолчанию работает мгновенно и не падает', () async {
    await AppPaths.init();
    final sw = Stopwatch()..start();
    final adapter = WinSys.defaultRouteAdapter();
    final conflicts = await WinSys.vpnConflicts();
    sw.stop();
    // ignore: avoid_print
    print('адаптер: ${adapter?.alias} (${adapter?.description}), мешающих VPN: ${conflicts.map((c) => c.name).toList()}, '
        'за ${sw.elapsedMilliseconds} мс');
    expect(sw.elapsedMilliseconds, lessThan(1000));
    // Собственные процессы теста и его ядра помехой считаться не должны.
    expect(conflicts.every((c) => c.name.isNotEmpty), isTrue);
  });

  test('zapret узнаётся по рабочему процессу, в том числе запущенному службой', () {
    final sw = Stopwatch()..start();
    final names = WinSys.processNames();
    sw.stop();
    // Список имён видит все процессы — и системные, путь к которым узнать нельзя.
    expect(names, contains('system'));
    expect(names.any((n) => n.endsWith('.exe')), isTrue);
    expect(sw.elapsedMilliseconds, lessThan(500));

    expect(WinSys.zapretIn(['explorer.exe', 'WinWS.exe']), 'zapret');
    expect(WinSys.zapretIn(['winws2.exe', 'chrome.exe']), 'zapret 2');
    expect(WinSys.zapretIn(['winws.exe', 'winws2.exe']), 'zapret 2');
    expect(WinSys.zapretIn(['explorer.exe', 'winword.exe']), isNull);
  });
}
