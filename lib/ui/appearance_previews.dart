import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets.dart';

/// Выбор картинками (Настройки → Внешний вид): под каждой картинкой подпись, выбранная — в рамке цвета акцента.
class PictureChoice<T> extends StatelessWidget {
  const PictureChoice({super.key, required this.value, required this.items, required this.onChanged});
  final T value;

  /// Значение → подпись и картинка.
  final Map<T, (String, Widget)> items;
  final ValueChanged<T> onChanged;

  static const width = 112.0;
  static const height = 72.0;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 12, runSpacing: 12, children: [
        for (final MapEntry(key: v, value: (label, picture)) in items.entries)
          Hover(
            builder: (context, hovered) {
              final on = v == value;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(v),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: width + 6,
                    height: height + 6,
                    padding: const EdgeInsets.all(1),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(C.r(11)),
                      border: Border.all(color: on ? C.orange : (hovered ? C.muted : C.border), width: 2),
                    ),
                    child: ClipRRect(borderRadius: BorderRadius.circular(C.r(8)), child: picture),
                  ),
                  const SizedBox(height: 6),
                  Text(label,
                      style: TextStyle(
                        fontSize: 12,
                        color: on ? C.text : C.muted,
                        fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                      )),
                ]),
              );
            },
          ),
      ]);
}

/// Что нарисовано в окошке-образце справа от меню.
enum MiniBody { cards, tiles, list }

/// Окошко программы в миниатюре: меню слева или сверху и содержимое в цветах палитры [p].
class MiniWindow extends StatelessWidget {
  const MiniWindow({super.key, required this.p, this.navTop = false, this.body = MiniBody.cards, this.corners});
  final Palette p;
  final bool navTop;
  final MiniBody body;

  /// Скругление карточек в образце (множитель, как у [C.r]); по умолчанию — текущее.
  final double? corners;

  double _r(double x) => x * (corners ?? p.corners);

  Widget _bar(double w, Color c, {double h = 3}) =>
      Container(width: w, height: h, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2)));

  Widget _card({Widget? child, EdgeInsets padding = const EdgeInsets.all(4)}) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: p.surface2,
          borderRadius: BorderRadius.circular(_r(4)),
          border: Border.all(color: p.border, width: 0.6),
        ),
        child: child,
      );

  Widget _content() => switch (body) {
        MiniBody.cards => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: _card(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _bar(26, p.text),
                  const SizedBox(height: 3),
                  _bar(40, p.muted, h: 2),
                  const Spacer(),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Container(
                      width: 18,
                      height: 7,
                      decoration: BoxDecoration(color: C.orange, borderRadius: BorderRadius.circular(_r(3))),
                    ),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 3),
            SizedBox(height: 12, child: _card(child: _bar(30, p.muted, h: 2))),
          ]),
        MiniBody.tiles => GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 3,
            crossAxisSpacing: 3,
            childAspectRatio: 1.7,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            children: [
              for (var i = 0; i < 4; i++)
                _card(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                          color: C.orange.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(_r(2))),
                    ),
                    const Spacer(),
                    _bar(16, p.text, h: 2),
                  ]),
                ),
            ],
          ),
        MiniBody.list => Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(
              width: 22,
              child: Column(children: [
                for (var i = 0; i < 4; i++) ...[
                  Container(
                    height: 7,
                    decoration: BoxDecoration(
                      color: i == 0 ? C.orange.withValues(alpha: 0.35) : p.surface2,
                      borderRadius: BorderRadius.circular(_r(2)),
                    ),
                  ),
                  const SizedBox(height: 3),
                ],
              ]),
            ),
            const SizedBox(width: 3),
            Expanded(
              child: _card(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (var i = 0; i < 4; i++) ...[_bar(i.isEven ? 30 : 22, i == 0 ? p.text : p.muted, h: 2), const SizedBox(height: 4)],
                ]),
              ),
            ),
          ]),
      };

  @override
  Widget build(BuildContext context) {
    final items = [for (var i = 0; i < 4; i++) _bar(navTop ? 9 : 12, i == 0 ? C.orange : p.markMuted, h: 2.5)];
    final nav = navTop
        ? Container(
            height: 12,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            color: p.surface,
            child: Row(children: [for (final b in items) ...[b, const SizedBox(width: 5)]]),
          )
        : Container(
            width: 24,
            padding: const EdgeInsets.fromLTRB(5, 6, 5, 6),
            color: p.surface,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final b in items) ...[b, const SizedBox(height: 5)],
            ]),
          );
    final content = Expanded(child: Padding(padding: const EdgeInsets.all(5), child: _content()));
    return Container(
      color: p.bg,
      child: navTop
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [nav, content])
          : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [nav, content]),
    );
  }
}

/// «Как в Windows»: окошко наполовину тёмное, наполовину светлое (по диагонали).
class MiniSystemTheme extends StatelessWidget {
  const MiniSystemTheme({super.key});

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
        const MiniWindow(p: Palette.dark),
        ClipPath(clipper: _Diagonal(), child: const MiniWindow(p: Palette.light)),
      ]);
}

class _Diagonal extends CustomClipper<Path> {
  @override
  Path getClip(Size size) => Path()
    ..moveTo(size.width * 0.62, 0)
    ..lineTo(size.width, 0)
    ..lineTo(size.width, size.height)
    ..lineTo(size.width * 0.38, size.height)
    ..close();

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}
