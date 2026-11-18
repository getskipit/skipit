import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/ui/app_icon.dart';
import 'package:skipit/ui/icon_style_preview.dart';
import 'package:skipit/ui/theme.dart';

// Из корня проекта: flutter test tools/make_icon_previews_test.dart
void main() {
  testWidgets('render icon preview assets', (tester) async {
    await tester.runAsync(() async {
      final asset = File(iconPreviewAsset);
      final name = asset.uri.pathSegments.last;
      final styles = IconStyle.values.skip(1).toList();
      for (final ratio in [1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0]) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..scale(ratio);
        const padding = (iconPreviewCell - iconPreviewSize) / 2;
        for (final accent in Accent.values) {
          for (final (column, style) in styles.indexed) {
            canvas.save();
            canvas.translate(column * iconPreviewCell + padding, accent.index * iconPreviewCell + padding);
            SkipItIconPainter(style, accent).paint(canvas, const Size.square(iconPreviewSize));
            canvas.restore();
          }
        }
        final picture = recorder.endRecording();
        final width = (styles.length * iconPreviewCell * ratio).round();
        final height = (Accent.values.length * iconPreviewCell * ratio).round();
        final image = await picture.toImage(width, height);
        picture.dispose();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        final dir = ratio == 1.0 ? asset.parent : Directory('${asset.parent.path}${Platform.pathSeparator}${ratio}x');
        final output = dir.uri.resolve(name).toFilePath();
        await dir.create(recursive: true);
        await File(output).writeAsBytes(Uint8List.sublistView(bytes!));
      }
    });
  });
}
