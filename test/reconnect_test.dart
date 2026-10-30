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

  test('«Нет связи» после сна или смены сети: перезапуск сразу, без 20 с ожидания, но не чаще раза в 5 минут', () {
    final down = DateTime(2026, 10, 1, 12);
    bool heal(int seconds, {required int changedAgo, DateTime? last}) {
      final now = down.add(Duration(seconds: seconds));
      return AppState.shouldHeal(
          downSince: down, now: now, lastHeal: last, netChangedAt: now.subtract(Duration(seconds: changedAgo)));
    }

    expect(heal(0, changedAgo: 2), isTrue);
    expect(heal(5, changedAgo: 50), isTrue);
    // Сеть менялась давно — снова обычные 20 с.
    expect(heal(5, changedAgo: 120), isFalse);
    expect(heal(0, changedAgo: 2, last: down.subtract(const Duration(minutes: 1))), isFalse);
  });

  test('падение ядра: повторы через 3 с, 30 с, 2 мин, после четвёртого за 10 минут — нет', () {
    const ok = Duration(minutes: 1);
    expect(AppState.crashRetryDelay(1, uptime: ok), const Duration(seconds: 3));
    expect(AppState.crashRetryDelay(2, uptime: ok), const Duration(seconds: 30));
    expect(AppState.crashRetryDelay(3, uptime: ok), const Duration(minutes: 2));
    expect(AppState.crashRetryDelay(4, uptime: ok), isNull);
  });

  test('падение ядра меньше чем через 30 с работы — не повторяем', () {
    expect(AppState.crashRetryDelay(1, uptime: const Duration(seconds: 5)), isNull);
    expect(AppState.crashRetryDelay(1, uptime: const Duration(seconds: 29)), isNull);
    expect(AppState.crashRetryDelay(1, uptime: const Duration(seconds: 30)), const Duration(seconds: 3));
  });

  test('падение без повтора не засчитывается: следующий повтор — через 3 с, а не через 30', () {
    final times = <DateTime>[];
    final t0 = DateTime(2026, 1, 1, 12);
    // Ядро закрылось через 21 с работы — повтора нет, и в счёт падение не идёт.
    expect(AppState.countCrash(times, t0, const Duration(seconds: 21)), isNull);
    expect(times, isEmpty);
    // Через две минуты закрылось после 104 с работы — это первое засчитанное падение.
    expect(AppState.countCrash(times, t0.add(const Duration(minutes: 2)), const Duration(seconds: 104)),
        const Duration(seconds: 3));
    expect(AppState.countCrash(times, t0.add(const Duration(minutes: 4)), const Duration(minutes: 1)),
        const Duration(seconds: 30));
    // Падения старше 10 минут забываются.
    expect(AppState.countCrash(times, t0.add(const Duration(minutes: 20)), const Duration(minutes: 1)),
        const Duration(seconds: 3));
  });
}
