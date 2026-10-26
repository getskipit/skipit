import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/qr.dart';
import '../core/tray.dart';
import '../core/windows.dart';
import '../state/app_scope.dart';
import 'theme.dart';

/// Ищет QR-коды на всех мониторах и добавляет найденные ссылки (серверы, подписки).
Future<void> importQrFromScreen(BuildContext context) async {
  final state = AppScope.read(context);
  final image = await Tray.captureScreen();
  if (image == null) {
    state.toast('Не удалось сделать снимок экрана');
    return;
  }
  final texts = await _decode(image.gray, image.w, image.h);
  if (texts.isEmpty) {
    state.toast('QR-код на экране не найден', detail: 'Откройте его на экране целиком и не слишком мелко');
    return;
  }
  await state.importText(texts.join('\n'));
}

/// QR-код из файла-картинки (PNG, JPG, BMP, GIF).
Future<void> importQrFromFile(BuildContext context) async {
  final state = AppScope.read(context);
  final path = await WinSys.pickFile(filter: 'Картинки (*.png;*.jpg;*.jpeg;*.bmp;*.gif)|*.png;*.jpg;*.jpeg;*.bmp;*.gif');
  if (path == null) return;
  final ({Uint8List gray, int w, int h}) image;
  try {
    image = await _grayFromBytes(await File(path).readAsBytes());
  } catch (_) {
    state.toast('Не удалось открыть картинку');
    return;
  }
  final texts = await _decode(image.gray, image.w, image.h);
  if (texts.isEmpty) {
    state.toast('В картинке не найден QR-код');
    return;
  }
  await state.importText(texts.join('\n'));
}

/// Картинка из буфера обмена: если в ней QR-код — добавляет его ссылки. false — картинки в буфере нет.
Future<bool> importQrFromClipboardImage(BuildContext context) async {
  final state = AppScope.read(context);
  final image = await Tray.clipboardImage();
  if (image == null) return false;
  final texts = await _decode(image.gray, image.w, image.h);
  if (texts.isEmpty) {
    state.toast('В картинке из буфера не найден QR-код');
  } else {
    await state.importText(texts.join('\n'));
  }
  return true;
}

Future<List<String>> _decode(Uint8List gray, int w, int h) => Isolate.run(() => QrDecoder.decode(gray, w, h));

/// Картинка из файла в оттенках серого; большие фото уменьшаются до 3000 точек по длинной стороне.
Future<({Uint8List gray, int w, int h})> _grayFromBytes(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final scale = 3000 / (descriptor.width > descriptor.height ? descriptor.width : descriptor.height);
  final codec = await descriptor.instantiateCodec(
      targetWidth: scale < 1 ? (descriptor.width * scale).round() : null,
      targetHeight: scale < 1 ? (descriptor.height * scale).round() : null);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  final w = image.width, h = image.height;
  image.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  final gray = Uint8List(w * h);
  for (var i = 0; i < w * h; i++) {
    final a = rgba[i * 4 + 3];
    // Прозрачное — как белый фон.
    final lum = (rgba[i * 4] * 299 + rgba[i * 4 + 1] * 587 + rgba[i * 4 + 2] * 114) ~/ 1000;
    gray[i] = (lum * a + 255 * (255 - a)) ~/ 255;
  }
  return (gray: gray, w: w, h: h);
}

/// Окно с QR-кодом [text] — чтобы перенести сервер или подписку на телефон. [subscription] — код подписки
/// (её ссылка открывает все серверы), иначе — одного сервера.
Future<void> showQrDialog(BuildContext context, {required String title, required String text, bool subscription = false}) async {
  final state = AppScope.read(context);
  final qr = QrCode.encode(text);
  if (qr == null) {
    state.toast('Ссылка слишком длинная для QR-кода');
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 320,
            height: 320,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(C.r(12))),
            child: CustomPaint(painter: QrPainter(qr)),
          ),
          const SizedBox(height: 14),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_rounded, size: 16, color: C.orange),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                subscription
                    ? 'В коде — ссылка подписки: по ней открываются все её серверы. Не показывайте его посторонним.'
                    : 'В коде — ключ доступа к серверу. Не показывайте его посторонним.',
                style: TextStyle(color: C.muted, fontSize: 12.5, height: 1.35),
              ),
            ),
          ]),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            state.toast('Ссылка скопирована');
          },
          child: const Text('Скопировать ссылку'),
        ),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть')),
      ],
    ),
  );
}

/// Рисует код чёрным по белому с полем в 4 модуля, модули — по целым точкам экрана (без размытых краёв).
class QrPainter extends CustomPainter {
  QrPainter(this.qr);
  final QrCode qr;

  @override
  void paint(Canvas canvas, Size size) {
    final cells = qr.size + 8;
    final side = size.shortestSide;
    final module = (side / cells).floorToDouble().clamp(1.0, double.infinity);
    final offset = Offset((size.width - module * qr.size) / 2, (size.height - module * qr.size) / 2);
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    final path = Path();
    for (var y = 0; y < qr.size; y++) {
      for (var x = 0; x < qr.size; x++) {
        if (qr.modules[y][x]) path.addRect(Rect.fromLTWH(offset.dx + x * module, offset.dy + y * module, module, module));
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(QrPainter old) => old.qr != qr;
}
