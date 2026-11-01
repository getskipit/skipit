import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/core/rule_list.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/state/app_state.dart';

void main() {
  test('BOM, дубликаты и domain payload сохраняют смысл записей', () {
    final plain = RuleList.parse('\uFEFFExample.com\nexample.com\n203.0.113.5\n203.0.113.5\n');
    expect(plain.domains, ['domain:example.com']);
    expect(plain.ips, ['203.0.113.5']);
    final yaml = RuleList.parse("payload:\n  - '+.example.com'\n  - IP-CIDR,203.0.113.0/24,no-resolve\nrules:\n  - DOMAIN,ignored.example\n");
    expect(yaml.domains, ['domain:example.com']);
    expect(yaml.ips, ['203.0.113.0/24']);
  });

  test('несовместимые регулярные выражения и некорректные адреса не попадают в Xray', () {
    final parsed = RuleList.parse('regexp:(?=x)\n999.999.999.999\n-bad.example\nfoo..example\n');
    expect(parsed.domains, isEmpty);
    expect(parsed.skipped, 4);
    expect(RuleList.validUrl('file:///C:/rules.txt'), isFalse);
    expect(RuleList.validUrl('https://user:password@rules.example/list'), isFalse);
  });

  test('id импортированного профиля не может превратиться в путь кэша', () {
    expect(RuleList.cacheFile('../../outside', 'https://rules.example/list'), matches(r'^[a-f0-9]{16}\.txt$'));
  });

  group('загрузка', () {
    late Directory tmp;
    late AppState state;
    late HttpServer server;
    late RuleListSource source;
    setUp(() async {
      await AppPaths.init();
      tmp = await Directory.systemTemp.createTemp('skipit-rule-rewrite');
      AppPaths.dataDir = tmp;
      state = AppState();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      source = RuleListSource(url: 'http://127.0.0.1:${server.port}/list');
    });
    tearDown(() async {
      await server.close(force: true);
      await state.saveNow();
      state.dispose();
      for (var i = 0; i < 10; i++) {
        try { await tmp.delete(recursive: true); break; }
        on FileSystemException { await Future<void>.delayed(const Duration(milliseconds: 100)); }
      }
    });

    test('одновременные обновления делают один запрос и обновляют обе модели', () async {
      var requests = 0;
      server.listen((request) async {
        requests++;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        request.response.write('example.com\n');
        await request.response.close();
      });
      final other = RuleListSource(url: source.url);
      expect(await Future.wait([
        state.downloadRuleListSource('test', source), state.downloadRuleListSource('test', other),
      ]), [true, true]);
      expect(requests, 1);
      expect(other.count, 1);
      expect(other.updatedAt, isNotNull);
      expect(RuleList.readEntries(RoutingProfile(id: 'test', name: '', ruleLists: [source])).proxyDomains,
          ['domain:example.com']);
    });

    test('превышение размера обрывает поток, прежний файл и дата сохраняются', () async {
      var large = false;
      server.listen((request) async {
        if (!large) {
          request.response.write('example.com');
        } else {
          request.response.add(List.filled(RuleList.maxBytes + 1, 65));
        }
        try { await request.response.close(); } on SocketException { /* Клиент прервал загрузку. */ }
      });
      expect(await state.downloadRuleListSource('test', source), isTrue);
      final date = source.updatedAt;
      large = true;
      expect(await state.downloadRuleListSource('test', source), isFalse);
      expect(File(RuleList.path('test', source.url)).readAsStringSync(), 'domain:example.com');
      expect(source.updatedAt, date);
      expect(tmp.listSync(recursive: true).whereType<File>().any((f) => f.path.endsWith('.part')), isFalse);
    });

    test('HTML с доменом в отдельной строке не становится списком', () async {
      server.listen((r) => r.response..write('<html>\nexample.com\n</html>')..close());
      expect(await state.downloadRuleListSource('test', source), isFalse);
      expect(File(RuleList.path('test', source.url)).existsSync(), isFalse);
    });

    test('повреждённый кэш не приводит к подключению без правил', () async {
      final file = File(RuleList.path('test', source.url));
      await file.parent.create(recursive: true);
      await file.writeAsString('<html>not a list</html>');
      final profile = RoutingProfile(id: 'test', name: '', ruleLists: [source]);
      await expectLater(RuleList.readEntriesAsync(profile), throwsFormatException);
    });

    test('переадресация на список работает', () async {
      server.listen((r) {
        if (r.uri.path == '/list') {
          r.response.statusCode = 302;
          r.response.headers.set('location', '/actual');
        } else { r.response.write('example.com'); }
        r.response.close();
      });
      expect(await state.downloadRuleListSource('test', source), isTrue);
    });
  });
}
