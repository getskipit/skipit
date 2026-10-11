import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/log_store.dart';
import 'package:skipit/core/site_check.dart';

/// Проверка сайта («Почему тормозит?»): разбор введённого адреса и вывод словами по замерам.
void main() {
  test('адрес сайта: без https://, пути и порта; не имя — отказ', () {
    expect(SiteCheck.hostOf(' https://Site.Example/page?x=1 '), 'site.example');
    expect(SiteCheck.hostOf('www.site.example:8443'), 'www.site.example');
    expect(SiteCheck.hostOf('site.example'), 'site.example');
    for (final wrong in ['', 'localhost', '203.0.113.7', 'просто слова', 'site .example', '-a.example']) {
      expect(SiteCheck.hostOf(wrong), isNull, reason: wrong);
    }
  });

  SiteReport report(ConnRoute? route) => SiteReport('site.example')
    ..done = true
    ..route = route;
  List<SiteNoteKind> kinds(SiteReport r) => [for (final n in r.notes) n.kind];

  test('вывод: всё в порядке, далёкий адрес от DNS, медленный сайт, долгий поиск адреса', () {
    final fine = report(ConnRoute.direct)
      ..firstMs = 180
      ..warmMs = 120
      ..replyMs = 90
      ..addressMs = 55
      ..otherMs = 52;
    expect(kinds(fine), [SiteNoteKind.ok]);
    expect(fine.summary, 'напрямую, соединение 180 мс, повторное 120 мс, ответ сайта 90 мс, '
        'адрес от DNS ядра мимо VPN 55 мс, адрес от независимого DNS 52 мс');

    final far = report(ConnRoute.direct)
      ..firstMs = 700
      ..warmMs = 650
      ..replyMs = 240
      ..addressMs = 220
      ..otherMs = 55;
    expect(far.farAddress, isTrue);
    expect(far.notes.single.text, contains('DNS назвал далёкий адрес: до него 220 мс'));

    final slowSite = report(ConnRoute.direct)
      ..firstMs = 130
      ..warmMs = 120
      ..replyMs = 4200;
    expect(slowSite.notes.single.text, contains('Сайт сам долго отвечает: 4200 мс'));

    final slowDns = report(ConnRoute.direct)
      ..firstMs = 1700
      ..warmMs = 120
      ..replyMs = 90;
    expect(slowDns.notes.single.text, contains('на 1580 мс дольше повторного'));
  });

  test('вывод: сайт через VPN сравнивается с проверочным адресом через тот же сервер', () {
    final usual = report(ConnRoute.proxy)
      ..firstMs = 260
      ..warmMs = 190
      ..replyMs = 150
      ..vpnBaseMs = 170;
    expect(kinds(usual), [SiteNoteKind.info, SiteNoteKind.ok]);
    expect(usual.notes.first.text, contains('столько занимает сам путь через VPN-сервер'));

    final distant = report(ConnRoute.proxy)
      ..firstMs = 700
      ..warmMs = 640
      ..replyMs = 300
      ..vpnBaseMs = 170;
    expect(distant.notes.single.text, contains('Сайт далеко от VPN-сервера'));
  });

  test('вывод: сайт не открылся или заблокирован правилом', () {
    final blocked = report(ConnRoute.block)..error = 'соединение закрылось, не успев установиться';
    expect(blocked.notes.single.kind, SiteNoteKind.bad);
    expect(blocked.notes.single.text, contains('заблокирован правилом'));

    final dead = report(ConnRoute.direct)
      ..error = 'нет ответа за 8 с'
      ..addressMs = 60;
    expect(kinds(dead), [SiteNoteKind.bad, SiteNoteKind.info]);
    expect(dead.notes.first.text, 'Этим путём сайт не открылся: нет ответа за 8 с');

    // Соединение есть, а ответа на запрос нет.
    final silent = report(ConnRoute.proxy)
      ..firstMs = 200
      ..warmMs = 190;
    expect(silent.notes.single.text, contains('на запрос сайт не ответил'));
  });
}
