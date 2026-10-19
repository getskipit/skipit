import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/service_client.dart';
import 'package:skipit/models/app_rules.dart';
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

  test('«мимо ядра»: подсети правила — после табуляции', () {
    expect(
        ServiceBypass.request('172.19.0.1', ['Example', 'Other'], {
          'Example': ['203.0.113.0/24', '198.51.100.0/24'],
        }),
        'bypass\n172.19.0.1\nExample\t203.0.113.0/24 198.51.100.0/24\nOther');
  });

  test('подсети запоминаются /24, свежие в конце, без повторов, не больше предела', () {
    final e = AppEntry(match: 'Example', label: 'Example');
    expect(e.rememberNet('203.0.113.7'), isTrue);
    expect(e.rememberNet('203.0.113.200'), isFalse);
    expect(e.rememberNet('198.51.100.1'), isTrue);
    expect(e.rememberNet('203.0.113.9'), isTrue);
    expect(e.nets, ['198.51.100.0/24', '203.0.113.0/24']);
    for (var i = 0; i < AppEntry.maxNets + 5; i++) {
      e.rememberNet('10.${i ~/ 256}.${i % 256}.1');
    }
    expect(e.nets.length, AppEntry.maxNets);
    expect(AppEntry.fromJson(e.toJson()).nets, e.nets);
  });

  test('запомненные подсети уходят службе, только пока программа в списке «напрямую» и включена', () {
    final on = AppEntry(match: 'Example', label: 'Example', nets: ['203.0.113.0/24']);
    final off = AppEntry(match: 'Other', label: 'Other', enabled: false, nets: ['198.51.100.0/24']);
    final rules = AppRules(mode: AppRoutingMode.allExcept, entries: [on, off]);
    expect(rules.directNets, {'Example': ['203.0.113.0/24']});
    rules.mode = AppRoutingMode.onlySelected;
    expect(rules.directNets, isEmpty);
    rules.mode = AppRoutingMode.off;
    expect(rules.directNets, isEmpty);
  });

  test('ядро TUN по умолчанию — Xray, выбор «SkipIt» сохраняется', () {
    expect(AppSettings().tunCore, TunCore.xray);
    final skipit = AppSettings()..tunCore = TunCore.skipit;
    expect(AppSettings.fromJson(skipit.toJson()).tunCore, TunCore.skipit);
  });
}
