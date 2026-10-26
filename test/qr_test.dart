import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/qr.dart';
import 'package:skipit/ui/qr_ui.dart';

/// Картинка кода: модуль — [scale] точек (можно дробно), вокруг белое поле в 4 модуля.
({Uint8List gray, int w, int h}) render(QrCode qr, {double scale = 4, bool inverted = false}) {
  final side = ((qr.size + 8) * scale).ceil();
  final gray = Uint8List(side * side);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final mx = (x / scale).floor() - 4, my = (y / scale).floor() - 4;
      final dark = mx >= 0 && my >= 0 && mx < qr.size && my < qr.size && qr.modules[my][mx];
      gray[y * side + x] = (dark != inverted) ? 20 : 235;
    }
  }
  return (gray: gray, w: side, h: side);
}

/// Поворот на 90° по часовой стрелке.
({Uint8List gray, int w, int h}) rotate(({Uint8List gray, int w, int h}) img) {
  final out = Uint8List(img.w * img.h);
  for (var y = 0; y < img.h; y++) {
    for (var x = 0; x < img.w; x++) {
      out[x * img.h + (img.h - 1 - y)] = img.gray[y * img.w + x];
    }
  }
  return (gray: out, w: img.h, h: img.w);
}

/// Код на большом «экране» с посторонним серым фоном.
({Uint8List gray, int w, int h}) onScreen(({Uint8List gray, int w, int h}) img, int w, int h, int ox, int oy) {
  final out = Uint8List(w * h)..fillRange(0, w * h, 60);
  for (var y = 0; y < img.h; y++) {
    for (var x = 0; x < img.w; x++) {
      out[(y + oy) * w + x + ox] = img.gray[y * img.w + x];
    }
  }
  return (gray: out, w: w, h: h);
}

List<String> decode(({Uint8List gray, int w, int h}) img) => QrDecoder.decode(img.gray, img.w, img.h);

const link = 'vless://00000000-0000-0000-0000-000000000000@203.0.113.10:443?encryption=none&security=reality'
    '&sni=www.example.com&fp=chrome&pbk=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCdE&sid=0123abcd&type=tcp'
    '&flow=xtls-rprx-vision#%F0%9F%87%A9%F0%9F%87%AA%20Германия';

void main() {
  test('ёмкость версий совпадает со стандартом', () {
    expect(qrDataCodewordsForTest(1, 'L'), 19);
    expect(qrDataCodewordsForTest(1, 'M'), 16);
    expect(qrDataCodewordsForTest(1, 'Q'), 13);
    expect(qrDataCodewordsForTest(1, 'H'), 9);
    expect(qrDataCodewordsForTest(10, 'H'), 122);
    expect(qrDataCodewordsForTest(40, 'L'), 2956);
    expect(qrDataCodewordsForTest(40, 'M'), 2334);
    expect(qrDataCodewordsForTest(40, 'Q'), 1666);
    expect(qrDataCodewordsForTest(40, 'H'), 1276);
  });

  test('коррекция и служебные биты — как в примерах стандарта ISO/IEC 18004', () {
    // Пример из стандарта: «01234567», версия 1-M.
    const data = [0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11];
    expect(qrEccForTest(data, 10), [0xA5, 0x24, 0xD4, 0xC1, 0xED, 0x36, 0xC7, 0x87, 0x2C, 0x55]);
    expect(qrFormatBitsForTest('M', 0), 0x5412);
    expect(qrFormatBitsForTest('L', 0), int.parse('111011111000100', radix: 2));
    expect(qrFormatBitsForTest('H', 7), int.parse('000100000111011', radix: 2));
    expect(qrVersionBitsForTest(7), 0x07C94);
    // Ёмкость уровня M для версий 1–10 (байт данных вместе с заголовком).
    expect([for (var v = 1; v <= 10; v++) qrDataCodewordsForTest(v, 'M')], [16, 28, 44, 64, 86, 108, 124, 154, 182, 216]);
  });

  test('код читается обратно: короткий, ссылка сервера, длинный', () {
    final rnd = math.Random(1);
    final long = List.generate(1800, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[rnd.nextInt(36)]).join();
    for (final text in ['https://example.com/sub', link, long]) {
      final qr = QrCode.encode(text)!;
      expect(decode(render(qr)), [text], reason: 'версия ${qr.version}');
    }
  });

  test('слишком длинный текст не кодируется', () {
    expect(QrCode.encode('a' * (QrCode.maxBytes + 1)), isNull);
    expect(QrCode.encode('a' * QrCode.maxBytes)?.version, 40);
  });

  test('читается с испорченными модулями, повёрнутый, светлый на тёмном, при дробном масштабе, на экране', () {
    final qr = QrCode.encode(link)!;
    // Испортить несколько модулей данных в середине кода.
    final broken = QrCode.encode(link)!;
    for (var i = 0; i < 12; i++) {
      final x = 20 + i, y = broken.size - 12 - i;
      broken.modules[y][x] = !broken.modules[y][x];
    }
    expect(decode(render(broken)), [link]);
    expect(decode(rotate(render(qr))), [link]);
    expect(decode(rotate(rotate(render(qr)))), [link]);
    expect(decode(render(qr, inverted: true)), [link]);
    expect(decode(render(qr, scale: 3.3)), [link]);
    expect(decode(render(qr, scale: 2)), [link]);
    expect(decode(onScreen(render(qr, scale: 3), 1200, 800, 517, 203)), [link]);
  });

  test('два кода на одном экране', () {
    final a = render(QrCode.encode('vless://a@203.0.113.1:443#A')!, scale: 5);
    final b = render(QrCode.encode('trojan://b@203.0.113.2:443#B')!, scale: 5);
    final screen = onScreen(a, 1000, 600, 40, 60);
    for (var y = 0; y < b.h; y++) {
      for (var x = 0; x < b.w; x++) {
        screen.gray[(y + 200) * 1000 + x + 600] = b.gray[y * b.w + x];
      }
    }
    expect(decode(screen).toSet(), {'vless://a@203.0.113.1:443#A', 'trojan://b@203.0.113.2:443#B'});
  });

  testWidgets('нарисованный в окне код читается', (tester) async {
    final qr = QrCode.encode(link)!;
    final key = GlobalKey();
    await tester.pumpWidget(Center(
      child: RepaintBoundary(
        key: key,
        child: Container(width: 320, height: 320, color: Colors.white, child: CustomPaint(painter: QrPainter(qr))),
      ),
    ));
    final texts = await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.25);
      final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      final out = Platform.environment['QR_SHOT'];
      if (out != null) {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File(out).writeAsBytesSync(png!.buffer.asUint8List());
      }
      final gray = Uint8List(image.width * image.height);
      for (var i = 0; i < gray.length; i++) {
        gray[i] = rgba[i * 4];
      }
      return QrDecoder.decode(gray, image.width, image.height);
    });
    expect(texts, [link]);
  });

  test('без кода — пусто', () {
    final w = 300, h = 200;
    final rnd = math.Random(2);
    expect(QrDecoder.decode(Uint8List.fromList(List.generate(w * h, (_) => rnd.nextInt(256))), w, h), isEmpty);
  });
}
