import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets.dart';

/// Пункт всплывающего меню: значок, подпись, отметка выбранного.
class AppMenuItem<T> {
  const AppMenuItem(this.value, this.label,
      {this.icon, this.danger = false, this.checked = false, this.hint, this.description})
      : divider = false;

  /// Тонкая линия-разделитель между группами пунктов.
  const AppMenuItem.divider()
      : value = null,
        label = '',
        icon = null,
        danger = false,
        checked = false,
        hint = null,
        description = null,
        divider = true;

  final T? value;
  final String label;
  final IconData? icon;

  /// Опасное действие (удаление) — красным.
  final bool danger;

  /// Галочка справа — текущий выбор в списках.
  final bool checked;

  /// Серая подпись справа (например, сочетание клавиш).
  final String? hint;

  /// Пояснение: что это и как работает. Показывается внизу меню — у пункта под мышью, иначе у выбранного.
  final String? description;
  final bool divider;
}

/// Всплывающее меню в стиле приложения. Появляется под виджетом [context] (правый край к правому краю,
/// как у кнопок «…»), либо у точки [at] — для меню по правому клику. [matchWidth] — меню не уже
/// самого виджета и выровнено по левому краю (выпадающие списки). [centered] — меню стоит по центру
/// под виджетом (маленькие кнопки-переключатели посреди экрана).
Future<T?> showAppMenu<T>(
  BuildContext context, {
  required List<AppMenuItem<T>> items,
  Offset? at,
  bool matchWidth = false,
  bool centered = false,
}) {
  final box = context.findRenderObject() as RenderBox;
  final anchor = at != null ? (at & Size.zero) : (box.localToGlobal(Offset.zero) & box.size);
  return Navigator.of(context, rootNavigator: true).push(_MenuRoute<T>(
    items: items,
    anchor: anchor,
    alignRight: at == null && !matchWidth && !centered,
    centered: centered,
    minWidth: matchWidth ? anchor.width : 0,
  ));
}

class _MenuRoute<T> extends PopupRoute<T> {
  _MenuRoute({
    required this.items,
    required this.anchor,
    required this.alignRight,
    required this.centered,
    required this.minWidth,
  });
  final List<AppMenuItem<T>> items;
  final Rect anchor;
  final bool alignRight;
  final bool centered;
  final double minWidth;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Закрыть меню';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 110);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    // Только плавное проявление, без изменения размера и сдвига: иначе меню при открытии «скачет».
    return CustomSingleChildLayout(
      delegate: _MenuLayout(anchor, alignRight, centered),
      child: FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: _MenuCard<T>(items: items, minWidth: minWidth),
      ),
    );
  }
}

/// Меню под виджетом; если снизу не помещается — над ним. За края окна не выходит.
class _MenuLayout extends SingleChildLayoutDelegate {
  _MenuLayout(this.anchor, this.alignRight, this.centered);
  final Rect anchor;
  final bool alignRight;
  final bool centered;

  static const _margin = 8.0;
  static const _gap = 6.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(Size(constraints.maxWidth - _margin * 2, constraints.maxHeight - _margin * 2));

  @override
  Offset getPositionForChild(Size size, Size child) {
    var x = centered
        ? anchor.center.dx - child.width / 2
        : (alignRight ? anchor.right - child.width : anchor.left);
    var y = anchor.bottom + _gap;
    if (y + child.height > size.height - _margin && anchor.top - _gap - child.height >= _margin) {
      y = anchor.top - _gap - child.height;
    }
    x = x.clamp(_margin, (size.width - child.width - _margin).clamp(_margin, double.infinity));
    y = y.clamp(_margin, (size.height - child.height - _margin).clamp(_margin, double.infinity));
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MenuLayout old) =>
      old.anchor != anchor || old.alignRight != alignRight || old.centered != centered;
}

class _MenuCard<T> extends StatefulWidget {
  const _MenuCard({required this.items, required this.minWidth});
  final List<AppMenuItem<T>> items;
  final double minWidth;

  @override
  State<_MenuCard<T>> createState() => _MenuCardState<T>();
}

class _MenuCardState<T> extends State<_MenuCard<T>> {
  AppMenuItem<T>? _hovered;

  List<AppMenuItem<T>> get items => widget.items;
  double get minWidth => widget.minWidth;

  /// Строка пояснений внизу меню: постоянного размера, чтобы меню не меняло размер при наведении.
  Widget _description() {
    final shown = _hovered?.description ?? items.where((i) => i.checked).firstOrNull?.description;
    return Padding(
      padding: const EdgeInsets.fromLTRB(9, 4, 9, 4),
      child: SizedBox(
        width: 280,
        height: 50,
        child: Text(shown ?? '',
            maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, height: 1.35, color: C.muted)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Material(
        type: MaterialType.transparency,
        child: Container(
          constraints: BoxConstraints(minWidth: minWidth < 190 ? 190 : minWidth, maxWidth: 380),
          decoration: BoxDecoration(
            color: C.surface2,
            borderRadius: BorderRadius.circular(C.r(14)),
            border: Border.all(color: C.border),
            boxShadow: [BoxShadow(color: C.palette.shadow, blurRadius: 28, offset: const Offset(0, 10))],
          ),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(5),
            child: IntrinsicWidth(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                for (final item in items)
                  if (item.divider)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                      child: Container(height: 1, color: C.border),
                    )
                  else
                    MouseRegion(
                      onEnter: (_) => setState(() => _hovered = item),
                      onExit: (_) => setState(() => _hovered = _hovered == item ? null : _hovered),
                      child: _MenuRow<T>(item: item),
                    ),
                if (items.any((i) => i.description != null)) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                    child: Container(height: 1, color: C.border),
                  ),
                  _description(),
                ],
              ]),
            ),
          ),
        ),
      );
}

class _MenuRow<T> extends StatelessWidget {
  const _MenuRow({required this.item});
  final AppMenuItem<T> item;

  @override
  Widget build(BuildContext context) {
    final accent = item.danger ? C.red : C.orange;
    return Hover(
      builder: (context, hovered) {
        final color = item.danger ? C.red : (hovered || item.checked ? C.text : C.text.withValues(alpha: 0.82));
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).pop(item.value),
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            decoration: BoxDecoration(
              color: hovered ? accent.withValues(alpha: 0.13) : Colors.transparent,
              borderRadius: BorderRadius.circular(C.r(9)),
            ),
            child: Row(children: [
              if (item.icon != null) ...[
                Icon(item.icon, size: 16, color: hovered || item.danger ? accent : C.muted),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: color)),
              ),
              if (item.hint != null) ...[
                const SizedBox(width: 18),
                Text(item.hint!, style: TextStyle(fontSize: 11.5, color: C.muted)),
              ],
              if (item.checked) ...[
                const SizedBox(width: 14),
                Icon(Icons.check_rounded, size: 16, color: C.orange),
              ],
            ]),
          ),
        );
      },
    );
  }
}
