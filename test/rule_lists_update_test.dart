import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/core/rule_list.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/state/app_state.dart';

/// Списки правил по ссылке: скачивание, кэш в папке rulesets и тихое обновление в фоне.
void main() {
  test('скачивание: записи считаются, кэш ложится в rulesets', () async {
    await AppPaths.init();
    final tmp = await Directory.systemTemp.createTemp('skipit-rulelists');
    AppPaths.dataDir = tmp;

    final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    srv.listen((r) => r.response
      ..write('example.com\ndomain:cdn.example.net\n203.0.113.7\n')
      ..close());

    final state = AppState();
    final profile = RoutingProfile(name: 'Тест', ruleLists: [
      RuleListSource(url: 'http://127.0.0.1:${srv.port}/list', action: 'proxy'),
    ]);
    final source = profile.ruleLists.single;

    final ok = await state.downloadRuleListSource(profile.id, source);
    expect(ok, isTrue, reason: state.log.lines.map((l) => l.text).join("; "));
    expect(source.count, 3);
    expect(source.updatedAt, isNotNull);
    final cache = File('${tmp.path}\\rulesets\\${RuleList.cacheFile(profile.id, source.url)}');
    expect(cache.existsSync(), isTrue);
    expect(cache.readAsStringSync(), contains('example.com'));

    await srv.close(force: true);
    await _cleanUp(state, tmp);
  });

  test('адрес отвечает ошибкой — старый кэш цел, в журнале предупреждение', () async {
    await AppPaths.init();
    final tmp = await Directory.systemTemp.createTemp('skipit-rulelists');
    AppPaths.dataDir = tmp;

    var down = false;
    final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    srv.listen((r) {
      if (down) r.response.statusCode = 404;
      r.response
        ..write('example.com\n')
        ..close();
    });

    final state = AppState();
    final profile = RoutingProfile(name: 'Тест', ruleLists: [
      RuleListSource(url: 'http://127.0.0.1:${srv.port}/list', action: 'direct'),
    ]);
    final source = profile.ruleLists.single;
    expect(await state.downloadRuleListSource(profile.id, source), isTrue);

    down = true;
    final before = source.updatedAt;
    expect(await state.downloadRuleListSource(profile.id, source), isFalse);
    expect(source.count, 1);
    expect(source.updatedAt, before);
    final cache = File('${tmp.path}\\rulesets\\${RuleList.cacheFile(profile.id, source.url)}');
    expect(cache.existsSync(), isTrue);
    expect(state.log.lines.any((l) => l.text.contains('Предупреждение')), isTrue);

    await srv.close(force: true);
    await _cleanUp(state, tmp);
  });

  test('список пора обновлять: кэша нет, записи старше недели', () {
    final now = DateTime.now();
    final s = RuleListSource(url: 'https://list.example/rules.txt', action: 'proxy');
    expect(RuleList.updateDue(s, cacheExists: false, now: now), isTrue);
    expect(RuleList.updateDue(s, cacheExists: true, now: now), isTrue);
    s.updatedAt = now.subtract(const Duration(days: 8));
    expect(RuleList.updateDue(s, cacheExists: true, now: now), isTrue);
    s.updatedAt = now.subtract(const Duration(days: 1));
    expect(RuleList.updateDue(s, cacheExists: true, now: now), isFalse);
  });

  test('список больше лимита строк — не сохраняется, старый кэш цел', () async {
    await AppPaths.init();
    final tmp = await Directory.systemTemp.createTemp('skipit-rulelists');
    AppPaths.dataDir = tmp;

    final big = StringBuffer();
    for (var i = 0; i <= RuleList.maxLines; i++) {
      big.writeln('host$i.example');
    }
    final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    srv.listen((r) => r.response
      ..write(big.toString())
      ..close());

    final state = AppState();
    final profile = RoutingProfile(name: 'Тест', ruleLists: [
      RuleListSource(url: 'http://127.0.0.1:${srv.port}/list', action: 'proxy'),
    ]);
    final source = profile.ruleLists.single;
    expect(await state.downloadRuleListSource(profile.id, source), isFalse);
    expect(source.count, 0);
    expect(
      File('${tmp.path}\\rulesets\\${RuleList.cacheFile(profile.id, source.url)}').existsSync(),
      isFalse,
    );

    await srv.close(force: true);
    await _cleanUp(state, tmp);
  });

  test('HTTP 200 с мусором вместо списка — старый кэш и дата не тронуты', () async {
    await AppPaths.init();
    final tmp = await Directory.systemTemp.createTemp('skipit-rulelists');
    AppPaths.dataDir = tmp;

    var junk = false;
    final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    srv.listen((r) => r.response
      ..write(junk ? '<html><body>404 Not Found</body></html>' : 'example.com\n')
      ..close());

    final state = AppState();
    final profile = RoutingProfile(name: 'Тест', ruleLists: [
      RuleListSource(url: 'http://127.0.0.1:${srv.port}/list', action: 'proxy'),
    ]);
    final source = profile.ruleLists.single;
    expect(await state.downloadRuleListSource(profile.id, source), isTrue);
    expect(source.count, 1);

    junk = true;
    final before = source.updatedAt;
    expect(await state.downloadRuleListSource(profile.id, source), isFalse);
    expect(source.count, 1);
    expect(source.updatedAt, before);
    final cache = File('${tmp.path}\\rulesets\\${RuleList.cacheFile(profile.id, source.url)}');
    expect(cache.readAsStringSync(), contains('example.com'));
    expect(state.log.lines.any((l) => l.text.contains('Предупреждение')), isTrue);

    await srv.close(force: true);
    await _cleanUp(state, tmp);
  });
}

/// Уборка после теста. Отложенная запись state.json (через 400 мс после изменения) иначе срабатывала
/// уже в следующем тесте и писала в его временную папку, а та не удалялась: файл открыт. [AppState.saveNow]
/// отменяет её и дописывает файл сейчас. Только что записанный файл Windows (антивирус, индексатор)
/// может ещё держать — папку удаляем с повторами; временную папку, которая так и не удалилась, не считаем ошибкой.
Future<void> _cleanUp(AppState state, Directory tmp) async {
  await state.saveNow();
  state.dispose();
  for (var attempt = 1; attempt <= 10; attempt++) {
    try {
      await tmp.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }
}
