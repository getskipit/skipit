import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/ui/app_icon.dart';
import 'package:skipit/ui/theme.dart';

void main() {
  testWidgets('значок панели задач содержит PNG всех размеров Windows', (tester) async {
    await tester.runAsync(() async {
      const shots = String.fromEnvironment('SKIPIT_SHOTS');
      final directory = shots.isEmpty ? Directory.systemTemp.createTempSync('skipit-icon') : Directory(shots);
      if (shots.isEmpty) addTearDown(() => directory.deleteSync(recursive: true));

      final images = await renderIcon(IconStyle.bright, Accent.blue);
      expect(images.map((image) => image.size), iconSizes);
      final path = saveTaskbarIcon(directory, IconStyle.bright, Accent.blue, images);
      expect(path, isNotNull);
      final bytes = File(path!).readAsBytesSync();
      final ico = ByteData.sublistView(bytes);
      expect(ico.getUint16(2, Endian.little), 1);
      expect(ico.getUint16(4, Endian.little), iconSizes.length);

      for (final (index, size) in iconSizes.indexed) {
        final entry = 6 + 16 * index;
        final offset = ico.getUint32(entry + 12, Endian.little);
        final length = ico.getUint32(entry + 8, Endian.little);
        expect(ico.getUint8(entry), size % 256);
        expect(ico.getUint8(entry + 1), size % 256);
        expect(bytes.sublist(offset, offset + length), images[index].png);
      }

      final other = await renderIcon(IconStyle.bright, Accent.green);
      expect(saveTaskbarIcon(directory, IconStyle.bright, Accent.green, other), isNot(path));
    });
  });
}
