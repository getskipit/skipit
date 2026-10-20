import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/pac.dart';
import 'package:skipit/core/windows.dart';

/// «Смешанный» через файл автонастройки прокси: текст файла, сервер и свой адрес в настройках Windows.
void main() {
  test('всё через HTTP-порт ядра, исключения — напрямую', () {
    final s = PacServer.script(10809, '*.example;192.168.*;<local>');
    expect(s, contains('function FindProxyForURL(url, host)'));
    expect(s, contains('shExpMatch(host, "*.example")'));
    expect(s, contains('shExpMatch(host, "192.168.*")'));
    expect(s, contains('isPlainHostName(host)'));
    expect(s, contains('return "DIRECT"'));
    expect(s, contains('return "PROXY 127.0.0.1:10809; DIRECT"'));
  });

  test('без своих исключений — стандартный список Windows', () {
    final s = PacServer.script(10809, '');
    expect(s, contains('shExpMatch(host, "127.*")'));
    expect(s, contains('shExpMatch(host, "localhost")'));
  });

  test('кавычки в исключениях не ломают файл', () {
    expect(PacServer.script(10809, 'a"b.example'), contains(r'shExpMatch(host, "a\"b.example")'));
  });

  test('сервер отдаёт файл на 127.0.0.1', () async {
    final pac = await PacServer.start('function FindProxyForURL(url, host) { return "DIRECT"; }');
    addTearDown(pac.stop);
    expect(PacServer.isOwn(pac.url), isTrue);
    expect(PacServer.portOf(pac.url), isNotNull);
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    addTearDown(client.close);
    final r = await (await client.getUrl(Uri.parse(pac.url))).close();
    expect(r.statusCode, 200);
    expect(r.headers.contentType?.mimeType, 'application/x-ns-proxy-autoconfig');
    expect(await r.transform(const SystemEncoding().decoder).join(), contains('FindProxyForURL'));
  });

  test('свой адрес отличается от чужого', () {
    expect(PacServer.isOwn('http://127.0.0.1:50123/skipit.pac?abc'), isTrue);
    expect(PacServer.isOwn('http://proxy.example/wpad.dat'), isFalse);
    expect(PacServer.isOwn('http://127.0.0.1:8080/other.pac'), isFalse);
    expect(PacServer.portOf('http://proxy.example/wpad.dat'), isNull);
  });

  test('прежний файл автонастройки запоминается; у старых записей — «не знаем»', () {
    final s = SystemProxyState(enabled: false, autoConfig: 'http://proxy.example/wpad.dat');
    expect(SystemProxyState.fromJson(s.toJson()).autoConfig, 'http://proxy.example/wpad.dat');
    expect(SystemProxyState.fromJson({'enabled': true, 'server': '127.0.0.1:3128'}).autoConfig, isNull);
  });
}
