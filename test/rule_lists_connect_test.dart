import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/core/rule_list.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/state/app_state.dart';

/// Решение о гео-базах и списках по ссылке при подключении (AppState.prepareConnectGeoAndLists).
void main() {
  late AppState state;
  late Directory tmp;

  setUpAll(() async => AppPaths.init());

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('skipit-rlconnect');
    AppPaths.dataDir = tmp;
    // Гео-базы живут в geoDir, который init() ставит один раз, — тестам он нужен во временной папке.
    AppPaths.geoDir = Directory('${tmp.path}\\geo')..createSync();
    state = AppState();
  });

  tearDown(() async => _cleanUp(state, tmp));

  test('geosite-запись в кэше списка — гео-базы качаются и без блокировки рекламы', () async {
    // Локальный «сервер» гео-баз отвечает на любой запрос.
    final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    srv.listen((r) => r.response
      ..write('geo')
      ..close());

    final profile = RoutingProfile(name: 'Тест', ruleLists: [
      RuleListSource(url: 'https://rules.example/list.txt', action: 'proxy'),
    ])
      ..geoipUrl = 'http://127.0.0.1:${srv.port}/geoip.dat'
      ..geositeUrl = 'http://127.0.0.1:${srv.port}/geosite.dat';
    state.routingProfiles.add(profile);
    state.settings.selectedRoutingId = profile.id;
    // Кэш списка с записью geosite: — без гео-баз ядро с таким конфигом не запустится.
    final dir = Directory(AppPaths.ruleListsDir)..createSync(recursive: true);
    File('${dir.path}\\${RuleList.cacheFile(profile.id, profile.ruleLists.single.url)}')
        .writeAsStringSync('geosite:category-ru\n');

    await state.prepareConnectGeoAndLists(state.routingForConfig, null);

    expect(File(AppPaths.geoipFile).existsSync(), isTrue);
    expect(File(AppPaths.geositeFile).existsSync(), isTrue);

    await srv.close(force: true);
  });

  test('без geosite-записей и без блокировки рекламы гео-базы не качаются', () async {
    final profile = RoutingProfile(name: 'Тест', ruleLists: [
      RuleListSource(url: 'https://rules.example/list.txt', action: 'proxy'),
    ]);
    state.routingProfiles.add(profile);
    state.settings.selectedRoutingId = profile.id;
    final dir = Directory(AppPaths.ruleListsDir)..createSync(recursive: true);
    File('${dir.path}\\${RuleList.cacheFile(profile.id, profile.ruleLists.single.url)}')
        .writeAsStringSync('example.com\n');

    await state.prepareConnectGeoAndLists(state.routingForConfig, null);

    expect(File(AppPaths.geoipFile).existsSync(), isFalse);
    expect(File(AppPaths.geositeFile).existsSync(), isFalse);
  });

  test('при «Мой DNS» фон обновляет списки сохранённого профиля, а не копии для конфига', () async {
    final profile = RoutingProfile(name: 'Тест', ruleLists: [
      RuleListSource(url: 'https://rules.example/list.txt', action: 'proxy'),
    ]);
    state.routingProfiles.add(profile);
    state.settings
      ..selectedRoutingId = profile.id
      ..ownDns = true
      ..ownDnsRemote = '9.9.9.9'
      ..ownDnsDomestic = '77.88.8.8';

    Directory(AppPaths.ruleListsDir).createSync(recursive: true);
    File(RuleList.path(profile.id, profile.ruleLists.single.url)).writeAsStringSync('example.com');
    await state.prepareConnectGeoAndLists(state.routingForConfig, null);

    expect(state.ruleListRoutingForUpdate, same(profile));
  });
}

/// Уборка после теста (отложенная запись state.json иначе срабатывала уже в следующем тесте).
Future<void> _cleanUp(AppState state, Directory tmp) async {
  await state.saveNow();
  state.dispose();
  for (var attempt = 1; attempt <= 10; attempt++) {
    try {
      await tmp.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}
