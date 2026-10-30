import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Контроллер с плавной прокруткой колесом мыши: вместо мгновенного скачка
/// каждое деление колеса анимируется, а быстрые прокрутки подряд накапливаются.
class SmoothScrollController extends ScrollController {
  /// Строка, которую при следующей раскладке нужно оставить там же на экране, и где она была (точек
  /// от верха видимой части): страница перестраивается (например, меняет ширину), а строка не уезжает.
  /// Поправка вносится в том же кадре и сбрасывается.
  (GlobalKey, double)? anchor;

  /// Где строка сейчас: точек от верха видимой части прокрутки; null — её нет на экране.
  static double? offsetOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return null;
    return box.localToGlobal(Offset.zero, ancestor: viewport).dy;
  }

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) =>
      _SmoothScrollPosition(
        owner: this,
        physics: physics,
        context: context,
        initialPixels: initialScrollOffset,
        keepScrollOffset: keepScrollOffset,
        oldPosition: oldPosition,
        debugLabel: debugLabel,
      );
}

class _SmoothScrollPosition extends ScrollPositionWithSingleContext {
  _SmoothScrollPosition({
    required this.owner,
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  final SmoothScrollController owner;
  static const _duration = Duration(milliseconds: 320);
  double? _target;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final ok = super.applyContentDimensions(minScrollExtent, maxScrollExtent);
    final anchor = owner.anchor;
    if (anchor == null) return ok;
    owner.anchor = null;
    final now = SmoothScrollController.offsetOf(anchor.$1);
    if (now == null || (now - anchor.$2).abs() < 0.5) return ok;
    // Сдвиг прокрутки и повторная раскладка в этом же кадре — строка не мелькает на новом месте.
    correctPixels((pixels + now - anchor.$2).clamp(minScrollExtent, maxScrollExtent));
    return false;
  }

  @override
  void pointerScroll(double delta) {
    if (delta == 0) return;
    // Если анимация ещё идёт — прибавляем к её цели, чтобы прокрутка не «тормозила».
    final base = _target != null && isScrollingNotifier.value ? _target! : pixels;
    final target = (base + delta).clamp(minScrollExtent, maxScrollExtent);
    if (target == pixels) return;
    _target = target;
    animateTo(target, duration: _duration, curve: Curves.easeOutCubic);
  }
}

/// Создаёт и освобождает [SmoothScrollController] для прокручиваемого содержимого.
class SmoothScroll extends StatefulWidget {
  const SmoothScroll({super.key, required this.builder});
  final Widget Function(BuildContext context, ScrollController controller) builder;

  @override
  State<SmoothScroll> createState() => _SmoothScrollState();
}

class _SmoothScrollState extends State<SmoothScroll> {
  final _controller = SmoothScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}

/// Отдельный контроллер плавной прокрутки для раздела: списки внутри берут его через primary: true.
class SmoothPage extends StatelessWidget {
  const SmoothPage({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => SmoothScroll(
        builder: (context, controller) => PrimaryScrollController(controller: controller, child: child),
      );
}