import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/state/app_state.dart';

void main() {
  test('«Нет связи»: перезапуск через 20 с без связи и не чаще раза в 5 минут', () {
    final down = DateTime(2026, 10, 1, 12);
    bool heal(int seconds, {DateTime? last}) =>
        AppState.shouldHeal(downSince: down, now: down.add(Duration(seconds: seconds)), lastHeal: last);
    expect(heal(5), isFalse);
    expect(heal(19), isFalse);
    expect(heal(20), isTrue);
    expect(heal(60), isTrue);
    // Прошлый перезапуск был 2 минуты назад — не помог, ждём.
    expect(heal(60, last: down.subtract(const Duration(minutes: 1))), isFalse);
    // А 6 минут назад — можно ещё раз.
    expect(heal(60, last: down.subtract(const Duration(minutes: 5))), isTrue);
  });

  test('падение ядра: повторы через 3 с, 30 с, 2 мин, после четвёртого за 10 минут — нет', () {
    expect(AppState.crashRetryDelay(1), const Duration(seconds: 3));
    expect(AppState.crashRetryDelay(2), const Duration(seconds: 30));
    expect(AppState.crashRetryDelay(3), const Duration(minutes: 2));
    expect(AppState.crashRetryDelay(4), isNull);
  });
}
