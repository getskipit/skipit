import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/ui/theme.dart';
import 'package:skipit/ui/widgets.dart';

/// Над любой доступной кнопкой — палец, над недоступной — стрелка (кнопки Flutter на Windows по умолчанию
/// показывают стрелку всегда).
void main() {
  Future<MouseCursor?> cursorOver(WidgetTester tester, Widget button) async {
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: Center(child: button))));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byWidget(button)));
    await tester.pump();
    return RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
  }

  testWidgets('контурная кнопка (Экспорт, Импорт…)', (tester) async {
    expect(await cursorOver(tester, GhostButton(label: 'Экспорт', onPressed: () {})), SystemMouseCursors.click);
  });

  testWidgets('недоступная кнопка — стрелка', (tester) async {
    expect(await cursorOver(tester, const GhostButton(label: 'Экспорт')), SystemMouseCursors.basic);
  });

  testWidgets('текстовая кнопка', (tester) async {
    expect(await cursorOver(tester, TextButton(onPressed: () {}, child: const Text('Отмена'))),
        SystemMouseCursors.click);
  });

  testWidgets('кнопка-значок', (tester) async {
    expect(await cursorOver(tester, IconButton(onPressed: () {}, icon: const Icon(Icons.close))),
        SystemMouseCursors.click);
  });

  testWidgets('кнопка с заливкой', (tester) async {
    expect(await cursorOver(tester, GradientButton(label: 'Сохранить', onPressed: () {})), SystemMouseCursors.click);
  });
}
