import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/core_manager.dart';
import '../core/log_explain.dart';
import '../core/paths.dart';
import '../core/util.dart';
import '../state/app_scope.dart';
import 'app_menu.dart';
import 'flag_text.dart';
import 'smooth_scroll.dart';
import 'theme.dart';
import 'widgets.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

/// Фильтр строк: события приложения отдельно от вывода ядер.
enum _LogTab { all, app, xray, singbox, connections }

extension on _LogTab {
  String get label => switch (this) {
        _LogTab.all => 'Все',
        _LogTab.app => 'Приложение',
        _LogTab.xray => 'Xray',
        _LogTab.singbox => 'sing-box',
        _LogTab.connections => 'Соединения',
      };

  bool matches(String source) => switch (this) {
        _LogTab.all => true,
        _LogTab.xray => source == 'xray' || source == 'test',
        _LogTab.singbox => source == 'sing-box',
        // Соединения — отдельный список (LogSession.connections), а не строки журнала.
        _LogTab.connections => false,
        _LogTab.app => source != 'xray' && source != 'test' && source != 'sing-box',
      };
}

String _two(int n) => n.toString().padLeft(2, '0');
String _clock(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

const _months = [
  'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
  'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
];

/// «Сегодня», «Вчера» или «29 сентября».
String _dayLabel(DateTime day) {
  final now = DateTime.now();
  final diff = DateTime(now.year, now.month, now.day).difference(DateTime(day.year, day.month, day.day)).inDays;
  if (diff == 0) return 'Сегодня';
  if (diff == 1) return 'Вчера';
  return '${day.day} ${_months[day.month - 1]}';
}

/// Длительность отрезка коротко: «меньше минуты», «44 мин», «2 ч 5 мин».
String _span(Duration d) {
  if (d.inMinutes < 1) return 'меньше минуты';
  if (d.inHours < 1) return '${d.inMinutes} мин';
  final m = d.inMinutes % 60;
  return m == 0 ? '${d.inHours} ч' : '${d.inHours} ч $m мин';
}

class _LogsPageState extends State<LogsPage> {
  _LogTab _tab = _LogTab.all;

  /// Фильтр вкладки «Соединения» по пути; null — все.
  ConnRoute? _route;

  /// В «Соединениях» показывать только то, к чему обращались за последнюю минуту.
  bool _recent = true;

  /// Фильтр строк журнала: 2 — только ошибки, 1 — только предупреждения, null — все.
  int? _level;

  /// Развёрнутые группы одинаковых соединений (см. [ConnGroup.key]).
  final _open = <String>{};

  /// Список «за последнюю минуту» должен редеть и тогда, когда новых соединений нет.
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && _tab == _LogTab.connections && _recent) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  /// Отрезок, выбранный пользователем. null — показываем самый свежий и следуем за новыми.
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final log = state.log;
    return ListenableBuilder(
      listenable: log,
      builder: (context, _) {
        final sessions = log.sessions;
        final selected = sessions.where((s) => s.id == _selectedId).firstOrNull ?? sessions.lastOrNull;
        if (selected != null && selected.lines == null) log.load(selected);

        return Column(children: [
          PageHeader(
            'Логи',
            subtitle: 'Журнал разбит по подключениям и хранится ${LogBuffer.keepDays} дней. '
                'Под строками ядра — пояснения простыми словами',
            actions: [
              GhostButton(
                label: 'Папка',
                icon: Icons.folder_open_rounded,
                onPressed: () => Process.run('explorer', [AppPaths.logDir.path]),
              ),
              // Builder: меню выбора появляется под самой кнопкой.
              Builder(
                builder: (context) => GhostButton(
                  label: 'Очистить историю',
                  icon: Icons.delete_sweep_rounded,
                  onPressed: sessions.any((s) => !s.live)
                      ? () async {
                          // Дни, за которые есть прошлые журналы, свежие сверху.
                          final days = <DateTime>[];
                          for (final s in sessions.reversed.where((s) => !s.live)) {
                            final day = DateTime(s.start.year, s.start.month, s.start.day);
                            if (!days.contains(day)) days.add(day);
                          }
                          // 0 — за всё время, дальше — номер дня в списке плюс один.
                          final picked = await showAppMenu<int>(context, items: [
                            const AppMenuItem(0, 'За всё время', icon: Icons.delete_sweep_rounded, danger: true),
                            const AppMenuItem.divider(),
                            for (final (i, day) in days.indexed) AppMenuItem(i + 1, _dayLabel(day)),
                          ]);
                          if (picked == null || !context.mounted) return;
                          final day = picked == 0 ? null : days[picked - 1];
                          final ok = day == null
                              ? await confirm(context, 'Очистить историю?',
                                  'Журналы прошлых подключений будут удалены. Текущий журнал останется.')
                              : await confirm(context, 'Удалить журналы за ${_dayLabel(day).toLowerCase()}?',
                                  // Текущий журнал начат сегодня — про него есть смысл говорить только тут.
                                  _dayLabel(day) == 'Сегодня'
                                      ? 'Все журналы за сегодня, кроме текущего, будут удалены.'
                                      : 'Все журналы за этот день будут удалены.');
                          if (!ok) return;
                          setState(() => _selectedId = null);
                          log.clearHistory(day: day);
                        }
                      : null,
                ),
              ),
            ],
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
              child: sessions.isEmpty
                  ? _card(Center(child: Text('Здесь пока пусто', style: TextStyle(color: C.muted))))
                  : LayoutBuilder(
                      builder: (context, c) => Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        SizedBox(
                          width: c.maxWidth < 860 ? 250 : 310,
                          child: _card(_SessionList(
                            sessions: sessions,
                            selected: selected,
                            onSelect: (s) => setState(() => _selectedId = identical(s, sessions.last) ? null : s.id),
                          )),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: _card(_SessionView(
                            session: selected!,
                            tab: _tab,
                            onTab: (t) => setState(() => _tab = t),
                            route: _route,
                            onRoute: (r) => setState(() => _route = r),
                            recent: _recent,
                            onRecent: (v) => setState(() => _recent = v),
                            level: _level,
                            onLevel: (v) => setState(() => _level = v),
                            open: _open,
                            onToggle: (key) => setState(() => _open.remove(key) || _open.add(key)),
                            onCopied: () => state.toast('Журнал скопирован'),
                            onDelete: () {
                              setState(() => _selectedId = null);
                              log.remove(selected);
                            },
                          )),
                        ),
                      ]),
                    ),
            ),
          ),
        ]);
      },
    );
  }

  Widget _card(Widget child) => Container(
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: C.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      );
}

/// Слева: отрезки журнала по дням, свежие сверху. Каждый день сворачивается кликом по заголовку;
/// по умолчанию развёрнут только сегодняшний.
class _SessionList extends StatefulWidget {
  const _SessionList({required this.sessions, required this.selected, required this.onSelect});
  final List<LogSession> sessions;
  final LogSession? selected;
  final ValueChanged<LogSession> onSelect;

  @override
  State<_SessionList> createState() => _SessionListState();
}

class _SessionListState extends State<_SessionList> {
  /// Дни, которые пользователь развернул или свернул сам (ключ — дата). Остальные — по умолчанию.
  final _opened = <String, bool>{};

  static String _key(DateTime d) => '${d.year}-${d.month}-${d.day}';

  @override
  Widget build(BuildContext context) {
    // Отрезки по дням, свежие сверху.
    final days = <(DateTime, List<LogSession>)>[];
    for (final s in widget.sessions.reversed) {
      if (days.isEmpty || _key(days.last.$1) != _key(s.start)) days.add((s.start, []));
      days.last.$2.add(s);
    }
    final today = _key(DateTime.now());
    final rows = <Widget>[
      for (final (day, list) in days)
        _DayGroup(
          key: ValueKey(_key(day)),
          label: _dayLabel(day),
          count: list.length,
          first: identical(list, days.first.$2),
          open: _opened[_key(day)] ?? _key(day) == today,
          onToggle: (open) => setState(() => _opened[_key(day)] = open),
          selectedIndex: list.indexWhere((s) => identical(s, widget.selected)),
          children: [
            for (final s in list)
              _SessionTile(session: s, selected: identical(s, widget.selected), onTap: () => widget.onSelect(s)),
          ],
        ),
    ];
    // Свой контроллер плавной прокрутки: основной контроллер страницы занят списком строк справа.
    return SmoothScroll(
      builder: (context, controller) =>
          ListView(controller: controller, padding: const EdgeInsets.only(bottom: 10), children: rows),
    );
  }
}

/// Журналы одного дня: заголовок-переключатель и плавно раскрывающийся список отрезков.
class _DayGroup extends StatefulWidget {
  const _DayGroup({
    super.key,
    required this.label,
    required this.count,
    required this.first,
    required this.open,
    required this.onToggle,
    required this.selectedIndex,
    required this.children,
  });
  final String label;
  final int count;
  final bool first;
  final bool open;
  final ValueChanged<bool> onToggle;

  /// Номер выбранного журнала в этом дне; -1 — выбран журнал другого дня.
  final int selectedIndex;
  final List<Widget> children;

  @override
  State<_DayGroup> createState() => _DayGroupState();
}

class _DayGroupState extends State<_DayGroup> {
  /// Где подсветка стояла в последний раз: там она и гаснет, когда выбран журнал другого дня.
  int _last = 0;

  String get label => widget.label;
  int get count => widget.count;
  bool get first => widget.first;
  bool get open => widget.open;
  ValueChanged<bool> get onToggle => widget.onToggle;

  /// Подсветка скользит, только когда выбор переходит между журналами этого же дня. Если до этого
  /// был выбран журнал другого дня, она сразу проявляется на нажатой строке, а не едет к ней
  /// от места, где стояла когда-то раньше.
  bool _slide = false;

  @override
  void didUpdateWidget(_DayGroup old) {
    super.didUpdateWidget(old);
    if (old.selectedIndex != widget.selectedIndex) _slide = old.selectedIndex >= 0 && widget.selectedIndex >= 0;
  }

  @override
  Widget build(BuildContext context) {
    final here = widget.selectedIndex >= 0;
    if (here) _last = widget.selectedIndex;
    return _build(context, here);
  }

  Widget _build(BuildContext context, bool here) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Заголовок дня — отдельная плашка: видно, что на неё можно нажать. Если выбранный журнал
        // спрятан внутри свёрнутого дня, плашка отмечена оранжевым.
        Hover(
          builder: (context, hovered) {
            final marked = here && !open;
            final accent = marked ? C.orange : (hovered ? C.text : C.muted);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onToggle(!open),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                margin: EdgeInsets.fromLTRB(8, first ? 8 : 4, 8, 4),
                padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
                decoration: BoxDecoration(
                  // Наведение — поверх того же фона, непрозрачным цветом: при переходе от непрозрачного
                  // к почти прозрачному белому середина перехода вспыхивала светло-серым.
                  color: hovered ? Color.alphaBlend(C.hover, C.surface2) : C.surface2,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: marked ? C.orange.withValues(alpha: 0.55) : C.border),
                ),
                child: Row(children: [
                  Expanded(
                    child: Text(label.toUpperCase(),
                        style: TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
                  ),
                  // Сколько журналов в этом дне.
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                    decoration: BoxDecoration(
                      color: (marked ? C.orange : C.muted).withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('$count',
                        style: TextStyle(color: marked ? C.orange : C.muted, fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    child: Icon(Icons.expand_more_rounded, size: 18, color: hovered || marked ? C.orange : C.muted),
                  ),
                ]),
              ),
            );
          },
        ),
        Reveal(
          open: open,
          extent: count * _SessionTile.height,
          // Подсветка выбранного журнала — одна на день и «скользит» к новому, как в боковом меню.
          child: Stack(fit: StackFit.passthrough, children: [
            AnimatedPositioned(
              duration: Duration(milliseconds: _slide ? 240 : 0),
              curve: Curves.easeOutCubic,
              top: _last * _SessionTile.height,
              left: 0,
              right: 0,
              height: _SessionTile.height,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: here ? 1 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: Container(
                    alignment: Alignment.centerLeft,
                    color: C.orange.withValues(alpha: 0.10),
                    // Оранжевая метка слева — как у выбранного сервера на главной.
                    child: Container(width: 3, color: C.orange),
                  ),
                ),
              ),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.children),
          ]),
        ),
      ]);
}
class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, required this.selected, required this.onTap});
  final LogSession session;
  final bool selected;
  final VoidCallback onTap;

  static const height = 56.0;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final (country, name) = Flags.leading(s.title);
    final time = s.live ? 'с ${_clock(s.start)}' : '${_clock(s.start)} – ${_clock(s.end)}';
    return Hover(
      builder: (context, hovered) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          // Фон и метку выбранного отрезка рисует скользящая подсветка дня (см. _DayGroup).
          color: !selected && hovered ? C.hover : Colors.transparent,
          child: Row(children: [
            const SizedBox(width: 3, height: height),
            const SizedBox(width: 11),
            if (!s.connection)
              _RoundIcon(Icons.more_horiz_rounded)
            else if (country != null)
              FlagIcon.round(country, size: 26)
            else
              _RoundIcon(Icons.public_rounded),
            const SizedBox(width: 11),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                FlagText(s.connection ? name : s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5,
                      color: s.connection ? C.text : C.muted,
                    )),
                const SizedBox(height: 3),
                Row(children: [
                  if (s.live) ...[
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(color: C.green, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      [time, if (s.detail.isNotEmpty) s.detail].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: C.muted, fontSize: 11.5, fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ),
                ]),
              ]),
            ),
            if (s.errors > 0) _Count(s.errors, C.red, 'Ошибок: ${s.errors}'),
            if (s.warnings > 0) _Count(s.warnings, C.isDark ? C.orangeLight : C.orange, 'Предупреждений: ${s.warnings}'),
            const SizedBox(width: 12),
          ]),
        ),
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon(this.icon);
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(color: C.surface2, shape: BoxShape.circle, border: Border.all(color: C.border)),
        child: Icon(icon, size: 15, color: C.muted),
      );
}

/// Счётчик ошибок или предупреждений в отрезке.
class _Count extends StatelessWidget {
  const _Count(this.value, this.color, this.tooltip);
  final int value;
  final Color color;
  final String tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Container(
          margin: const EdgeInsets.only(left: 6),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
          child: Text(value > 99 ? '99+' : '$value',
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
        ),
      );
}

/// Справа: шапка выбранного отрезка и его строки.
class _SessionView extends StatelessWidget {
  const _SessionView({
    required this.session,
    required this.tab,
    required this.onTab,
    required this.route,
    required this.onRoute,
    required this.recent,
    required this.onRecent,
    required this.level,
    required this.onLevel,
    required this.open,
    required this.onToggle,
    required this.onCopied,
    required this.onDelete,
  });
  final LogSession session;
  final _LogTab tab;
  final ValueChanged<_LogTab> onTab;
  final ConnRoute? route;
  final ValueChanged<ConnRoute?> onRoute;
  final bool recent;
  final ValueChanged<bool> onRecent;
  final int? level;
  final ValueChanged<int?> onLevel;
  final Set<String> open;
  final ValueChanged<String> onToggle;
  final VoidCallback onCopied;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final all = s.lines;
    final tabLines = (all ?? const <LogLine>[]).where((l) => tab.matches(l.source)).toList();
    final lines = level == null ? tabLines : tabLines.where((l) => l.level == level).toList();
    final stored = s.connections;
    // «Последняя минута» есть только у идущего подключения: в прошлом отрезке показывать было бы нечего.
    final recentOnly = recent && s.live;
    final since = DateTime.now().subtract(const Duration(minutes: 1));
    final window = recentOnly ? stored.where((c) => c.time.isAfter(since)).toList() : stored;
    final conns = route == null ? window : window.where((c) => c.route == route).toList();
    // Числа на кнопках: за последнюю минуту — по тому, что в списке, иначе — за весь отрезок.
    int count(ConnRoute? r) => recentOnly
        ? (r == null ? window.length : window.where((c) => c.route == r).length)
        : (r == null ? s.connectionsTotal : s.connectionCounts[r] ?? 0);
    final showConns = tab == _LogTab.connections;
    final when = '${_dayLabel(s.start)}, ${_clock(s.start)}'
        '${s.live ? ' · идёт сейчас' : ' – ${_clock(s.end)} · ${_span(s.end.difference(s.start))}'}'
        '${s.detail.isNotEmpty ? ' · ${s.detail}' : ''}';

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 10, 12),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              FlagText(s.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 3),
              Text(when, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: C.muted, fontSize: 12)),
            ]),
          ),
          IconButton(
            tooltip: 'Скопировать',
            icon: Icon(Icons.copy_rounded, size: 18, color: C.muted),
            onPressed: (showConns ? conns.isEmpty : lines.isEmpty)
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(
                        text: showConns
                            ? conns.map(_connLine).join('\n')
                            : lines
                                .map((l) => '${l.time.toIso8601String()} [${l.source}] ${l.text}'
                                    '${l.repeats > 1 ? '  ×${l.repeats}' : ''}')
                                .join('\n')));
                    onCopied();
                  },
          ),
          if (!s.live)
            IconButton(
              tooltip: 'Удалить этот журнал',
              icon: Icon(Icons.delete_outline_rounded, size: 19, color: C.muted),
              onPressed: onDelete,
            ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        child: Align(
          alignment: Alignment.centerLeft,
          // В узком окне пять вкладок не помещаются — переключатель слегка уменьшается.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Segmented<_LogTab>(
              value: tab,
              items: {
                for (final t in _LogTab.values)
                  t: '${t.label}  ${t == _LogTab.connections ? s.connectionsTotal : (all ?? const <LogLine>[]).where((l) => t.matches(l.source)).length}',
              },
              onChanged: onTab,
            ),
          ),
        ),
      ),
      // Фильтр соединений по пути и по времени. В списке всего отрезка — только последние соединения.
      if (showConns && stored.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: Align(
            alignment: Alignment.centerLeft,
            // В узком окне кнопки переносятся на вторую строку.
            child: Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              _Chip('Все', count(null), C.text, route == null, () => onRoute(null)),
              for (final r in const [ConnRoute.proxy, ConnRoute.direct, ConnRoute.block])
                _Chip(_routeTitle(r), count(r), _routeColor(r), route == r, () => onRoute(r)),
              if (s.live) ...[
                Container(width: 1, height: 18, color: C.border),
                _Chip('Последняя минута', null, C.orange, recent, () => onRecent(!recent)),
              ],
              if (!recentOnly && s.connectionsTotal > stored.length)
                Text('в списке — последние ${stored.length}', style: TextStyle(color: C.muted, fontSize: 11.5)),
              if (s.unknownProcess > 0)
                Tooltip(
                  message: 'Для этих соединений ядро не смогло узнать, какая программа их открыла, и правила '
                      'по приложениям к ним не применились.\nОбычно это службы Windows. Но если игра из списка '
                      '«напрямую» идёт через VPN — причина в этом: её соединения помечены в списке.',
                  waitDuration: const Duration(milliseconds: 300),
                  // Счёт идёт по сообщениям ядра, а их на одно соединение бывает несколько — поэтому
                  // «раз», а не «соединений».
                  child: Text(
                      'ядро не узнало программу: ${s.unknownProcess} ${plural(s.unknownProcess, 'раз', 'раза', 'раз')}',
                      style: TextStyle(color: C.isDark ? C.orangeLight : C.orange, fontSize: 11.5)),
                ),
            ]),
          ),
        ),
      // Фильтр строк журнала: только ошибки или только предупреждения.
      if (!showConns && tabLines.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              _Chip('Все', tabLines.length, C.text, level == null, () => onLevel(null)),
              _Chip('Ошибки', tabLines.where((l) => l.level == 2).length, C.red, level == 2, () => onLevel(2)),
              _Chip('Предупреждения', tabLines.where((l) => l.level == 1).length,
                  C.isDark ? C.orangeLight : C.orange, level == 1, () => onLevel(1)),
            ]),
          ),
        ),
      Divider(height: 1, color: C.border),
      Expanded(
        child: showConns
            ? (conns.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        stored.isNotEmpty
                            ? (recentOnly
                                ? 'За последнюю минуту таких соединений не было'
                                : 'Среди последних ${stored.length} соединений таких нет')
                            : s.live
                            ? 'Соединений пока нет. Здесь появится, какая программа или сайт куда идёт: через VPN, напрямую или блокируется'
                            : 'Список соединений не сохраняется на диск — он виден только до закрытия программы',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: C.muted),
                      ),
                    ),
                  )
                : _HoldWhileReading<ConnEntry>(
                    // Другая вкладка или другой фильтр — выделение и место чтения сбрасываются.
                    key: ValueKey('${s.id}-connections-${route?.name}-$recentOnly'),
                    items: conns,
                    newLabel: 'Новые соединения',
                    // Одинаковые соединения склеены в одну строку со счётчиком; клик разворачивает их.
                    builder: (context, shown) {
                      final groups = groupConnections(shown);
                      final index = {for (var i = 0; i < groups.length; i++) groups[i].key: groups.length - 1 - i};
                      return SelectionArea(
                        child: ListView.builder(
                          primary: true,
                          reverse: true,
                          padding: const EdgeInsets.all(14),
                          itemCount: groups.length,
                          itemBuilder: (_, i) {
                            final g = groups[groups.length - 1 - i];
                            return _ConnGroupText(g,
                                key: ValueKey(g.key), open: open.contains(g.key), onToggle: () => onToggle(g.key));
                          },
                          findChildIndexCallback: (key) => index[(key as ValueKey<String>).value],
                        ),
                      );
                    },
                  ))
            : all == null
            ? const Center(
                child: Spinner(size: 24))
            : lines.isEmpty
                ? Center(child: Text('В этом журнале таких записей нет', style: TextStyle(color: C.muted)))
                : _HoldWhileReading<LogLine>(
                    key: ValueKey('${s.id}-${tab.name}-$level'),
                    items: lines,
                    newLabel: 'Новые строки',
                    // Свежие строки внизу, список «прилипает» к низу — как в консоли.
                    // У каждой строки свой ключ: с приходом новых строк выделение остаётся на том же
                    // тексте, а не на том же месте списка.
                    builder: (context, shown) => SelectionArea(
                      child: ListView.builder(
                        primary: true,
                        reverse: true,
                        padding: const EdgeInsets.all(14),
                        itemCount: shown.length,
                        itemBuilder: (_, i) {
                          final l = shown[shown.length - 1 - i];
                          return _LineText(l, key: ValueKey(l));
                        },
                        findChildIndexCallback: (key) => _indexFromEnd(shown, (key as ValueKey<LogLine>).value),
                      ),
                    ),
                  ),
      ),
    ]);
  }
}

/// Список журнала, который не двигается, пока его читают. Внизу списка он следует за новыми записями;
/// стоит прокрутить вверх — показывается снимок на этот момент, а новые записи копятся и ждут кнопки
/// внизу (или возврата к низу списка). Иначе текст уезжал бы из-под глаз с каждой новой строкой.
class _HoldWhileReading<T extends Object> extends StatefulWidget {
  const _HoldWhileReading({super.key, required this.items, required this.builder, required this.newLabel});

  /// Записи от старых к новым.
  final List<T> items;
  final Widget Function(BuildContext context, List<T> shown) builder;

  /// Подпись кнопки возврата: «Новые строки», «Новые соединения».
  final String newLabel;

  @override
  State<_HoldWhileReading<T>> createState() => _HoldWhileReadingState<T>();
}

class _HoldWhileReadingState<T extends Object> extends State<_HoldWhileReading<T>> {
  /// Снимок списка на момент, когда начали читать; null — список следует за новыми записями.
  List<T>? _held;
  ScrollController? _scroll;

  /// Дальше этого от низа — считаем, что читают, а не просто чуть сдвинули список.
  static const _away = 40.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scroll = PrimaryScrollController.maybeOf(context);
    if (identical(scroll, _scroll)) return;
    _scroll?.removeListener(_onScroll);
    _scroll = scroll?..addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll?.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final scroll = _scroll;
    if (scroll == null || !scroll.hasClients) return;
    final reading = scroll.positions.last.pixels > _away;
    if (reading == (_held != null)) return;
    setState(() => _held = reading ? List.of(widget.items) : null);
  }

  /// Сколько записей пришло после снимка.
  int get _pending {
    final held = _held;
    if (held == null || held.isEmpty) return 0;
    final at = widget.items.lastIndexOf(held.last);
    return at < 0 ? widget.items.length : widget.items.length - 1 - at;
  }

  void _toBottom() {
    final scroll = _scroll;
    if (scroll == null || !scroll.hasClients) return;
    scroll.animateTo(0, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pending;
    return Stack(children: [
      Positioned.fill(child: widget.builder(context, _held ?? widget.items)),
      if (_held != null)
        Positioned(
          left: 0,
          right: 0,
          bottom: 10,
          child: Center(
            child: Hover(
              builder: (context, hovered) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toBottom,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 6, 10, 6),
                    decoration: BoxDecoration(
                      color: C.surface2,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: hovered ? C.orange : C.border),
                      boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 10, offset: Offset(0, 3))],
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(pending > 0 ? '${widget.newLabel}: $pending' : 'К последним записям',
                          style: TextStyle(color: C.text, fontSize: 12, fontWeight: FontWeight.w600)),
                      const SizedBox(width: 4),
                      Icon(Icons.arrow_downward_rounded, size: 14, color: hovered ? C.orange : C.muted),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
    ]);
  }
}

/// Место записи в списке, который показан с конца (свежее — внизу); null — записи уже нет.
int? _indexFromEnd<T>(List<T> items, T item) {
  final i = items.lastIndexOf(item);
  return i < 0 ? null : items.length - 1 - i;
}

/// Строка журнала. Если ядро повторило её несколько раз, в конце стоит счётчик «×N» — клик по нему
/// раскрывает время каждого повтора.
class _LineText extends StatefulWidget {
  const _LineText(this.line, {super.key});
  final LogLine line;

  @override
  State<_LineText> createState() => _LineTextState();
}

class _LineTextState extends State<_LineText> {
  bool _open = false;

  static const _style = TextStyle(fontFamily: 'Consolas', fontSize: 12, height: 1.5);

  static String _clock(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

  /// Уровень, которым ядро начинает строку (`[Info]` у Xray, `INFO` у sing-box), и номер соединения за ним.
  static final _levelTag =
      RegExp(r'^(\[(?:Debug|Info|Warning|Error)\]|(?:TRACE|DEBUG|INFO|WARN|ERROR|FATAL|PANIC)\b) ?(\[\d+\] )?');

  static Color _levelColor(String tag) {
    final t = tag.toLowerCase();
    if (t.contains('err') || t.contains('fatal') || t.contains('panic')) return C.red;
    if (t.contains('warn')) return C.isDark ? C.orangeLight : C.orange;
    if (t.contains('info')) return C.green;
    return C.muted;
  }

  @override
  Widget build(BuildContext context) {
    final line = widget.line;
    final orange = C.isDark ? C.orangeLight : C.orange;
    final t = line.time;
    final hint = LogExplain.of(line.source, line.text);
    final color = switch (line.level) {
      2 => C.red,
      1 => C.isDark ? C.orangeLight : C.orange,
      _ => C.text,
    };
    // Пометка уровня в начале строки ядра — своим цветом и жирным, номер соединения за ней — серым:
    // так глаз сразу находит, где кончается служебное начало и начинается само сообщение.
    final tag = _levelTag.firstMatch(line.text);
    final level = tag?.group(1), conn = tag?.group(2);
    final text = Text.rich(
      TextSpan(children: [
        TextSpan(text: '${_clock(t)} ', style: TextStyle(color: C.muted)),
        TextSpan(text: '[${line.source}] ', style: TextStyle(color: C.cyan)),
        if (level != null)
          TextSpan(text: '$level ', style: TextStyle(color: _levelColor(level), fontWeight: FontWeight.w700)),
        if (conn != null) TextSpan(text: conn, style: TextStyle(color: C.muted)),
        TextSpan(text: tag == null ? line.text : line.text.substring(tag.end), style: TextStyle(color: color)),
        // Одинаковые строки ядра не повторяются в журнале — у первой растёт счётчик.
        if (line.repeats > 1) ...[
          const TextSpan(text: '  '),
          WidgetSpan(alignment: PlaceholderAlignment.middle, child: _repeatsButton(line, orange)),
        ],
        if (hint != null)
          TextSpan(
            text: '\n         ↳ $hint',
            style: TextStyle(color: C.muted, fontFamily: 'Segoe UI', fontSize: 12),
          ),
      ]),
      style: _style,
    );
    if (!_open || line.repeats < 2) return text;

    // Раскрыто: время каждого повтора. Самые ранние могли не сохраниться — строка повторялась слишком долго.
    final missing = line.repeats - 1 - line.repeatTimes.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      text,
      Padding(
        padding: const EdgeInsets.only(left: 30, top: 2, bottom: 4),
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: 'Повторилась: ', style: TextStyle(color: C.muted, fontFamily: 'Segoe UI')),
            if (missing > 0) TextSpan(text: '… ещё $missing раньше, ', style: TextStyle(color: C.muted)),
            TextSpan(text: line.repeatTimes.map(_clock).join('  '), style: TextStyle(color: C.text)),
          ]),
          style: _style,
        ),
      ),
    ]);
  }

  /// Счётчик повторов — кнопка: стрелка и курсор-«рука» показывают, что её можно нажать.
  Widget _repeatsButton(LogLine line, Color orange) => Tooltip(
        message: _open ? 'Свернуть' : 'Показать время каждого повтора',
        waitDuration: const Duration(milliseconds: 600),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Hover(
            builder: (context, hovered) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _open = !_open),
              child: Container(
                padding: const EdgeInsets.fromLTRB(6, 0, 2, 0),
                decoration: BoxDecoration(
                  color: hovered || _open ? orange.withValues(alpha: 0.16) : C.surface2,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: hovered || _open ? orange.withValues(alpha: 0.6) : C.border),
                ),
                child: DefaultSelectionStyle.merge(
                  mouseCursor: SystemMouseCursors.click,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('×${line.repeats}',
                        style: TextStyle(color: orange, fontSize: 11, fontWeight: FontWeight.w700, height: 1.4)),
                    Icon(_open ? Icons.expand_more_rounded : Icons.chevron_right_rounded, size: 14, color: orange),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
}

String _routeLabel(ConnRoute r) => switch (r) {
      ConnRoute.proxy => 'через VPN',
      ConnRoute.direct => 'напрямую',
      ConnRoute.block => 'заблокировано',
      ConnRoute.dns => 'DNS',
    };

/// Название пути для фильтра.
String _routeTitle(ConnRoute r) => switch (r) {
      ConnRoute.proxy => 'VPN',
      ConnRoute.direct => 'Напрямую',
      ConnRoute.block => 'Заблокировано',
      ConnRoute.dns => 'DNS',
    };

Color _routeColor(ConnRoute r) => switch (r) {
      ConnRoute.proxy => C.isDark ? C.orangeLight : C.orange,
      ConnRoute.direct => C.green,
      ConnRoute.block => C.red,
      ConnRoute.dns => C.muted,
    };

/// Кнопка фильтра под вкладками: название и сколько таких записей (null — без числа).
class _Chip extends StatelessWidget {
  const _Chip(this.label, this.count, this.color, this.selected, this.onTap);
  final String label;
  final int? count;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Hover(
          builder: (context, hovered) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: selected ? color.withValues(alpha: 0.14) : (hovered ? C.hover : Colors.transparent),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: selected ? color.withValues(alpha: 0.5) : C.border),
              ),
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: label, style: TextStyle(color: selected ? C.text : C.muted)),
                  if (count != null)
                    TextSpan(text: '  $count', style: TextStyle(color: color, fontWeight: FontWeight.w700)),
                ]),
                maxLines: 1,
                style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ),
          ),
      );
}

/// Откуда соединение попало в ядро — по тегу входа.
String _inboundLabel(String tag) => switch (tag) {
      'socks' => 'SOCKS-порт',
      'http' => 'HTTP-прокси',
      'skipit-tun' => 'TUN',
      _ => tag,
    };

/// Куда шло соединение: сайт и порт (порт не показывается, если ядро его не сообщило).
String _target(ConnEntry c) => c.port > 0 ? '${c.host}:${c.port}' : c.host;

/// Соединение одной строкой — для копирования.
String _connLine(ConnEntry c) => '${c.time.toIso8601String()} ${c.network} ${_target(c)} → ${_routeLabel(c.route)}'
    '${c.outbound.isEmpty ? '' : ' (${c.outbound})'} · вход: ${_inboundLabel(c.inbound)}'
    '${c.unknownProcess ? ' · программа не определена' : ''}';

/// Строка списка соединений: куда шли → каким путём отправлено. Несколько одинаковых соединений —
/// одна строка со счётчиком и временем последнего; клик по счётчику разворачивает их все.
class _ConnGroupText extends StatelessWidget {
  const _ConnGroupText(this.group, {super.key, required this.open, required this.onToggle});
  final ConnGroup group;
  final bool open;
  final VoidCallback onToggle;

  static const _style = TextStyle(fontFamily: 'Consolas', fontSize: 12, height: 1.5);

  static String _time(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)} ';

  /// Через какой выход и с какого входа пришло соединение.
  static String _via(ConnEntry c) =>
      '${c.outbound.isEmpty ? '' : ' (${c.outbound})'} · вход: ${_inboundLabel(c.inbound)}';

  @override
  Widget build(BuildContext context) {
    final c = group.last;
    final many = group.items.length > 1;
    final color = _routeColor(c.route);
    final head = Text.rich(
      TextSpan(children: [
        TextSpan(text: _time(c.time), style: TextStyle(color: C.muted)),
        TextSpan(text: _target(c), style: TextStyle(color: C.text)),
        if (c.network == 'udp') TextSpan(text: ' udp', style: TextStyle(color: C.muted)),
        TextSpan(text: ' → ${_routeLabel(c.route)}', style: TextStyle(color: color, fontWeight: FontWeight.w700)),
        if (!many) TextSpan(text: _via(c), style: TextStyle(color: C.muted)),
        // Правило по приложениям к соединению не применилось: ядро не узнало программу.
        if (group.items.any((e) => e.unknownProcess))
          TextSpan(text: ' · программа не определена', style: TextStyle(color: C.isDark ? C.orangeLight : C.orange)),
      ]),
      style: _style,
    );
    if (!many) return head;

    final count = group.items.length;
    final orange = C.isDark ? C.orangeLight : C.orange;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Flexible(child: head),
        // Раскрывается только кнопкой-счётчиком, как повторы в журнале: по самой строке можно
        // спокойно кликать и выделять текст.
        Tooltip(
          message: open ? 'Свернуть' : 'Показать все соединения: $count',
          waitDuration: const Duration(milliseconds: 600),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Hover(
              builder: (context, hovered) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onToggle,
                child: Container(
                  margin: const EdgeInsets.only(left: 8, right: 4),
                  padding: const EdgeInsets.fromLTRB(6, 0, 2, 0),
                  decoration: BoxDecoration(
                    color: hovered || open ? orange.withValues(alpha: 0.16) : C.surface2,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: hovered || open ? orange.withValues(alpha: 0.6) : C.border),
                  ),
                  child: DefaultSelectionStyle.merge(
                    mouseCursor: SystemMouseCursors.click,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('×$count',
                          style: TextStyle(color: orange, fontSize: 11, fontWeight: FontWeight.w700, height: 1.4)),
                      Icon(open ? Icons.expand_more_rounded : Icons.chevron_right_rounded, size: 14, color: orange),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
      if (open)
        for (final e in group.items)
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: _time(e.time), style: TextStyle(color: C.muted)),
                TextSpan(text: _via(e).trimLeft(), style: TextStyle(color: C.muted)),
              ]),
              style: _style,
            ),
          ),
    ]);
  }
}