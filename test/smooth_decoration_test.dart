import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/ui/theme.dart';

void main() {
  testWidgets('rounded panel keeps layout and clicks while animating its surface', (tester) async {
    var selected = false;
    late StateSetter update;
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(builder: (context, setState) {
      update = setState;
      return Center(child: GestureDetector(onTap: () => setState(() => selected = !selected),
        child: AnimatedContainer(
          key: key, width: 240, height: 120, duration: const Duration(milliseconds: 180),
          decoration: SmoothBoxDecoration(
            color: selected ? Colors.blueGrey : Colors.grey,
            border: Border.all(color: Colors.orange, width: selected ? 2 : 1),
            borderRadius: BorderRadius.circular(selected ? 24 : 16),
          ),
          child: const Center(child: Text('Panel')),
        )));
    }))));
    final size = tester.getSize(find.byKey(key));
    await tester.tap(find.text('Panel'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 45));
      expect(tester.getSize(find.byKey(key)), size);
      expect(tester.takeException(), isNull);
    }
    expect(selected, isTrue);
    update(() => selected = false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('smoothed input keeps editing, floating labels and theme changes', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    Future<void> mount(Palette palette) async {
      C.use(palette);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: Center(
        child: SizedBox(width: 300, child: TextField(controller: controller,
          decoration: const InputDecoration(labelText: 'Address'))),
      ))));
    }
    await mount(Palette.dark);
    await tester.enterText(find.byType(TextField), 'service.example');
    await tester.pumpAndSettle();
    expect(controller.text, 'service.example');
    await mount(Palette.light);
    await tester.pumpAndSettle();
    expect(controller.text, 'service.example');
    expect(tester.takeException(), isNull);
    C.use(Palette.dark);
  });

  testWidgets('rounded fills feather only their edge at different pixel ratios', (tester) async {
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final ratio in [1.0, 1.25, 1.5]) {
      tester.view.devicePixelRatio = ratio;
      for (final decoration in <Decoration>[
        const SmoothBoxDecoration(color: Colors.white, borderRadius: BorderRadius.all(Radius.circular(18))),
        const ShapeDecoration(color: Colors.white,
          shape: SmoothRoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(18)))),
      ]) {
        await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder)..scale(ratio);
          final painter = decoration.createBoxPainter(() {});
          painter.paint(canvas, const Offset(20, 20),
            ImageConfiguration(size: const Size(80, 60), devicePixelRatio: ratio, textDirection: TextDirection.ltr));
          painter.dispose();
          final picture = recorder.endRecording();
          final image = await picture.toImage((120 * ratio).ceil(), (100 * ratio).ceil());
          final bytes = (await image.toByteData())!.buffer.asUint8List();
          int alpha(int x, int y) => bytes[(y * image.width + x) * 4 + 3];
          expect(alpha((20 * ratio).floor() - 1, (50 * ratio).floor()), inExclusiveRange(0, 255));
          expect(alpha((60 * ratio).floor(), (50 * ratio).floor()), 255);
          expect(alpha(0, 0), 0);
          image.dispose();
          picture.dispose();
        });
      }
    }
    tester.view.resetDevicePixelRatio();
  });
}