import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/line_check.dart';
import 'package:skipit/core/site_check.dart';
import 'package:skipit/core/speed_test.dart';

/// Раздел «Проверка»: несколько сайтов разом, стабильность связи и замер скорости — разбор ввода,
/// подсчёт и выводы словами, без выхода в сеть.
void main() {
  test('несколько сайтов: через запятую с пробелом и без, с новой строки; без повторов', () {
    expect(SiteCheck.hostsOf('site.example, shop.example'), ['site.example', 'shop.example']);
    expect(SiteCheck.hostsOf('site.example,shop.example'), ['site.example', 'shop.example']);
    expect(SiteCheck.hostsOf(' https://site.example/a ;shop.example\nsite.example , '), ['site.example', 'shop.example']);
    expect(SiteCheck.hostsOf('site.example'), ['site.example']);
    // Одно неверное имя — отказ целиком: молча пропустить его значило бы проверить не то, что просили.
    expect(SiteCheck.hostsOf('site.example, не сайт'), isNull);
    expect(SiteCheck.hostsOf(' , '), isNull);
    expect(SiteCheck.hostsOf([for (var i = 0; i <= SiteCheck.maxHosts; i++) 's$i.example'].join(',')), isNull);
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
