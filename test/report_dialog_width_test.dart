import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:skipit/ui/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/check_page.dart';
import 'package:skipit/ui/theme.dart';

void main() {
  setUpAll(() async {
    final loader = FontLoader('Segoe UI');
    for (final name in ['segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf']) {
      final f = File('${Platform.environment['WINDIR']}\\Fonts\\$name');
      if (f.existsSync()) loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
    await loader.load();
  });
  testWidgets('hover keeps the selected accent', (tester) async {
    for (final accent in [Accent.purple, Accent.blue, Accent.green]) {
      C.use(Palette.dark.styled(accent, Palette.dark.corners));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(
        child: GradientButton(label: 'Test', onPressed: () {}),
      ))));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('Test')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final container = tester.widget<AnimatedContainer>(find.descendant(
        of: find.byType(GradientButton), matching: find.byType(AnimatedContainer)).first);
      final color = (container.decoration! as BoxDecoration).gradient! as LinearGradient;
      final c = color.colors.last;
      if (accent == Accent.green) {
        expect(c.g, greaterThan(c.r));
      } else {
        expect(c.b, greaterThan(c.r));
      }
      await mouse.removePointer();
    }
    C.use(Palette.dark);
  });
  for (final size in [const Size(1920, 1080), const Size(944, 561)]) {
    testWidgets('report confirmation width at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      C.use(Palette.dark);
      final state = AppState();
      await tester.pumpWidget(RepaintBoundary(child: MaterialApp(theme: buildTheme(), home: Scaffold(
        body: Builder(builder: (context) => TextButton(
          onPressed: () => makeReportWithDialog(context, state), child: const Text('Report'),
        )),
      ))));
      await tester.tap(find.text('Report'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.getSize(find.textContaining('В журнале есть адреса сайтов')).width, lessThanOrEqualTo(560));
      expect(tester.takeException(), isNull);
      const shots = String.fromEnvironment('SKIPIT_SHOTS');
      if (shots.isNotEmpty) await expectLater(find.byType(RepaintBoundary).first,
          matchesGoldenFile(Uri.file('$shots/report-${size.width.toInt()}.png')));
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
    });
  }
}
