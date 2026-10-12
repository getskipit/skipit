import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/log_store.dart';
import 'package:skipit/core/site_check.dart';

/// Проверка сайта («Почему тормозит?»): разбор введённого адреса и вывод словами по замерам.
void main() {
  test('адрес сайта: без https://, пути и порта; не имя — отказ', () {
    expect(SiteCheck.hostOf(' https://Site.Example/page?x=1 '), 'site.example');
    expect(SiteCheck.hostOf('www.site.example:8443'), 'www.site.example');
    expect(SiteCheck.hostOf('site.example'), 'site.example');
    expect(SiteCheck.hostOf('http://site.example./'), 'site.example');
    // Кириллическое имя уходит в сеть в латинской записи, а показывается как вписано.
    expect(SiteCheck.hostOf('Пример.Испытание'), 'xn--e1afmkfd.xn--80akhbyknj4f');
    expect(SiteCheck.hostOf('https://президент.рф/новости'), 'xn--d1abbgf6aiiy.xn--p1ai');
    expect(SiteCheck.hostOf('bücher.example'), 'xn--bcher-kva.example');
    expect(SiteCheck.hostOf('xn--e1afmkfd.xn--p1ai'), 'xn--e1afmkfd.xn--p1ai');
    expect(SiteCheck.nameOf('Президент.РФ')!.shown, 'президент.рф');
    expect(SiteReport('xn--d1abbgf6aiiy.xn--p1ai', shown: 'президент.рф').copyText, startsWith('президент.рф — '));
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
        'адрес от DNS подключения напрямую 55 мс');

    final far = report(ConnRoute.direct)
      ..firstMs = 700
      ..warmMs = 650
      ..replyMs = 240
      ..addressMs = 220
      ..otherMs = 55;
    expect(far.farAddress, isTrue);
    expect(far.notes.single.text, contains('DNS подключения назвал далёкий адрес: до него 220 мс'));
    // Адреса разные — в тексте для копирования оба, каждый со своим временем.
    far
      ..address = '203.0.113.52'
      ..otherAddress = '203.0.113.78';
    expect(far.summary, contains('адрес от DNS подключения 203.0.113.52 напрямую 220 мс, адрес от Google DNS 203.0.113.78 55 мс'));

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
    expect(slowDns.notes.single.kind, SiteNoteKind.warn);

    // Недолгий поиск адреса — к сведению, а не причина: повторная проверка его уже не покажет,
    // и вывод у обеих должен быть один — «задержек не видно».
    final firstRun = report(ConnRoute.direct)
      ..firstMs = 620
      ..warmMs = 120
      ..replyMs = 90;
    expect(kinds(firstRun), [SiteNoteKind.info, SiteNoteKind.ok]);
    // Повторное соединение ушло к другому адресу сайта и вышло дольше первого: дорога — лучшее из двух.
    final otherAddress = report(ConnRoute.direct)
      ..firstMs = 19
      ..warmMs = 117
      ..replyMs = 62;
    expect(otherAddress.notes.single.text, 'Задержек по дороге не видно: соединение 19 мс, ответ сайта 62 мс');
  });

  test('вывод: сайт через VPN сравнивается с проверочным адресом через тот же сервер', () {
    final usual = report(ConnRoute.proxy)
      ..firstMs = 260
      ..warmMs = 190
      ..replyMs = 150
      ..vpnSiteMs = 190
      ..vpnBaseMs = 170;
    expect(usual.notes.single.text,
        'Задержек по дороге не видно: соединение 190 мс — обычное время пути через VPN-сервер, ответ сайта 150 мс');
    // Проверочный адрес ответил дольше сайта — это всплеск на дороге, а не повод для вывода.
    expect(kinds(usual..vpnBaseMs = 420), [SiteNoteKind.ok]);

    // Сайт и проверочный адрес шли разными выходами ядра (у провайдера их несколько): сравнивать нечего,
    // и долгое соединение само по себе выводом «сайт далеко» не становится.
    final otherPath = report(ConnRoute.proxy)
      ..firstMs = 257
      ..warmMs = 250
      ..replyMs = 108;
    expect(otherPath.notes.single.text, 'Задержек по дороге не видно: соединение 250 мс, ответ сайта 108 мс');

    final distant = report(ConnRoute.proxy)
      ..firstMs = 700
      ..warmMs = 640
      ..replyMs = 300
      ..vpnSiteMs = 640
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
