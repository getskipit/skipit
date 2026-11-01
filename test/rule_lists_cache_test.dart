import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/rule_list.dart';
import 'package:skipit/models/routing.dart';

void main() {
  group('RuleList кэш', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('rulelist-test');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    RoutingProfile profile() => RoutingProfile(
          id: 'p1',
          name: 'Тест',
          ruleLists: [
            RuleListSource(url: 'https://rules.example/a.txt', action: 'proxy'),
            RuleListSource(url: 'https://rules.example/b.txt', action: 'block'),
            RuleListSource(url: 'https://rules.example/missing.txt', action: 'direct'),
          ],
        );

    void cache(String profileId, String url, String content) =>
        File('${dir.path}\\${RuleList.cacheFile(profileId, url)}').writeAsStringSync(content);

    test('readEntries раскладывает записи по действиям; без файла — пропуск', () {
      cache('p1', 'https://rules.example/a.txt', 'example.com\n203.0.113.5');
      cache('p1', 'https://rules.example/b.txt', 'geosite:category-ads-all');
      final e = RuleList.readEntries(profile(), dir: dir.path);
      expect(e.proxyDomains, ['domain:example.com']);
      expect(e.proxyIps, ['203.0.113.5']);
      expect(e.blockDomains, ['geosite:category-ads-all']);
      expect(e.directDomains, isEmpty);
      expect(e.isEmpty, isFalse);
    });

    test('needsGeo true, когда в кэше есть geosite:/geoip:', () {
      cache('p1', 'https://rules.example/a.txt', 'example.com');
      expect(RuleList.needsGeo(profile(), dir: dir.path), isFalse);
      cache('p1', 'https://rules.example/b.txt', 'geoip:ru');
      expect(RuleList.needsGeo(profile(), dir: dir.path), isTrue);
    });

    test('cleanOrphans удаляет файлы без ссылок из профилей', () {
      cache('p1', 'https://rules.example/a.txt', 'example.com');
      cache('p1', 'https://rules.example/old.txt', 'old.example');
      cache('ghost', 'https://rules.example/x.txt', 'x.example');
      RuleList.cleanOrphans([profile()], dir: dir.path);
      expect(File('${dir.path}\\${RuleList.cacheFile('p1', 'https://rules.example/a.txt')}').existsSync(), isTrue);
      expect(File('${dir.path}\\${RuleList.cacheFile('p1', 'https://rules.example/old.txt')}').existsSync(), isFalse);
      expect(File('${dir.path}\\${RuleList.cacheFile('ghost', 'https://rules.example/x.txt')}').existsSync(), isFalse);
    });
  });
}
