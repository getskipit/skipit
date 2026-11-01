import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Боковая кнопка мыши выполняет тот же переход, что и стрелка страницы.
class MouseBack extends StatelessWidget {
  const MouseBack({super.key, required this.onBack, required this.child});
  final VoidCallback? onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          if (event.kind == PointerDeviceKind.mouse && event.buttons == kBackMouseButton) onBack?.call();
        },
        child: child,
      );
}
