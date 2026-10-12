import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/line_check.dart';
import 'package:skipit/core/site_check.dart';
import 'package:skipit/core/speed_test.dart';

/// Раздел «Проверка»: несколько сайтов разом, стабильность связи и замер скорости — разбор ввода,
/// подсчёт и выводы словами, без выхода в сеть.
void main() {
  test('несколько сайтов: через запятую с пробелом и без, с новой строки; без повторов', () {
    List<String>? hosts(String input) => SiteCheck.hostsOf(input)?.map((n) => n.host).toList();
    expect(hosts('site.example, shop.example'), ['site.example', 'shop.example']);
    expect(hosts('site.example,shop.example'), ['site.example', 'shop.example']);
    expect(hosts(' https://site.example/a ;shop.example\nsite.example , '), ['site.example', 'shop.example']);
    expect(hosts('site.example'), ['site.example']);
    // Одно неверное имя — отказ целиком: молча пропустить его значило бы проверить не то, что просили.
    expect(SiteCheck.hostsOf('site.example, не сайт'), isNull);
    expect(SiteCheck.hostsOf(' , '), isNull);
    expect(SiteCheck.hostsOf([for (var i = 0; i <= SiteCheck.maxHosts; i++) 's$i.example'].join(',')), isNull);
  });

  test('подпись под результатом: название сервера — да, его адрес — нет', () {
    const known = ['vpn.example', '203.0.113.40'];
    expect(SiteCheck.stampServer('Finland', known), 'Finland');
    expect(SiteCheck.stampServer('Russia - 1 [Сотовая связь]', known), 'Russia - 1 [Сотовая связь]');
    // Сервер без названия называется своим адресом — в подпись он не идёт.
    for (final name in ['vpn.example:443', '203.0.113.40:8443', '203.0.113.40', 'Мой vpn.example', 'other.example:2096']) {
      expect(SiteCheck.stampServer(name, known), '', reason: name);
    }
  });

  test('стабильность: пробный пакет и ответ на него, потери, всплески и самая длинная череда потерь', () {
    final request = LineCheck.request(321);
    expect(request.length, 20);
    expect(LineCheck.replyNumber(request), 321);
    expect(LineCheck.replyNumber(Uint8List(20)), isNull);
    expect(LineCheck.replyNumber(Uint8List(8)), isNull);

    final path = LineCheck.path([60, 61, null, null, null, 62, 250, 60, null, 61]);
    expect(path.sent, 10);
    expect(path.lost, 4);
    expect(path.longestGap, 3);
    expect(path.usual, 61);
    expect(path.worst, 250);
    expect(path.spikes, 1);
    expect(path.rough, isTrue);
    expect(LineCheck.path(List.filled(200, 60)).rough, isFalse);
    // Один всплеск на двести ответов — не «неровная связь».
    expect(LineCheck.path([...List.filled(199, 60), 400]).rough, isFalse);
    expect(LineCheck.path(List<int?>.filled(50, null)).silent, isTrue);
  });

  test('стабильность: вывод — где портится связь', () {
    final even = LineCheck.path(List.filled(300, 60));
    final spiky = LineCheck.path([...List.filled(280, 90), ...List.filled(20, 240)]);
    final lossy = LineCheck.path([...List.filled(270, 60), ...List<int?>.filled(30, null)]);

    final fine = LineReport()
      ..vpn = even
      ..direct = even;
    expect(fine.notes.single.text, 'Связь ровная и через VPN, и напрямую');

    final vpnRough = LineReport()
      ..vpn = spiky
      ..direct = even;
    expect(vpnRough.notes.single.kind, SiteNoteKind.warn);
    expect(vpnRough.notes.single.text, contains('неровность даёт путь до VPN-сервера или сам сервер'));

    final lineRough = LineReport()
      ..vpn = spiky
      ..direct = lossy;
    expect(lineRough.notes.single.text, contains('дело в вашей линии или интернет-провайдере, а не в VPN'));

    // Напрямую не меряли (Kill Switch): неровность видна, но чья она — сказать нельзя.
    final unknown = LineReport()
      ..vpn = spiky
      ..directSkipped = 'включён Kill Switch — напрямую пакеты не выпускаются';
    expect([for (final n in unknown.notes) n.kind], [SiteNoteKind.info, SiteNoteKind.warn]);
    expect(unknown.notes.first.text, 'Напрямую не измерялось: включён Kill Switch — напрямую пакеты не выпускаются');
    expect(unknown.notes.last.text, contains('не видно, чья это неровность'));
    expect(unknown.copyText, contains('напрямую: включён Kill Switch'));
    // Ровная связь через VPN при Kill Switch: причина пропуска и зелёный итог.
    final guarded = LineReport()
      ..vpn = even
      ..directSkipped = 'включён Kill Switch — напрямую пакеты не выпускаются';
    expect([for (final n in guarded.notes) n.kind], [SiteNoteKind.info, SiteNoteKind.ok]);

    // Сервер не пропускает пробные пакеты: это не «всё потеряно», а «не измерено».
    final silent = LineReport()
      ..vpn = LineCheck.path(List<int?>.filled(100, null))
      ..direct = even;
    expect([for (final n in silent.notes) n.kind], [SiteNoteKind.info, SiteNoteKind.ok]);
    expect(silent.notes.last.text, 'Связь ровная напрямую; другой путь не измерялся');
  });

  test('проверку прерывает отключение VPN: замер останавливается, а не выдаёт потери за плохую связь', () async {
    // Стабильность: после пяти пакетов подключение «пропало» — дальше пакеты не идут, итог — «прерван».
    var sent = 0;
    final line = LineReport();
    final watch = Stopwatch()..start();
    await LineCheck.run(line,
        server: InternetAddress.loopbackIPv4, viaVpn: true, count: 200, keepGoing: () => ++sent <= 5);
    expect(line.stopped, isTrue);
    expect(line.done, isTrue);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    expect(line.notes.single.kind, SiteNoteKind.bad);
    expect(line.notes.single.text, 'Замер прерван: VPN отключился или переподключился');

    // Сайт: то же самое словами, без «сайт не открылся».
    final site = SiteReport('site.example')
      ..done = true
      ..stopped = true
      ..firstMs = 120;
    expect(site.notes.single.text, 'Проверка прервана: VPN отключился или переподключился');
    expect(site.copyText, 'site.example — проверка прервана: VPN отключился или переподключился\n'
        '  • Проверка прервана: VPN отключился или переподключился');
  });

  test('скорость: счёт без разгона и вывод — режет ли VPN', () {
    // 30 МБ за 6 с, из них 2 МБ за первую секунду разгона: считаются 28 МБ за 5 с.
    final speed = SpeedTest.mbit(
        total: 30 * 1000 * 1000, atWarmup: 2 * 1000 * 1000, elapsed: const Duration(seconds: 6));
    expect(speed, closeTo(44.8, 0.01));
    // Файл кончился раньше разгона — считается всё скачанное за всё время.
    expect(SpeedTest.mbit(total: 1000 * 1000, elapsed: const Duration(milliseconds: 500)), closeTo(16, 0.01));
    expect(SpeedReport.show(44.8), '45 Мбит/с');
    expect(SpeedReport.show(3.26), '3.3 Мбит/с');

    final same = SpeedReport()
      ..vpnMbit = 80
      ..directMbit = 95;
    expect(same.notes.single.kind, SiteNoteKind.ok);
    expect(same.notes.single.text, 'VPN скорость заметно не режет: 80 Мбит/с против 95 Мбит/с напрямую');
    // Через VPN быстрее, чем напрямую, — не ошибка замера: об этом сказано словами.
    final faster = SpeedReport()
      ..vpnMbit = 307
      ..directMbit = 144;
    expect(faster.notes.single.kind, SiteNoteKind.ok);
    expect(faster.notes.single.text, contains('вышло даже быстрее (307 Мбит/с против 144 Мбит/с напрямую)'));
    final cut = SpeedReport()
      ..vpnMbit = 20
      ..directMbit = 95;
    expect(cut.notes.single.text, contains('меньше половины'));
    final onlyVpn = SpeedReport()
      ..vpnMbit = 20
      ..directError = 'включён Kill Switch';
    expect(onlyVpn.notes.single.text, 'Через VPN — 20 Мбит/с. Напрямую не измерялось: включён Kill Switch');
    final failed = SpeedReport()..vpnError = 'нет ответа за 8 с';
    expect(failed.notes.single.kind, SiteNoteKind.bad);
  });
}
