import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/main.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/theme.dart';

/// Смена темы перекрашивает окно, не пересоздавая его: открытый раздел и состояние виджетов сохраняются.
void main() {
  // Настоящий ввод-вывод — вне testWidgets: внутри него время поддельное, и чтение диска не завершилось бы.
  setUpAll(AppPaths.init);

  testWidgets('смена темы перекрашивает окно на месте', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState()..settings.theme = AppTheme.dark;
    state.routingProfiles.add(RoutingProfile.global());
    await tester.pumpWidget(SkipItApp(state: state));
    await tester.pump(const Duration(milliseconds: 300));
    Color background() => tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor!;
    expect(background(), Palette.dark.bg);
    // Встроенные подписи Flutter — на русском (подсказка кнопки закрытия уведомления и т. п.).
    expect(MaterialLocalizations.of(tester.element(find.byType(Scaffold).first)).closeButtonTooltip, 'Закрыть');

    // Открываем «Настройки» и переключаем тему — раздел должен остаться открытым.
    await tester.tap(find.byIcon(Icons.tune_rounded).first);
    await tester.pump(const Duration(milliseconds: 300));
    state.settings.theme = AppTheme.light;
    state.openPage(state.pageIndex);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(background(), Palette.light.bg);
    expect(state.pageIndex, 4);
    expect(tester.takeException(), isNull);

    state.settings.theme = AppTheme.dark;
    state.openPage(state.pageIndex);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(background(), Palette.dark.bg);
    C.use(Palette.dark);
  });
}