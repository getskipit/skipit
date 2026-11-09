import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/core_manager.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/core/windows.dart';
import 'package:skipit/models/app_rules.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/subscription.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/state/settings_import.dart';

/// Подписки и серверы на диске зашифрованы ключом учётной записи Windows; перенос — через экспорт.
void main() {
  late Directory tmp;
  const url = 'https://panel.example/sub/SECRET-TOKEN';

  setUp(() async {
    await AppPaths.init();
    tmp = await Directory.systemTemp.createTemp('skipit-protected');
    AppPaths.dataDir = tmp;
  });
  tearDown(() async => tmp.delete(recursive: true));

  AppState filled() {
    final state = AppState();
    final sub = Subscription(url: url, name: 'Провайдер');
    state.subscriptions.add(sub);
    final server = LinkParser.parseText('trojan://PASSWORD-123@server.example:443#Germany').servers.single
      ..subscriptionId = sub.id;
    state.servers.add(server);
    state.settings
      ..selectedServerId = server.id
      ..killSwitch = true;
    return state;
  }

  test('шифрование Windows: свои данные читаются, чужие и повреждённые — нет', () {
    final plain = Uint8List.fromList(utf8.encode('ссылка подписки $url'));
    final blob = WinSys.protect(plain)!;
    expect(utf8.decode(blob, allowMalformed: true), isNot(contains('SECRET-TOKEN')));
    expect(WinSys.unprotect(blob), plain);
    expect(WinSys.unprotect(Uint8List.fromList([...blob]..[blob.length ~/ 2] ^= 0xFF)), isNull);
    expect(WinSys.unprotect(Uint8List.fromList(utf8.encode('это не шифр'))), isNull);
    expect(WinSys.unprotect(WinSys.protect(Uint8List(0))!), isEmpty);
  });

  test('в файле данных нет ссылок подписок и ключей серверов, а после запуска они на месте', () async {
    await filled().saveNow();
    final text = File(AppPaths.stateFile).readAsStringSync();
    expect(text, isNot(contains('SECRET-TOKEN')));
    expect(text, isNot(contains('PASSWORD-123')));
    expect(text, isNot(contains('server.example')));
    final j = jsonDecode(text) as Map<String, dynamic>;
    expect(j['protected'], isA<String>());
    expect(j.containsKey('subscriptions'), isFalse);
    // Настройки остаются открытыми — в них нет секретов.
    expect((j['settings'] as Map)['killSwitch'], isTrue);

    final again = AppState();
    await again.loadForTest();
    expect(again.subscriptions.single.url, url);
    expect(again.servers.single.address, 'server.example');
    expect(again.selectedServer?.name, 'Germany');
    expect(again.protectedUnreadable, isFalse);
  });

  test('отказ DPAPI не записывает открытые ключи и сохраняет прежний файл', () async {
    final state = filled()..protectState = (_) => null;
    final stateFile = File(AppPaths.stateFile);
    final pending = File('${stateFile.path}.tmp');
    final toast = state.messages.first;
    final failure = await state.saveNow();
    expect(failure, contains('Windows не удалось зашифровать'));
    expect((await toast).kind, ToastKind.error);
    expect(stateFile.existsSync(), isFalse);
    expect(pending.existsSync(), isFalse);

    state.protectState = WinSys.protect;
    expect(await state.saveNow(), isNull);
    final previous = await stateFile.readAsBytes();
    final exported = await state.exportData(tmp.path);

    state.protectState = (_) => null;
    state.subscriptions.single.url = 'https://panel.example/sub/NEW-SECRET';
    expect(await state.importData(exported), failure);
    expect(await stateFile.readAsBytes(), previous);
    expect(pending.existsSync(), isFalse);
    state.dispose();
  });

  test('файл от прежней версии (без шифрования) читается и шифруется при первом сохранении', () async {
    await File(AppPaths.stateFile).writeAsString('{"subscriptions":[{"id":"s1","url":"$url","name":"Test"}],'
        '"servers":[{"id":"a","name":"A","protocol":"vless","address":"1.1.1.1","port":443,"link":"vless://x",'
        '"outbound":{},"subscriptionId":"s1"}]}');
    final state = AppState();
    await state.loadForTest();
    expect((state.subscriptions.single.url, state.servers.single.name), (url, 'A'));
    await state.saveNow();
    expect(File(AppPaths.stateFile).readAsStringSync(), isNot(contains('SECRET-TOKEN')));
  });

  test('файл, зашифрованный для другой учётной записи: подписки не читаются, копия сохраняется', () async {
    await File(AppPaths.stateFile)
        .writeAsString(jsonEncode({'settings': {'killSwitch': true}, 'protected': base64Encode(utf8.encode('чужое'))}));
    final state = AppState();
    await state.loadForTest();
    expect(state.protectedUnreadable, isTrue);
    expect(state.subscriptions, isEmpty);
    // Настройки при этом читаются, а зашифрованная часть не пропадает.
    expect(state.settings.killSwitch, isTrue);
    expect(File('${AppPaths.stateFile}.locked').existsSync(), isTrue);
  });

  test('экспорт и импорт переносят всё; негодный файл ничего не портит', () async {
    final state = filled();
    final path = await state.exportData(tmp.path);
    // Файл экспорта — открытый: его и переносят на другой компьютер.
    expect(File(path).readAsStringSync(), contains('SECRET-TOKEN'));

    final other = AppState();
    expect(await other.importData(path), isNull);
    expect(other.subscriptions.single.url, url);
    expect(other.servers.single.name, 'Germany');
    expect(other.settings.killSwitch, isTrue);
    // Импортированное сразу сохранено зашифрованным.
    expect(File(AppPaths.stateFile).readAsStringSync(), isNot(contains('SECRET-TOKEN')));

    final junk = File('${tmp.path}\\junk.json')..writeAsStringSync('{"hello": 1}');
    expect(await other.importData(junk.path), 'Это не файл настроек SkipIt');
    final broken = File('${tmp.path}\\broken.json')
      ..writeAsStringSync('{"settings": {}, "subscriptions": [{"id": 5, "url": 7}], "servers": "x"}');
    expect(await other.importData(broken.path), isNotNull);
    expect(other.subscriptions.single.url, url);
    expect(other.servers.single.name, 'Germany');
  });

  for (final section in SettingsImportSection.values) {
    test('частичный импорт: ${section.name}', () async {
      final source = filled();
      final sourceProfile = RoutingProfile(name: 'Source', subscriptionId: source.subscriptions.single.id);
      source.routingProfiles.add(sourceProfile);
      source.settings.selectedRoutingId = sourceProfile.id;
      source.appRules.entries.add(AppEntry(match: 'source.exe', label: 'Source'));
      final path = await source.exportData(tmp.path);

      final target = AppState();
      final targetSub = Subscription(url: 'https://other.example/sub', name: 'Target');
      final targetServer = LinkParser.parseText('trojan://PASSWORD@other.example:443#Target').servers.single
        ..subscriptionId = targetSub.id;
      final targetProfile = RoutingProfile(name: 'Target', subscriptionId: targetSub.id);
      target.subscriptions.add(targetSub);
      target.servers.add(targetServer);
      target.routingProfiles.addAll([RoutingProfile.global(), targetProfile]);
      target.appRules.entries.add(AppEntry(match: 'target.exe', label: 'Target'));
      target.settings
        ..selectedServerId = targetServer.id
        ..selectedRoutingId = targetProfile.id
        ..lastXrayPid = 1234;

      final preview = (await SettingsImport.read(path)).data!;
      expect(target.subscriptions.single, same(targetSub));
      expect(target.routingProfiles.last, same(targetProfile));
      // После предпросмотра файл мог измениться. Применяется прочитанный снимок.
      await File(path).writeAsString('{}');
      expect(await target.applyImport(preview, {section}), isNull);

      final importedSubs = section == SettingsImportSection.subscriptions;
      final importedRoutes = section == SettingsImportSection.routing;
      final importedSettings = section == SettingsImportSection.settings;
      expect(target.subscriptions.single.id, importedSubs ? source.subscriptions.single.id : targetSub.id);
      expect(target.servers.single.id, importedSubs ? source.servers.single.id : targetServer.id);
      expect(target.settings.selectedServerId, target.servers.single.id);
      expect(target.routingProfiles.last.id, importedRoutes ? sourceProfile.id : targetProfile.id);
      expect(target.settings.selectedRoutingId, target.routingProfiles.last.id);
      expect(target.routingProfiles.last.subscriptionId, importedSubs || importedRoutes ? null : targetSub.id);
      expect(target.settings.killSwitch, importedSettings);
      expect(target.settings.lastXrayPid, 1234);
      expect(target.appRules.entries.single.match, importedSettings ? 'source.exe' : 'target.exe');

      final reloaded = AppState();
      await reloaded.loadForTest();
      expect(reloaded.subscriptions.single.id, target.subscriptions.single.id);
      expect(reloaded.routingProfiles.last.id, target.routingProfiles.last.id);
      expect(reloaded.appRules.entries.single.match, target.appRules.entries.single.match);
      source.dispose();
      target.dispose();
      reloaded.dispose();
    });
  }

  test('старый файл без профилей и повреждённая зашифрованная часть', () async {
    final file = File('${tmp.path}\\legacy.json');
    await file.writeAsString('{"settings":{},"subscriptions":[],"servers":[]}');
    final preview = (await SettingsImport.read(file.path)).data!;
    expect(preview.sections, isNot(contains(SettingsImportSection.routing)));

    await file.writeAsString('{"settings":{},"protected":"!not-base64!"}');
    final broken = await SettingsImport.read(file.path);
    expect(broken.data, isNull);
    expect(broken.error, 'Файл настроек повреждён');
  });

  test('ядро получает конфиг напрямую, без файла на диске', () async {
    final xray = File('core/skipit-xray.exe');
    if (!xray.existsSync()) return;
    final log = LogBuffer();
    final core = CoreProcess('xray', log);
    const config = '{"log":{"loglevel":"warning"},"inbounds":[{"tag":"s","protocol":"socks","listen":"127.0.0.1",'
        '"port":28941,"settings":{"auth":"noauth"}}],"outbounds":[{"tag":"direct","protocol":"freedom"}]}';
    await core.start(xray.absolute.path, ['run', '-c', 'stdin:'], input: config);
    final ok = await waitForPort(28941, alive: () => core.running);
    await core.stop();
    expect(ok, isTrue, reason: log.tail(8));
  });
}
