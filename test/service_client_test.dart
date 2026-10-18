import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/service_client.dart';

/// Службы нет — программа получает «нет ответа», а не ошибку и не зависание.
void main() {
  test('служба не установлена: hello() возвращает null', () async {
    expect(await ServiceClient.hello(serviceName: 'SkipItNoSuchService').timeout(const Duration(seconds: 5)), isNull);
  });
}
