import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/service_client.dart';
import 'package:skipit/models/settings.dart';

/// Службы нет — программа получает «нет ответа», а не ошибку и не зависание.
void main() {
  test('служба не установлена: hello() возвращает null', () async {
    expect(await ServiceClient.hello(serviceName: 'SkipItNoSuchService').timeout(const Duration(seconds: 5)), isNull);
  });

  test('«мимо ядра»: адрес адаптера и правила программ — по строке', () {
    expect(ServiceBypass.request('172.19.0.1', ['E:/Games/Example/game.exe', 'Example', 'C:/Games/Other/']),
        'bypass\n172.19.0.1\nE:/Games/Example/game.exe\nExample\nC:/Games/Other/');
  });

  test('«мимо ядра» включено по умолчанию и сохраняется', () {
    expect(AppSettings().directPastCore, isTrue);
    final off = AppSettings()..directPastCore = false;
    expect(AppSettings.fromJson(off.toJson()).directPastCore, isFalse);
  });
}
