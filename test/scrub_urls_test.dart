import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/util.dart';

void main() {
  for (final url in [
    'https://rules.example?token=example-secret',
    'https://rules.example/list?token=public,example-secret',
    'https://rules.example/list?token=public;example-secret',
    'https://rules.example/list?token=public)example-secret',
    "https://rules.example/list?token=public'example-secret",
    'https://rules.example/list?token=public"example-secret',
    'https://user:example-secret@rules.example:8443/list',
  ]) {
    test('scrubUrls скрывает весь ключ: $url', () {
      final text = scrubUrls('Ошибка: $url');
      expect(text, isNot(contains('example-secret')));
      expect(text, contains('rules.example'));
      expect(text, isNot(contains('token=')));
    });
  }
}
