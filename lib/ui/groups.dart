import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets.dart';

// Плитки групп, вид «Списком» и закреплённый заголовок со стрелкой назад — общие у «Настроек» и «Логов».

/// Вид «Списком»: слева — группы раздела (как в «Параметрах» Windows), справа — [child] с содержимым
/// выбранной. Список групп не прокручивается вместе с содержимым; в узком окне от него остаются значки.
/// [groups] = null — обычный вид, [child] на всю ширину.
/// Смена страниц в «Настройках» и «Логах»: старая гаснет, новая проявляется (чуть внахлёст) и доезжает
/// [shift] точек по вертикали. Время у перехода идёт ровно, кривые — внутри: с кривой на самом переходе
/// новая страница к началу проявления была уже почти на месте и почти непрозрачной — смена выглядела рывком.
const pageSwitchDuration = Duration(milliseconds: 420);

Widget pageSwitchTransition(Widget child, Animation<double> anim, {double shift = 0}) {
  final fade = CurvedAnimation(parent: anim, curve: const Interval(0.3, 1, curve: Curves.easeOut));
  final move = CurvedAnimation(parent: anim, curve: const Interval(0.15, 1, curve: Curves.easeOutCubic));
  final faded = FadeTransition(opacity: fade, child: child);
  if (shift == 0) return faded;
  return AnimatedBuilder(
    animation: move,
    builder: (context, child) => Transform.translate(offset: Offset(0, shift * (1 - move.value)), child: child),
    child: faded,
  );
}

class GroupListLayout extends StatefulWidget {
  const GroupListLayout(
      {super.key, required this.groups, required this.selected, required this.onSelect, required this.child});
  final List<PageGroup>? groups;
  final int selected;
  final ValueChanged<int> onSelect;
  final Widget child;

  @override
  State<GroupListLayout> createState() => _GroupListLayoutState();
}

class _GroupListLayoutState extends State<GroupListLayout> {
  /// Группы, пока колонка уезжает после переключения на «Плитки».
  List<PageGroup>? _last;

  @override
  Widget build(BuildContext context) {
    final list = widget.groups;
    if (list != null) _last = list;
    final shown = _last;
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 820;
      final width = 28 + (wide ? 220.0 : 44.0);
      // Колонка групп при смене вида «Плитки / Списком» выезжает и прячется плавно, а содержимое справа
      // остаётся тем же виджетом: раньше оно пересоздавалось, и всё выскакивало сразу.
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TweenAnimationBuilder<double>(
          tween: Tween(end: list == null ? 0 : 1),
          duration: pageSwitchDuration,
          curve: Curves.easeOutCubic,
          builder: (context, t, _) => t == 0 || shown == null
              ? const SizedBox.shrink()
              : ClipRect(
                  child: SizedBox(
                    width: width * t,
                    child: OverflowBox(
                      alignment: Alignment.topRight,
                      minWidth: width,
                      maxWidth: width,
                      child: Opacity(
                        opacity: t,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(28, 2, 0, 0),
                          child: Column(children: [
                            for (var i = 0; i < shown.length; i++)
                              GroupNavItem(
                                group: shown[i],
                                selected: i == widget.selected,
                                showLabel: wide,
                                onTap: () => widget.onSelect(i),
                              ),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
        Expanded(child: widget.child),
      ]);
    });
  }
}

class GroupNavItem extends StatelessWidget {
  const GroupNavItem(
      {super.key, required this.group, required this.selected, required this.showLabel, required this.onTap});
  final PageGroup group;
  final bool selected;
  final bool showLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Tooltip(
          message: showLabel ? '' : group.title,
          waitDuration: const Duration(milliseconds: 300),
          child: Hover(
            builder: (context, hovered) => GestureDetector(
              onTap: onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(C.r(12)),
                  color: selected
                      ? C.orange.withValues(alpha: 0.14)
                      : (hovered ? C.hover : Colors.transparent),
                ),
                child: Row(children: [
                  Icon(group.icon, size: 20, color: selected || hovered ? C.orange : C.muted),
                  if (showLabel) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(group.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: selected || hovered ? C.text : C.muted)),
                    ),
                    if (group.alert != null)
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: group.alert, shape: BoxShape.circle),
                      ),
                  ],
                ]),
              ),
            ),
          ),
        ),
      );
}

/// Группа раздела: плитка на его первой странице и своя страница (или пункт слева в виде «Списком»).
class PageGroup {
  const PageGroup(this.icon, this.title, this.description, this.summary, {this.alert});
  final IconData icon;
  final String title;

  /// Что лежит в группе — описание на плитке.
  final String description;

  /// Коротко, что сейчас в группе, — подпись плитки.
  final String summary;

  /// Цвет отметки на плитке, если в группе есть что-то важное (доступно обновление, ядро не найдено).
  final Color? alert;
}

/// Плитки групп: три в ряд, в узком окне — две.
class GroupGrid extends StatelessWidget {
  const GroupGrid({super.key, required this.groups, required this.onOpen});
  final List<PageGroup> groups;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(28, 4, 28, 18),
        child: LayoutBuilder(builder: (context, c) {
          const gap = 14.0;
          final columns = c.maxWidth >= 720 ? 3 : 2;
          final width = ((c.maxWidth - gap * (columns - 1)) / columns).floorToDouble();
          return Wrap(spacing: gap, runSpacing: gap, children: [
            for (var i = 0; i < groups.length; i++)
              SizedBox(width: width, child: GroupTile(group: groups[i], onTap: () => onOpen(i))),
          ]);
        }),
      );
}

class GroupTile extends StatelessWidget {
  const GroupTile({super.key, required this.group, required this.onTap});
  final PageGroup group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Hover(
        builder: (context, hovered) => GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: 172,
            padding: const EdgeInsets.fromLTRB(18, 18, 14, 16),
            decoration: BoxDecoration(
              color: hovered ? Color.alphaBlend(C.hover, C.surface) : C.surface,
              borderRadius: BorderRadius.circular(C.r(18)),
              border: Border.all(color: hovered ? C.orange.withValues(alpha: 0.6) : C.border),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: C.orange.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(C.r(12)),
                  ),
                  child: Icon(group.icon, size: 22, color: C.orange),
                ),
                const Spacer(),
                if (group.alert != null)
                  Container(
                    width: 9,
                    height: 9,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(color: group.alert, shape: BoxShape.circle),
                  ),
                Icon(Icons.chevron_right_rounded, color: hovered ? C.orange : C.muted),
              ]),
              const Spacer(),
              Text(group.title, maxLines: 1, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(group.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: C.muted, fontSize: 12.5, height: 1.3)),
              const SizedBox(height: 8),
              // Что сейчас выбрано — одной строкой, акцентным цветом.
              Text(group.summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: C.isDark ? C.orangeLight : C.orange, fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );
}

/// Заголовок раздела с группами — один на плитки и страницы групп: высота и место [trailing] (поле поиска,
/// кнопки) не меняются, поэтому при переходах ничего не прыгает. В группе слева плавно выезжает стрелка
/// назад, а название раздела [page] с подписью сменяется на то же название мелко над названием группы.
class GroupHeader extends StatelessWidget {
  const GroupHeader({
    super.key,
    required this.page,
    required this.backTooltip,
    required this.group,
    required this.hint,
    required this.trailing,
    required this.onBack,
  });
  final String page;
  final String backTooltip;
  final PageGroup? group;
  final String hint;
  final Widget trailing;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final g = group;
    final back = Padding(
      padding: const EdgeInsets.only(right: 14),
      child: Tooltip(
        message: backTooltip,
        child: Hover(
          builder: (context, hovered) => GestureDetector(
            onTap: onBack,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: hovered ? C.orange.withValues(alpha: 0.14) : C.surface2,
                shape: BoxShape.circle,
                border: Border.all(color: hovered ? C.orange.withValues(alpha: 0.6) : C.border),
              ),
              child: Icon(Icons.arrow_back_rounded, size: 20, color: hovered ? C.orange : C.muted),
            ),
          ),
        ),
      ),
    );
    const big = TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: -0.5, height: 1.2);
    // Название раздела плавно уменьшается из заголовка в надпись над группой (и обратно), а строка под ним —
    // подпись страницы или название группы — выезжает снизу и проявляется; высота строк меняется плавно.
    final title = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // В группе название раздела — тоже путь назад к плиткам, как стрелка.
        Hover(
          enabled: g != null,
          builder: (context, hovered) => GestureDetector(
            onTap: g == null ? null : onBack,
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              // На основе общего стиля: иначе у надписи пропал бы шрифт программы.
              style: DefaultTextStyle.of(context).style.merge(g == null
                  ? big.copyWith(color: C.text)
                  : TextStyle(
                      color: hovered ? C.orange : C.muted,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0,
                      height: 1.2)),
              child: Text(page, maxLines: 1),
            ),
          ),
        ),
        const SizedBox(height: 2),
        AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          height: g == null ? 17 : 34,
          clipBehavior: Clip.hardEdge,
          decoration: const BoxDecoration(),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (current, previous) =>
                Stack(alignment: Alignment.topLeft, children: [...previous, if (current != null) current]),
            // Старая строка гаснет за первую половину, новая выезжает и проявляется во второй — не накладываются.
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: CurvedAnimation(parent: anim, curve: const Interval(0.45, 1)),
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.35), end: Offset.zero).animate(anim),
                child: child,
              ),
            ),
            child: g == null
                ? Text(hint,
                    key: const ValueKey('hint'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: C.muted, fontSize: 13, height: 1.3))
                : Text(g.title, key: ValueKey(g.title), maxLines: 1, overflow: TextOverflow.ellipsis, style: big),
          ),
        ),
      ],
    );
    final heading = SizedBox(
      height: 58,
      child: Row(children: [
        // Место под стрелку растёт, а сама круглая кнопка не обрезается: она проявляется и подрастает
        // из своего центра (обрезка по прямоугольнику показывала её «квадратом»).
        TweenAnimationBuilder<double>(
          tween: Tween(end: g == null ? 0 : 1),
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          child: back,
          builder: (context, t, child) => t == 0
              ? const SizedBox.shrink()
              : SizedBox(
                  width: 54 * t,
                  height: 40,
                  child: OverflowBox(
                    alignment: Alignment.centerLeft,
                    minWidth: 54,
                    maxWidth: 54,
                    child: Opacity(
                      opacity: t,
                      child: Transform.scale(scale: 0.7 + 0.3 * t, alignment: const Alignment(-0.26, 0), child: child),
                    ),
                  ),
                ),
        ),
        Expanded(child: title),
      ]),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 22, 28, 14),
      child: LayoutBuilder(
        builder: (context, c) => c.maxWidth >= 680
            ? Row(children: [Expanded(child: heading), trailing])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [heading, const SizedBox(height: 14), trailing]),
      ),
    );
  }
}
