import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'app_menu.dart';
import 'theme.dart';

/// Настройка «Меньше анимаций» (для слабых компьютеров): время всех анимаций окна ускоряется в
/// двадцать раз — раскрытия, переходы и подсветки срабатывают за один кадр. Значки «идёт работа»
/// при этом должны крутиться как обычно, поэтому их длительность берётся через [steady].
class Motion {
  static const _fast = 0.05;

  static void apply(bool reduced) {
    final value = reduced ? _fast : 1.0;
    if (timeDilation != value) timeDilation = value;
  }

  /// Длительность бесконечной анимации, которая не должна ускоряться.
  static Duration steady(Duration d) => d * (1 / timeDilation);
}

/// Отслеживает наведение мыши и перестраивает содержимое.
class Hover extends StatefulWidget {
  const Hover({super.key, required this.builder, this.cursor = SystemMouseCursors.click, this.enabled = true});
  final Widget Function(BuildContext context, bool hovered) builder;
  final MouseCursor cursor;
  final bool enabled;

  @override
  State<Hover> createState() => _HoverState();
}

class _HoverState extends State<Hover> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: widget.enabled ? widget.cursor : MouseCursor.defer,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: widget.builder(context, widget.enabled && _hover),
      );
}

/// Знак приложения: два скруглённых треугольника «перемотки».
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 32, this.flight, this.muted = false, this.white = false});
  final double size;

  /// Анимация подключения: стрелки «летят» в ту сторону, куда указывают. Значение 0…1 — доля пути,
  /// на которую они сдвинулись на одно место (на 0 и на 1 знак выглядит как обычный). null — стоит на месте.
  final double? flight;
  final bool muted;
  final bool white;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size * 0.72,
        child: CustomPaint(painter: _MarkPainter(flight, muted, white)),
      );
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.flight, this.muted, this.white);
  final double? flight;
  final bool muted;
  final bool white;

  /// Тема, в которой знак нарисован: после её смены его нужно перерисовать.
  final Palette palette = C.palette;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final r = h * 0.12;
    final Gradient gradient = white
        ? const LinearGradient(colors: [Colors.white, Colors.white])
        : muted
            ? LinearGradient(colors: [C.palette.markMuted, C.palette.markMuted])
            : C.gradient;

    Path tri(double x0, double tw) => Path()
      ..moveTo(x0 + r, r)
      ..lineTo(x0 + tw - r, h / 2)
      ..lineTo(x0 + r, h - r)
      ..close();

    void drawTri(Path p) {
      final shader = gradient.createShader(Offset.zero & size);
      canvas.drawPath(p, Paint()..shader = shader);
      canvas.drawPath(
          p,
          Paint()
            ..shader = shader
            ..style = PaintingStyle.stroke
            ..strokeWidth = r * 2
            ..strokeJoin = StrokeJoin.round);
    }

    // Два одинаковых треугольника с небольшим зазором, без выемки (на крупной кнопке она выглядела как кружок).
    const step = 0.52, width = 0.48;
    final t = flight;
    if (t == null) {
      drawTri(tri(0, w * width));
      drawTri(tri(w * step, w * width));
      return;
    }
    // В полёте треугольников три: слева влетает новый, два сдвигаются вправо, правый улетает.
    // У краёв знака они плавно проявляются и тают, поэтому цикл замыкается без рывка.
    for (var i = -1; i <= 1; i++) {
      final x0 = (i + t) * step;
      final center = x0 + width / 2;
      final alpha = ((center + 0.1) / 0.3).clamp(0.0, 1.0) * ((1.1 - center) / 0.3).clamp(0.0, 1.0);
      if (alpha <= 0) continue;
      canvas.saveLayer(Rect.fromLTRB(-w, 0, w * 2, h), Paint()..color = Colors.white.withValues(alpha: alpha));
      drawTri(tri(w * x0, w * width));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _MarkPainter old) =>
      old.flight != flight || old.muted != muted || old.white != white || !identical(old.palette, palette);
}

/// Значок приложения — та же картинка, что у иконки exe (assets/icon.png из tools/make_icon.ps1).
class AppBadge extends StatelessWidget {
  const AppBadge({super.key, this.size = 38});
  final double size;

  @override
  Widget build(BuildContext context) =>
      Image.asset('assets/icon.png', width: size, height: size, filterQuality: FilterQuality.medium);
}

/// Выпадающий список в общем стиле: скруглённая рамка, подсветка при наведении, без «залипающего» фокуса.
class AppDropdown<T> extends StatelessWidget {
  const AppDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.expand = false,
    this.leading,
    this.height,
  });
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;
  final bool expand;
  final Widget? leading;
  final double? height;

  @override
  Widget build(BuildContext context) => Hover(
        builder: (context, hovered) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Список открывается тем же меню, что и остальные меню приложения; текущий пункт отмечен галочкой.
          onTap: () async {
            final v = await showAppMenu<T>(context, matchWidth: true, items: [
              for (final e in items.entries) AppMenuItem(e.key, e.value, checked: e.key == value),
            ]);
            if (v != null && v != value) onChanged(v);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: height ?? 42,
            padding: const EdgeInsets.only(left: 14, right: 8),
            decoration: BoxDecoration(
              color: hovered ? C.orange.withValues(alpha: 0.08) : (height != null ? C.surface : Colors.transparent),
              borderRadius: BorderRadius.circular(height != null ? 18 : 12),
              border: Border.all(color: hovered ? C.orange.withValues(alpha: 0.7) : C.border),
            ),
            child: Row(mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min, children: [
              if (leading != null) ...[leading!, const SizedBox(width: 12)],
              Flexible(
                fit: expand ? FlexFit.tight : FlexFit.loose,
                // Новое значение проявляется на месте старого, а ширина кнопки плавно подстраивается под
                // него — иначе при выборе надпись и рамка менялись рывком.
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeInOutCubic,
                  alignment: Alignment.centerLeft,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: const Interval(0.35, 1, curve: Curves.easeOut),
                    switchOutCurve: const Interval(0.35, 1, curve: Curves.easeIn),
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.centerLeft,
                      children: [...previous, if (current != null) current],
                    ),
                    child: Text(items[value] ?? '$value',
                        key: ValueKey(value),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: C.text, fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.expand_more_rounded, color: hovered ? C.orange : C.muted),
            ]),
          ),
        ),
      );
}
/// Индикатор «идёт работа»: плавно вращающийся значок. Стандартный кружок Flutter на маленьком
/// размере рисуется с заметными «ступеньками», а значок — это символ шрифта, он всегда сглажен.
class Spinner extends StatefulWidget {
  const Spinner({super.key, this.size = 18, this.icon = Icons.autorenew_rounded, this.pulse = false});
  final double size;
  final IconData icon;

  /// Вместо вращения значок плавно мигает. Для действий, у которых свой значок (проверка задержки):
  /// вращающиеся стрелки там выглядели бы как обновление подписки.
  final bool pulse;

  @override
  State<Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<Spinner> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(
      vsync: this, duration: Motion.steady(Duration(milliseconds: widget.pulse ? 650 : 900)))
    ..repeat(reverse: widget.pulse);

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = Icon(widget.icon, size: widget.size, color: C.orange);
    return widget.pulse
        ? FadeTransition(opacity: Tween(begin: 0.3, end: 1.0).animate(_anim), child: icon)
        : RotationTransition(turns: _anim, child: icon);
  }
}

/// Мягкие края у прокручиваемого списка: строки не обрезаются резкой линией сверху и снизу,
/// а плавно растворяются на последних пикселях.
class FadeEdges extends StatelessWidget {
  const FadeEdges({super.key, required this.child, this.size = 14});
  final Widget child;

  /// Высота растворяющейся полосы у каждого края.
  final double size;

  @override
  Widget build(BuildContext context) => ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) {
          final edge = rect.height <= 0 ? 0.0 : (size / rect.height).clamp(0.0, 0.5);
          return LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: const [Colors.transparent, Colors.black, Colors.black, Colors.transparent],
            stops: [0, edge, 1 - edge, 1],
          ).createShader(rect);
        },
        child: child,
      );
}

/// Выключатель. Переключается только кликом: стандартный Switch реагирует ещё и на протягивание
/// мышью, из-за чего настройки можно было случайно переключить, проведя по ним с зажатой кнопкой.
class AppSwitch extends StatelessWidget {
  const AppSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  static const _duration = Duration(milliseconds: 180);

  @override
  Widget build(BuildContext context) => Hover(
        builder: (context, hovered) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(!value),
          child: AnimatedContainer(
            duration: _duration,
            curve: Curves.easeOutCubic,
            width: 50,
            height: 30,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: value ? C.orange : C.surface2,
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: value ? C.orange : (hovered ? C.orange.withValues(alpha: 0.6) : C.border),
                width: 1.5,
              ),
              boxShadow: [if (value && hovered) BoxShadow(color: C.orange.withValues(alpha: 0.45), blurRadius: 12)],
            ),
            // Кружок переезжает к нужному краю и подрастает во включённом состоянии.
            child: AnimatedAlign(
              duration: _duration,
              curve: Curves.easeOutCubic,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: AnimatedContainer(
                duration: _duration,
                curve: Curves.easeOutCubic,
                width: value ? 21 : 15,
                height: value ? 21 : 15,
                margin: EdgeInsets.symmetric(horizontal: value ? 0 : 3),
                decoration: BoxDecoration(color: value ? Colors.white : C.muted, shape: BoxShape.circle),
              ),
            ),
          ),
        ),
      );
}

/// Плавное раскрытие и сворачивание блока: высота меняется, а содержимое проявляется и тает.
/// При сворачивании содержимое остаётся на месте до конца анимации, а не исчезает сразу.
class Reveal extends StatefulWidget {
  const Reveal({super.key, required this.open, required this.child, this.extent});
  final bool open;
  final Widget child;

  /// Высота содержимого, если она известна заранее. У блока выше окна плавно раскрывается только
  /// часть высотой с окно, остальное (оно за нижним краем) появляется сразу. Иначе длинный список
  /// пролетал бы видимую часть за доли секунды — за то же время ему надо пройти в разы больший путь.
  final double? extent;

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    reverseDuration: const Duration(milliseconds: 220),
    value: widget.open ? 1 : 0,
  );
  late final _size = CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
  // Содержимое проявляется сразу и быстрее, чем раздвигается место под него: с отложенным
  // проявлением сначала раскрывалась пустота, и это выглядело как задержка.
  late final _fade = CurvedAnimation(parent: _anim, curve: const Interval(0, 0.55, curve: Curves.easeOut));

  final _childKey = GlobalKey();

  /// Высота содержимого, измеренная при последнем раскрытии (если [Reveal.extent] не задан).
  double? _measured;

  @override
  void initState() {
    super.initState();
    if (widget.open) WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  /// Чем выше блок, тем дольше он раскрывается: иначе длинный список «выстреливает» — за то же
  /// время ему надо пройти в разы больший путь. Короткие блоки (до 200 точек) идут с обычной
  /// скоростью, дальше время плавно растёт и перестаёт расти у блоков высотой с окно.
  void _applyDuration(double? height) {
    final extra = height == null ? 0.0 : ((height - 200) / 600).clamp(0.0, 1.0);
    _anim.duration = Duration(milliseconds: 280 + (240 * extra).round());
    _anim.reverseDuration = Duration(milliseconds: 220 + (180 * extra).round());
  }

  /// Высота ещё не известна: один кадр содержимое строится невидимым, чтобы её измерить.
  bool _preparing = false;

  /// Запоминает высоту содержимого (она известна только после того, как оно построено).
  void _measure() {
    if (!mounted) return;
    final height = _childKey.currentContext?.size?.height;
    if (height != null && height != _measured) setState(() => _measured = height);
  }

  @override
  void didUpdateWidget(Reveal old) {
    super.didUpdateWidget(old);
    if (old.open == widget.open) return;
    final known = widget.extent ?? _measured;
    if (!widget.open) {
      _applyDuration(known);
      _anim.reverse();
    } else if (known != null) {
      _applyDuration(known);
      _anim.forward();
      // Содержимое могло измениться с прошлого раза — запоминаем новую высоту.
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    } else {
      _preparing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _measure();
        setState(() => _preparing = false);
        if (widget.open) {
          _applyDuration(_measured);
          _anim.forward();
        }
      });
    }
  }

  @override
  void dispose() {
    _size.dispose();
    _fade.dispose();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final extent = widget.extent ?? _measured;
    final screen = MediaQuery.sizeOf(context).height;
    // Доля высоты, которая раскрывается плавно (см. [Reveal.extent]).
    final animated = extent != null && extent > screen ? screen / extent : 1.0;
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, child) => _anim.isDismissed && !_preparing
          ? const SizedBox(width: double.infinity)
          : ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: _anim.isCompleted ? 1 : _size.value * animated,
                child: Opacity(opacity: _fade.value, child: child),
              ),
            ),
      child: KeyedSubtree(key: _childKey, child: widget.child),
    );
  }
}

/// Панель с тонкой рамкой. Если задан onTap — подсвечивается при наведении.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.glow = false, this.onTap});
  final Widget child;
  final EdgeInsets padding;
  final bool glow;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Hover(
        enabled: onTap != null,
        builder: (context, hovered) => GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: padding,
            decoration: BoxDecoration(
              color: hovered ? C.surface2 : C.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: glow
                    ? C.orange.withValues(alpha: 0.6)
                    : (hovered ? C.orange.withValues(alpha: 0.35) : C.border),
              ),
              boxShadow: glow ? [BoxShadow(color: C.orange.withValues(alpha: 0.16), blurRadius: 24)] : null,
            ),
            child: child,
          ),
        ),
      );
}

class PageHeader extends StatelessWidget {
  const PageHeader(this.title, {super.key, this.subtitle, this.actions = const [], this.below});
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  /// Дополнительная строка под заголовком (например, вкладки раздела).
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    final heading = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
      if (subtitle != null) ...[
        const SizedBox(height: 4),
        Text(subtitle!, style: TextStyle(color: C.muted, fontSize: 13)),
      ],
      if (below != null) ...[const SizedBox(height: 14), below!],
    ]);
    final buttons = Wrap(spacing: 8, runSpacing: 8, children: actions);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 26, 28, 16),
      child: LayoutBuilder(
        // В узком окне кнопки уходят под заголовок: в одну строку с ним они оставляли заголовку
        // несколько точек ширины, и он выстраивался по букве в строке.
        builder: (context, c) => actions.isEmpty || c.maxWidth >= 680
            ? Row(children: [Expanded(child: heading), buttons])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                heading,
                const SizedBox(height: 14),
                buttons,
              ]),
      ),
    );
  }
}

/// Кнопка с оранжевым градиентом; при наведении светится ярче.
class GradientButton extends StatelessWidget {
  const GradientButton({super.key, required this.label, this.icon, this.onPressed});
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Hover(
      enabled: enabled,
      builder: (context, hovered) => Opacity(
        opacity: enabled ? 1 : 0.5,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            gradient: hovered
                ? const LinearGradient(colors: [Color(0xFFFFAE5C), Color(0xFFFF7033)])
                : C.gradient,
            borderRadius: BorderRadius.circular(12),
            boxShadow: enabled
                ? [BoxShadow(color: C.orange.withValues(alpha: hovered ? 0.55 : 0.3), blurRadius: hovered ? 22 : 14)]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onPressed,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (icon != null) ...[Icon(icon, size: 18, color: Colors.white), const SizedBox(width: 8)],
                  Text(label, style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Контурная кнопка; при наведении — оранжевая рамка и лёгкая заливка.
class GhostButton extends StatelessWidget {
  const GhostButton({super.key, required this.label, this.icon, this.onPressed, this.busy = false});
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        onPressed: busy ? null : onPressed,
        style: ButtonStyle(
          side: WidgetStateProperty.resolveWith((s) => BorderSide(
                color: s.contains(WidgetState.hovered) ? C.orange.withValues(alpha: 0.7) : C.border,
              )),
          backgroundColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.hovered) ? C.orange.withValues(alpha: 0.08) : Colors.transparent),
          overlayColor: WidgetStateProperty.all(C.orange.withValues(alpha: 0.08)),
        ),
        icon: busy
            ? const Spinner(size: 18)
            : Icon(icon ?? Icons.circle, size: 18),
        label: Text(label),
      );
}

/// Кнопка подключения: плитка со знаком ▶▶. Кликабельна только сама плитка.
/// При подключении знак «перематывается», при активном соединении плитка светится.
class ConnectButton extends StatefulWidget {
  const ConnectButton({super.key, required this.connected, required this.busy, required this.onTap});
  final bool connected;
  final bool busy;
  final VoidCallback onTap;

  @override
  State<ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<ConnectButton> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 750));
  bool _hover = false;

  /// Идёт ли сейчас бесконечный повтор (а не доигрывание последнего круга).
  bool _looping = false;

  /// Анимация крутится только пока идёт подключение — в покое окно не перерисовывается впустую.
  /// Когда подключение закончилось, текущий круг доигрывается до конца: стрелки долетают на место,
  /// а не отскакивают назад рывком.
  void _syncAnim() {
    _anim.duration = Motion.steady(const Duration(milliseconds: 750));
    if (widget.busy && !_looping) {
      _looping = true;
      _anim.repeat();
    } else if (!widget.busy && _looping) {
      _looping = false;
      _anim.forward().whenComplete(() {
        if (mounted && !_looping) _anim.value = 0;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _syncAnim();
  }

  @override
  void didUpdateWidget(ConnectButton old) {
    super.didUpdateWidget(old);
    _syncAnim();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const size = 200.0;
    const radius = 50.0;
    final active = widget.connected;
    final lit = active || widget.busy || _hover;
    return AnimatedScale(
      scale: _hover ? 1.03 : 1,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      child: ClipRRect(
        // Клип ограничивает и зону нажатия: углы плитки не кликаются.
        borderRadius: BorderRadius.circular(radius),
        clipBehavior: Clip.antiAlias,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: size,
              height: size,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                // Ровная заливка: тёмный градиент на экране ложился заметными полосами.
                color: active ? C.palette.tileActiveTop : C.palette.tileTop,
                border: Border.all(
                  color: active ? C.orange : (lit ? C.orange.withValues(alpha: 0.55) : C.border),
                  width: 2,
                ),
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: AnimatedBuilder(
                    animation: _anim,
                    builder: (_, __) => AppMark(
                      size: 104,
                      // Разгон и торможение в каждом цикле — стрелки «перелетают» на место друг друга.
                      flight: _anim.isAnimating ? Curves.easeInOutCubic.transform(_anim.value) : null,
                      muted: !lit,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Свечение вокруг кнопки подключения (рисуется снаружи клипа).
class ConnectGlow extends StatelessWidget {
  const ConnectGlow({super.key, required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(50),
          boxShadow: [
            // Большая тёмная тень на тёмном фоне тоже давала полосы — оставлено только свечение при подключении.
            if (active) BoxShadow(color: C.orange.withValues(alpha: 0.4), blurRadius: 60, spreadRadius: 2),
          ],
        ),
        child: child,
      );
}

class DelayBadge extends StatelessWidget {
  const DelayBadge(this.ms, {super.key, this.testing = false});
  final int? ms;
  final bool testing;

  @override
  Widget build(BuildContext context) {
    final text = ms == null ? (testing ? '…' : '—') : (ms! < 0 ? 'нет' : '$ms мс');
    final color = C.delay(ms);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, Color? color}) : _color = color;
  final String text;
  final Color? _color;
  Color get color => _color ?? C.muted;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: color.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
      );
}

/// Сегментированный переключатель: оранжевая «плашка» плавно переезжает к выбранному пункту;
/// невыбранные пункты подсвечиваются при наведении.
class Segmented<T> extends StatefulWidget {
  const Segmented({super.key, required this.value, required this.items, required this.onChanged});
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  @override
  State<Segmented<T>> createState() => _SegmentedState<T>();
}

class _SegmentedState<T> extends State<Segmented<T>> {
  final _stackKey = GlobalKey();
  final _keys = <T, GlobalKey>{};

  /// Место выбранного пункта внутри переключателя. null — ещё не измерено (первый кадр).
  Rect? _thumb;

  /// Первое появление плашки — без анимации, дальше она ездит.
  bool _animate = false;

  /// Ширина пунктов зависит от текста, поэтому место плашки берётся из реальной раскладки после кадра.
  void _measure() {
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    final item = _keys[widget.value]?.currentContext?.findRenderObject() as RenderBox?;
    if (stack == null || item == null || !stack.hasSize || !item.hasSize) return;
    final raw = item.localToGlobal(Offset.zero, ancestor: stack) & item.size;
    // Края плашки ставятся ровно на точки экрана. Ширина пунктов зависит от текста, и край обычно
    // попадает между точками (особенно при масштабе экрана 125–150 %): такая точка закрашивается
    // наполовину, и вдоль края плашки видна тёмно-оранжевая полоска.
    final ratio = View.of(context).devicePixelRatio;
    final origin = stack.localToGlobal(Offset.zero);
    double snap(double v) => (v * ratio).roundToDouble() / ratio;
    final onScreen = raw.shift(origin);
    final rect = Rect.fromLTRB(snap(onScreen.left), snap(onScreen.top), snap(onScreen.right), snap(onScreen.bottom))
        .shift(-origin);
    if (rect == _thumb) return;
    setState(() {
      _animate = _thumb != null;
      _thumb = rect;
    });
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measure();
    });
    final thumb = _thumb;
    return FittedBox(
      // В узком месте переключатель ужимается целиком, а не вылезает за край.
      fit: BoxFit.scaleDown,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: C.surface2,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: C.border),
        ),
        child: Stack(key: _stackKey, children: [
          if (thumb != null)
            AnimatedPositioned.fromRect(
              rect: thumb,
              duration: Duration(milliseconds: _animate ? 240 : 0),
              curve: Curves.easeOutCubic,
              child: DecoratedBox(
                decoration: BoxDecoration(gradient: C.gradient, borderRadius: BorderRadius.circular(10)),
              ),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in widget.items.entries)
                Hover(
                  builder: (context, hovered) {
                    final selected = e.key == widget.value;
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => widget.onChanged(e.key),
                      child: Container(
                        key: _keys.putIfAbsent(e.key, GlobalKey.new),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                        decoration: BoxDecoration(
                          // До первого измерения выбранный пункт закрашен сам — без пустого кадра.
                          gradient: selected && thumb == null ? C.gradient : null,
                          color: !selected && hovered ? C.hover : null,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        // Плавно меняется только цвет текста; фон не смешивается — едет сама плашка.
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 180),
                          style: TextStyle(
                            fontFamily: 'Segoe UI',
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: selected ? Colors.white : (hovered ? C.text : C.muted),
                          ),
                          child: Text(e.value),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ]),
      ),
    );
  }
}

Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String? hint,
  int maxLines = 1,
  String ok = 'Готово',
}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 520,
        child: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: maxLines,
          minLines: 1,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: maxLines == 1 ? (v) => Navigator.pop(ctx, v) : null,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
        GradientButton(label: ok, onPressed: () => Navigator.pop(ctx, ctrl.text)),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String title, String text, {String ok = 'Удалить'}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          GradientButton(label: ok, onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    ) ??
    false;
