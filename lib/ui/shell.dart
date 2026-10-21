import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/link_parser.dart';
import '../core/paths.dart';
import '../core/tray.dart';
import '../core/windows.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../version.dart';
import 'check_page.dart';
import 'home_page.dart';
import 'logs_page.dart';
import 'routing_hub_page.dart';
import 'servers_panel.dart';
import 'settings_page.dart';
import 'smooth_scroll.dart';
import 'flag_text.dart';
import 'theme.dart';
import 'widgets.dart';

/// Что делать с другим VPN, найденным перед подключением.
enum _ConflictChoice { cancel, close, proceed }

/// Окно-предупреждение: какие VPN сейчас мешают и что с ними сделать.
Future<_ConflictChoice> _askAboutConflicts(BuildContext context, List<VpnConflict> conflicts) async {
  final canClose = conflicts.every((c) => c.canClose);
  final choice = await showDialog<_ConflictChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(children: [
        Icon(Icons.warning_amber_rounded, color: C.isDark ? C.orangeLight : C.orange),
        const SizedBox(width: 10),
        const Expanded(child: Text('Сейчас работает другой VPN')),
      ]),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final c in conflicts)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: C.surface2,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: C.border),
              ),
              child: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          const SizedBox(height: 8),
          Text(
            canClose
                ? 'Два VPN одновременно мешают друг другу: закрывается ядро SkipIt или пропадает интернет. '
                    'SkipIt может сам закрыть другой VPN и подключиться.'
                : 'Два VPN одновременно мешают друг другу: закрывается ядро SkipIt или пропадает интернет. '
                    'Этот VPN SkipIt закрыть сам не может — отключите его вручную и подключитесь снова.',
            style: TextStyle(color: C.muted, height: 1.4),
          ),
          // Второй путь — не закрывать другой VPN — отдельной плашкой со своей кнопкой: внизу окна
          // остаются только «Отмена» и главное действие, а не три кнопки в ряд.
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: C.border),
            ),
            child: Row(children: [
              Expanded(
                child: Text(
                  'Другой VPN только для рабочей сети или удалённого рабочего стола? Тогда его можно оставить.',
                  style: TextStyle(color: C.muted, fontSize: 13, height: 1.35),
                ),
              ),
              const SizedBox(width: 6),
              // Значок и лёгкая подложка: видно, что это кнопка, а не подсвеченный текст.
              TextButton.icon(
                onPressed: () => Navigator.pop(ctx, _ConflictChoice.proceed),
                style: TextButton.styleFrom(backgroundColor: C.orange.withValues(alpha: 0.12)),
                icon: const Icon(Icons.call_split_rounded, size: 18),
                label: const Text('Подключиться рядом'),
              ),
            ]),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, _ConflictChoice.cancel), child: const Text('Отмена')),
        if (canClose)
          GradientButton(
            label: 'Закрыть и подключиться',
            icon: Icons.power_settings_new_rounded,
            onPressed: () => Navigator.pop(ctx, _ConflictChoice.close),
          ),
      ],
    ),
  );
  return choice ?? _ConflictChoice.cancel;
}

/// Окно-предупреждение о запущенном zapret: подключаться ли всё равно. Галочка «Больше не спрашивать»
/// выключает окно насовсем (вернуть — «Сбросить настройки»).
Future<bool> _askAboutZapret(BuildContext context, AppState state, String zapret) async {
  var dontAsk = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Row(children: [
          Icon(Icons.warning_amber_rounded, color: C.isDark ? C.orangeLight : C.orange),
          const SizedBox(width: 10),
          Expanded(child: Text('Запущен $zapret')),
        ]),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              '$zapret меняет соединения компьютера, и с VPN это может мешать: соединение с VPN-сервером '
              'не установится, или часть сайтов перестанет открываться. Если так случится — добавьте адрес '
              'VPN-сервера в исключения $zapret или закройте его.',
              style: TextStyle(color: C.muted, height: 1.4),
            ),
            const SizedBox(height: 10),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              mouseCursor: SystemMouseCursors.click,
              onTap: () => setLocal(() => dontAsk = !dontAsk),
              child: Row(children: [
                Checkbox(
                  value: dontAsk,
                  activeColor: C.orange,
                  onChanged: (v) => setLocal(() => dontAsk = v ?? false),
                ),
                const Text('Больше не спрашивать'),
              ]),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          GradientButton(
            label: 'Подключиться всё равно',
            icon: Icons.power_settings_new_rounded,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    ),
  );
  if (ok == true && dontAsk) {
    state.settings.zapretWarn = false;
    state.changed();
  }
  return ok == true;
}

/// Подключение: сначала проверка на zapret и другие VPN (с вопросом пользователю), затем запрос прав
/// администратора для TUN, если их нет.
Future<void> connectOrToggle(BuildContext context) async {
  final state = AppScope.read(context);
  // Другой VPN ещё закрывается — подключение начнётся само, второе нажатие ничего не меняет.
  if (state.closingOtherVpn) return;
  var ignoreOtherVpn = false;
  if (!state.isConnected && !state.isBusy) {
    final zapret = state.settings.zapretWarn ? WinSys.zapretRunning() : null;
    if (zapret != null) {
      if (!await _askAboutZapret(context, state, zapret)) return;
      if (!context.mounted) return;
    }
    final conflicts = state.findVpnConflicts();
    if (conflicts.isNotEmpty) {
      switch (await _askAboutConflicts(context, conflicts)) {
        case _ConflictChoice.cancel:
          return;
        case _ConflictChoice.close:
          await state.closeVpnConflicts(conflicts);
        case _ConflictChoice.proceed:
          ignoreOtherVpn = true;
      }
      if (!context.mounted) return;
    }
  }
  try {
    await state.toggle(ignoreOtherVpn: ignoreOtherVpn);
  } on NeedAdminException {
    if (!context.mounted) return;
    final ok = await confirm(
      context,
      'Нужны права администратора',
      'Режим TUN создаёт виртуальный сетевой адаптер — для этого Windows требует права администратора.\n\n'
          'Перезапустить приложение от имени администратора? Либо переключитесь на режим «Прокси».',
      ok: 'Перезапустить',
    );
    if (!ok) return;
    if (await WinSys.relaunchAsAdmin(['--connect'])) {
      await state.shutdown();
      await Tray.quit();
      exit(0);
    }
  }
}

Future<void> importFromClipboard(BuildContext context) async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final text = data?.text?.trim() ?? '';
  if (!context.mounted) return;
  if (text.isEmpty) {
    AppScope.read(context).toast('Буфер обмена пуст');
    return;
  }
  await AppScope.read(context).importText(text);
}

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  StreamSubscription<ToastMessage>? _sub;

  static const _items = [
    (Icons.bolt_rounded, 'Главная'),
    (Icons.storage_rounded, 'Серверы'),
    (Icons.alt_route_rounded, 'Маршрутизация'),
    (Icons.troubleshoot_rounded, 'Проверка'),
    (Icons.receipt_long_rounded, 'Логи'),
    (Icons.tune_rounded, 'Настройки'),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sub ??= AppScope.read(context).messages.listen((msg) {
      if (!mounted) return;
      // Новое уведомление вытесняет прежнее: то плавно уходит, это всплывает на его место.
      // Если прежнее ещё не успело появиться (два сообщения подряд), оно убирается сразу —
      // иначе оба остались бы на экране одно поверх другого.
      final previous = _toast?.currentState;
      if (previous != null) {
        previous.dismiss();
      } else {
        _toastEntry?.remove();
      }
      final key = _toast = GlobalKey<_ToastState>();
      late final OverlayEntry entry;
      entry = OverlayEntry(
          builder: (_) => _Toast(
              key: key,
              text: msg.text,
              detail: msg.detail,
              kind: msg.kind,
              onGone: () {
                if (identical(_toastEntry, entry)) _toastEntry = null;
                entry.remove();
              }));
      _toastEntry = entry;
      Overlay.of(context, rootOverlay: true).insert(entry);
    });
  }

  GlobalKey<_ToastState>? _toast;
  OverlayEntry? _toastEntry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _state = AppScope.read(context)
        ..addListener(_askPendingLinks)
        ..addListener(_connectIfRequested);
      _askPendingLinks();
    });
  }

  AppState? _state;
  bool _asking = false;

  /// Ссылка пришла извне (skipit:// с сайта, второй запуск) — спрашиваем, прежде чем что-то добавлять.
  Future<void> _askPendingLinks() async {
    final state = _state;
    if (state == null || _asking || state.pendingLinks.isEmpty || !mounted) return;
    _asking = true;
    final link = state.pendingLinks.first;
    final parsed = LinkParser.parseText(link);
    final what = [
      for (final u in parsed.subscriptionUrls) 'подписка: ${Uri.tryParse(u)?.host ?? u}',
      if (parsed.servers.isNotEmpty) 'серверов: ${parsed.servers.length}',
      for (final r in parsed.routing) r.off ? 'отключение маршрутизации' : 'профиль маршрутизации «${r.profile?.name}»',
    ];
    await Tray.show();
    if (!mounted) return;
    final ok = await confirm(
      context,
      'Добавить из ссылки?',
      '${what.isEmpty ? 'Ссылка не распознана.' : what.join('\n')}\n\n'
          'Добавляйте только то, что вы открыли сами — например, ссылку от своего VPN-провайдера.',
      ok: 'Добавить',
    );
    await state.resolvePendingLink(link, accept: ok);
    _asking = false;
    _askPendingLinks();
  }

  /// Подключение попросили из трея, и для него нужен вопрос пользователю (найден другой VPN).
  void _connectIfRequested() {
    final state = _state;
    if (state == null || !state.connectRequested || !mounted) return;
    state.connectRequested = false;
    connectOrToggle(context);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _state?.removeListener(_askPendingLinks);
    _state?.removeListener(_connectIfRequested);
    super.dispose();
  }

  // Через of: раздел может открыть и другая часть окна (например, плитка маршрутизации на главной).
  int get _index => AppScope.of(context).pageIndex.clamp(0, _items.length - 1);

  void go(int i) => AppScope.read(context).selectPage(i);

  /// Источник обновлений спрятанных разделов: никогда не срабатывает.
  static final _asleep = ChangeNotifier();

  @override
  Widget build(BuildContext context) {
    final pages = [
      const HomePage(),
      // Раздел «Серверы»: все подписки и серверы, включая скрытые с главной, на всю ширину окна.
      const Padding(padding: EdgeInsets.fromLTRB(24, 24, 24 - scrollGutter, 0), child: ServersPanel(manage: true)),
      const RoutingHubPage(),
      const CheckPage(),
      const LogsPage(),
      const SettingsPage(),
    ];
    return Scaffold(
      backgroundColor: C.bg,
      // Ctrl+V (и Ctrl+Shift+V) на главной и в «Серверах» — импорт ссылки или конфига из буфера. В других
      // разделах сочетание ничего не добавляет: подписка, появившаяся из журнала или настроек, была бы
      // неожиданной.
      body: Shortcuts(
        shortcuts: _index > 1
            ? const {}
            : const {
                SingleActivator(LogicalKeyboardKey.keyV, control: true): _PasteIntent(),
                SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true): _PasteIntent(),
              },
        child: Actions(
          actions: {_PasteIntent: _PasteAction(() => importFromClipboard(context))},
          child: Focus(
            autofocus: true,
            // Оба меню всегда на своих местах: при смене «слева / сверху» одно плавно сворачивается,
            // другое разворачивается, а разделы между ними не строятся заново. Боковое — на всю высоту
            // окна, верхнее — только над разделами: пока оба видны, верхнее не отнимает высоту у бокового.
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _MenuSlot(
                shown: !AppScope.of(context).settings.navTop,
                axis: Axis.horizontal,
                child: _Sidebar(index: _index, items: _items, onSelect: go),
              ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _MenuSlot(
            shown: AppScope.of(context).settings.navTop,
            axis: Axis.vertical,
            child: _TopBar(index: _index, items: _items, onSelect: go),
          ),
          // Спрятанные разделы слушают «спящий» источник и не перестраиваются от каждого изменения состояния
          // (раньше любое изменение перестраивало все шесть, вместе с полной копией списка серверов
          // в «Серверах»). Открытый раздел перестраивается сразу при переходе: у него меняется источник.
          Expanded(
            child: IndexedStack(index: _index, children: [
              for (var i = 0; i < pages.length; i++)
                AppScope(
                  state: AppScope.read(context),
                  notifier: i == _index ? null : _asleep,
                  child: _SmoothPage(child: pages[i]),
                ),
            ]),
          ),
        ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Всплывающее уведомление внизу окна: плавно поднимается и проявляется, через 4 секунды так же
/// плавно уходит вниз. Закрывается кликом по нему или по крестику; пока на нём курсор — не исчезает.
class _Toast extends StatefulWidget {
  const _Toast({super.key, required this.text, this.detail, required this.kind, required this.onGone});
  final String text;

  /// Вторая строка мельче; с ней первая становится заголовком.
  final String? detail;

  /// Успех, ошибка или просто сведение: значок слева и время показа.
  final ToastKind kind;

  /// Уведомление полностью ушло с экрана — его можно убирать.
  final VoidCallback onGone;

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    reverseDuration: const Duration(milliseconds: 220),
  );
  late final _move = CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
  Timer? _timer;
  bool _leaving = false;

  void _arm() {
    _timer?.cancel();
    // Ошибку и новость о новой версии нужно успеть прочитать — они держатся вдвое дольше.
    final long = widget.kind == ToastKind.error || widget.kind == ToastKind.update;
    _timer = Timer(Duration(seconds: long ? 8 : 4), dismiss);
  }

  /// Значок и цвет вида уведомления; у простого сведения — «i».
  (IconData, Color)? get _badge => switch (widget.kind) {
        ToastKind.success => (Icons.check_rounded, C.green),
        ToastKind.error => (Icons.priority_high_rounded, C.red),
        ToastKind.update => (Icons.arrow_downward_rounded, C.isDark ? C.orangeLight : C.orange),
        ToastKind.info => (Icons.info_rounded, C.orange),
      };

  void dismiss() {
    if (_leaving || !mounted) return;
    _leaving = true;
    _timer?.cancel();
    _anim.reverse().whenComplete(widget.onGone);
  }

  @override
  void initState() {
    super.initState();
    _anim.forward();
    _arm();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _move.dispose();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Positioned(
        left: 16,
        right: 16,
        bottom: 14,
        child: Center(
          child: AnimatedBuilder(
            animation: _move,
            builder: (context, child) => Opacity(
              opacity: _move.value,
              child: Transform.translate(
                offset: Offset(0, 18 * (1 - _move.value)),
                child: Transform.scale(scale: 0.96 + 0.04 * _move.value, child: child),
              ),
            ),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => _timer?.cancel(),
              onExit: (_) {
                if (!_leaving) _arm();
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: dismiss,
                child: Material(
                  type: MaterialType.transparency,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 520),
                    padding: EdgeInsets.fromLTRB(_badge == null ? 16 : 10, 10, 10, 10),
                    decoration: BoxDecoration(
                      color: C.surface2,
                      borderRadius: BorderRadius.circular(14),
                      // Рамка ошибки и новой версии — цветом их значка, у остальных обычная.
                      border: Border.all(
                          color: widget.kind == ToastKind.error || widget.kind == ToastKind.update
                              ? _badge!.$2.withValues(alpha: 0.55)
                              : C.border),
                      boxShadow: [BoxShadow(color: C.palette.shadow, blurRadius: 24, offset: const Offset(0, 8))],
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      // Значок на подложке своего цвета — как метки в остальном окне.
                      if (_badge case (final icon, final color)) ...[
                        Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Icon(icon, size: 18, color: color),
                        ),
                        const SizedBox(width: 11),
                      ],
                      Flexible(
                        child: widget.detail == null
                            ? Text(widget.text, style: TextStyle(color: C.text, fontSize: 14))
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(widget.text,
                                      style: TextStyle(color: C.text, fontSize: 14, fontWeight: FontWeight.w600)),
                                  Text(widget.detail!, style: TextStyle(color: C.muted, fontSize: 12.5)),
                                ],
                              ),
                      ),
                      const SizedBox(width: 12),
                      Hover(
                        builder: (context, hovered) =>
                            Icon(Icons.close_rounded, size: 18, color: hovered ? C.text : C.muted),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

/// Меню разделов вдоль верхнего края окна (Настройки → Внешний вид → «Расположение меню»). Узкое окно —
/// подписи остаются только у выбранного раздела, у остальных значок с подсказкой.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.index, required this.items, required this.onSelect});
  final int index;
  final List<(IconData, String)> items;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final (dotColor, statusText) = _statusOf(state);
    return Container(
      height: 64,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: C.border),
      ),
      child: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 1180;
        return Row(children: [
          const AppBadge(size: 34),
          const SizedBox(width: 10),
          Text(AppPaths.appName, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900, letterSpacing: -0.3)),
          const SizedBox(width: 18),
          Expanded(child: _TopNav(index: index, items: items, wide: wide, onSelect: onSelect)),
          Tooltip(
            richMessage: TextSpan(children: [
              TextSpan(text: '$statusText\n'),
              Flags.span(state.selectedServer?.name ?? 'Сервер не выбран', size: 12),
            ]),
            child: Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: C.surface2,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: state.isConnected ? C.green.withValues(alpha: 0.45) : C.border),
              ),
              child: Row(children: [
                _StatusDot(dotColor),
                const SizedBox(width: 9),
                Text(statusText, maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              ]),
            ),
          ),
          const SizedBox(width: 6),
          const SizedBox(width: 46, child: _VersionRow(collapsed: true)),
        ]);
      }),
    );
  }
}

/// Пункт верхнего меню: значок и, если хватает места, название.
/// Пункты верхнего меню и одна общая подсветка выбранного, которая «едет» к новому пункту — как
/// в боковом меню. Пункты бывают разной ширины (а в узком окне подпись у выбранного выезжает),
/// поэтому место подсветки берётся из раскладки и обновляется каждый кадр, пока она едет.
class _TopNav extends StatefulWidget {
  const _TopNav({required this.index, required this.items, required this.wide, required this.onSelect});
  final int index;
  final List<(IconData, String)> items;
  final bool wide;
  final ValueChanged<int> onSelect;

  @override
  State<_TopNav> createState() => _TopNavState();
}

class _TopNavState extends State<_TopNav> with SingleTickerProviderStateMixin {
  final _stack = GlobalKey();
  late final _keys = [for (final _ in widget.items) GlobalKey()];
  late final _move = AnimationController(vsync: this, duration: const Duration(milliseconds: 260), value: 1);

  /// Откуда едет подсветка и где она нарисована сейчас.
  Rect? _from;
  Rect? _drawn;

  Rect? _target() {
    final stack = _stack.currentContext?.findRenderObject() as RenderBox?;
    final item = _keys[widget.index].currentContext?.findRenderObject() as RenderBox?;
    if (stack == null || item == null || !stack.hasSize || !item.hasSize) return null;
    return item.localToGlobal(Offset.zero, ancestor: stack) & item.size;
  }

  @override
  void didUpdateWidget(_TopNav old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      _from = _drawn;
      _move.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _move.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // После раскладки (первый кадр, смена ширины окна) подсветка встаёт на место пункта.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_move.isAnimating && _target() != _drawn) setState(() {});
    });
    return Stack(key: _stack, alignment: Alignment.centerLeft, children: [
      AnimatedBuilder(
        animation: _move,
        builder: (context, _) {
          final to = _target();
          if (to == null) return const SizedBox.shrink();
          final rect = _from == null ? to : Rect.lerp(_from, to, Curves.easeOutCubic.transform(_move.value))!;
          _drawn = rect;
          return Positioned.fromRect(
            rect: rect,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: C.orange.withValues(alpha: 0.14),
                ),
              ),
            ),
          );
        },
      ),
      Row(children: [
        for (var i = 0; i < widget.items.length; i++)
          _TopItem(
            boxKey: _keys[i],
            icon: widget.items[i].$1,
            label: widget.items[i].$2,
            selected: i == widget.index,
            showLabel: widget.wide || i == widget.index,
            onTap: () => widget.onSelect(i),
          ),
      ]),
    ]);
  }
}

class _TopItem extends StatelessWidget {
  const _TopItem({
    required this.boxKey,
    required this.icon,
    required this.label,
    required this.selected,
    required this.showLabel,
    required this.onTap,
  });
  final GlobalKey boxKey;
  final IconData icon;
  final String label;
  final bool selected;
  final bool showLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Tooltip(
          message: showLabel ? '' : label,
          waitDuration: const Duration(milliseconds: 300),
          child: Hover(
            builder: (context, hovered) => GestureDetector(
              onTap: onTap,
              child: AnimatedContainer(
                key: boxKey,
                duration: const Duration(milliseconds: 160),
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  // Фон выбранного пункта рисует общая подсветка в [_TopNav].
                  color: !selected && hovered ? C.hover : Colors.transparent,
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 20, color: selected || hovered ? C.orange : C.muted),
                  // В узком окне подпись у выбранного пункта плавно выезжает, у прежнего — уезжает.
                  AnimatedSize(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.centerLeft,
                    child: showLabel
                        ? Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(label,
                                maxLines: 1,
                                softWrap: false,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: selected || hovered ? C.text : C.muted,
                                )),
                          )
                        : const SizedBox(height: 20),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
}

/// Место меню (слева или сверху): когда меню переезжает, оно здесь плавно сворачивается по ширине
/// или высоте и гаснет, а на новом месте так же разворачивается.
class _MenuSlot extends StatelessWidget {
  const _MenuSlot({required this.shown, required this.axis, required this.child});
  final bool shown;
  final Axis axis;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(end: shown ? 1 : 0),
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        child: child,
        builder: (context, t, child) => t == 0
            ? const SizedBox.shrink()
            : ClipRect(
                child: Align(
                  alignment: axis == Axis.horizontal ? Alignment.centerRight : Alignment.bottomCenter,
                  widthFactor: axis == Axis.horizontal ? t : null,
                  heightFactor: axis == Axis.vertical ? t : null,
                  child: Opacity(opacity: t, child: child),
                ),
              ),
      );
}

/// Цвет точки и слово статуса подключения — для бокового и верхнего меню.
(Color, String) _statusOf(AppState state) => switch (state.status) {
      ConnStatus.connected => (C.green, 'Подключено'),
      ConnStatus.connecting => (C.orangeLight, 'Подключение…'),
      ConnStatus.disconnecting => (C.orangeLight, 'Отключение…'),
      ConnStatus.disconnected => (C.muted, 'Не подключено'),
    };

/// Светящаяся точка статуса подключения.
class _StatusDot extends StatelessWidget {
  const _StatusDot(this.color);
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: 8)],
        ),
      );
}

/// Боковое меню — «плавающая» карточка; сворачивается до полоски с иконками.
class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.index, required this.items, required this.onSelect});
  final int index;
  final List<(IconData, String)> items;
  final ValueChanged<int> onSelect;

  static const _expandedWidth = 224.0;
  static const _collapsedWidth = 72.0;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final collapsed = state.settings.sidebarCollapsed;
    final (dotColor, statusText) = _statusOf(state);
    void toggle() {
      state.settings.sidebarCollapsed = !collapsed;
      state.changed();
    }

    final dot = _StatusDot(dotColor);

    // Справа от меню — отступ до разделов (прежде на этой границе висела круглая ручка сворачивания).
    const handle = 32.0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: (collapsed ? _collapsedWidth : _expandedWidth) + 12 + handle / 2,
      child: Stack(children: [
        Positioned.fill(
          left: 12,
          right: handle / 2,
          top: 12,
          bottom: 12,
          child: _panel(context, state, collapsed, dot, statusText, toggle),
        ),
      ]),
    );
  }

  Widget _panel(BuildContext context, AppState state, bool collapsed, Widget dot, String statusText, VoidCallback toggle) {
    return Container(
      padding: const EdgeInsets.fromLTRB(11, 18, 11, 14),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: C.border),
      ),
      // Подписи показываем только когда места достаточно — иначе во время анимации текст переполнится.
      child: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth > 160;
        return ClipRect(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Значок стоит на месте в обоих состояниях, надпись «выезжает» из-под него.
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Row(children: [
                // Значок SkipIt — кнопка «Свернуть / развернуть меню».
                _MenuBadge(collapsed: collapsed, onTap: toggle),
                // Свернули и анимация закончилась — надпись убираем совсем, чтобы не выглядывала.
                if (!collapsed || wide)
                Expanded(
                  child: SizedBox(
                    height: 36,
                    child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.centerLeft,
                      minWidth: 0,
                      maxWidth: double.infinity,
                      child: AnimatedSlide(
                        offset: collapsed ? const Offset(-0.6, 0) : Offset.zero,
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        child: AnimatedOpacity(
                          opacity: collapsed ? 0 : 1,
                          duration: const Duration(milliseconds: 200),
                          child: Padding(
                            padding: const EdgeInsets.only(left: 11),
                            child: Text(AppPaths.appName,
                                maxLines: 1,
                                softWrap: false,
                                style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900, letterSpacing: -0.3)),
                          ),
                        ),
                      ),
                    ),
                  ),
                  ),
                ),
              ]),
            ),
            // Одинаковый отступ в обоих состояниях — пункты меню не сдвигаются при сворачивании.
            const SizedBox(height: 26),
            // Подсветка выбранного пункта — одна на всё меню и «скользит» к новому пункту,
            // как у переключателей режимов.
            Stack(fit: StackFit.passthrough, children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                top: index * _NavItem.extent,
                left: 0,
                right: 0,
                height: _NavItem.height,
                child: IgnorePointer(
                  child: Container(
                    alignment: Alignment.centerLeft,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: C.orange.withValues(alpha: 0.14),
                    ),
                    // Оранжевая метка слева у выбранного пункта.
                    child: Container(
                      width: 3,
                      height: 18,
                      decoration: BoxDecoration(color: C.orange, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                ),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                for (var i = 0; i < items.length; i++)
                  _NavItem(
                    icon: items[i].$1,
                    label: items[i].$2,
                    selected: i == index,
                    collapsed: collapsed,
                    onTap: () => onSelect(i),
                  ),
              ]),
            ]),
            const Spacer(),
            // Статус: одна раскладка в обоих состояниях — точка на месте, текст выезжает.
            Tooltip(
              // В подсказке флаг — картинкой (в тексте Windows вместо него показала бы буквы «DE»).
              message: collapsed ? null : '',
              richMessage: collapsed
                  ? TextSpan(children: [
                      TextSpan(text: '$statusText\n'),
                      Flags.span(state.selectedServer?.name ?? 'Сервер не выбран', size: 12),
                    ])
                  : null,
              child: Container(
                height: 54,
                padding: const EdgeInsets.only(left: 19, right: 10),
                decoration: BoxDecoration(
                  color: C.surface2,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: state.isConnected ? C.green.withValues(alpha: 0.45) : C.border),
                ),
                child: Row(children: [
                  dot,
                  Expanded(
                    child: SlideLabel(
                      collapsed: collapsed,
                      height: 54,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 10),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(statusText,
                                maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                            SizedBox(
                              width: 150,
                              child: FlagText(
                                state.selectedServer?.name ?? 'Сервер не выбран',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: C.muted, fontSize: 11),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            _VersionRow(collapsed: collapsed),

          ]),
        );
      }),
    );
  }
}

/// Значок SkipIt — кнопка «Свернуть / развернуть меню». На его уголке всегда кружок со стрелками, чтобы
/// сразу было видно, что значок нажимается; при наведении весь значок становится кнопкой со стрелками.
class _MenuBadge extends StatelessWidget {
  const _MenuBadge({required this.collapsed, required this.onTap});
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final arrows = collapsed ? Icons.keyboard_double_arrow_right_rounded : Icons.keyboard_double_arrow_left_rounded;
    return Tooltip(
      message: collapsed ? 'Развернуть меню' : 'Свернуть меню',
      waitDuration: const Duration(milliseconds: 300),
      child: Hover(
        builder: (context, hovered) => GestureDetector(
          onTap: onTap,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned.fill(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  child: hovered
                      ? Container(
                          key: ValueKey(arrows),
                          decoration: BoxDecoration(
                            color: C.orange.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: C.orange.withValues(alpha: 0.5)),
                          ),
                          child: Icon(arrows, size: 20, color: C.orange),
                        )
                      : const AppBadge(key: ValueKey('badge'), size: 36),
                ),
              ),
              Positioned(
                right: -5,
                bottom: -5,
                child: AnimatedOpacity(
                  opacity: hovered ? 0 : 1,
                  duration: const Duration(milliseconds: 160),
                  child: Container(
                    width: 17,
                    height: 17,
                    decoration: BoxDecoration(
                      color: C.surface2,
                      shape: BoxShape.circle,
                      border: Border.all(color: C.border),
                    ),
                    child: Icon(arrows, size: 12, color: C.muted),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.collapsed = false,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;

  /// Высота пункта и шаг между пунктами (с отступом) — по ним движется подсветка в [_Sidebar].
  static const height = 44.0;
  static const extent = height + 4;

  @override
  Widget build(BuildContext context) {
    // Одна раскладка для обоих состояний: метка и иконка стоят на месте (иконка ровно по центру
    // свёрнутого меню), а название выезжает из-под иконки.
    final item = Hover(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            // Фон и метку выбранного пункта рисует скользящая подсветка в меню.
            color: !selected && hovered ? C.hover : Colors.transparent,
          ),
          child: Row(children: [
            const SizedBox(width: 14),
            Icon(icon, size: 20, color: selected || hovered ? C.orange : C.muted),
            Expanded(
              child: SlideLabel(
                collapsed: collapsed,
                height: 44,
                child: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(label,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: 14.5,
                        // Толщина одна для всех состояний — выбор и наведение меняют только цвет,
                        // иначе текст «прыгает» по толщине и ширине.
                        fontWeight: FontWeight.w700,
                        color: selected || hovered ? C.text : C.muted,
                      )),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: extent - height),
      child: Tooltip(
        message: collapsed ? label : '',
        waitDuration: const Duration(milliseconds: 300),
        child: item,
      ),
    );
  }
}

/// Подпись, которая «выезжает» из-под иконки при разворачивании меню и прячется обратно.
/// Место под ней обрезается, поэтому во время анимации ширины ничего не переполняется.
class SlideLabel extends StatelessWidget {
  const SlideLabel({super.key, required this.collapsed, required this.height, required this.child});
  final bool collapsed;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: 0,
            maxWidth: double.infinity,
            // Своя высота у подписи — иначе её растягивает на весь пункт и текст прилипает к верху.
            minHeight: 0,
            maxHeight: height,
            child: AnimatedSlide(
              offset: collapsed ? const Offset(-0.35, 0) : Offset.zero,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: collapsed ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                child: child,
              ),
            ),
          ),
        ),
      );
}

/// У каждой страницы свой контроллер плавной прокрутки (списки берут его через primary: true).
class _SmoothPage extends StatelessWidget {
  const _SmoothPage({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => SmoothScroll(
        builder: (context, controller) => PrimaryScrollController(controller: controller, child: child),
      );
}

/// Версия внизу меню + проверка обновлений. Одна раскладка для свёрнутого и развёрнутого меню:
/// значок стоит на месте (под значками пунктов), подпись выезжает из-под него — ничего не прыгает.
/// Если нашлось обновление — строка оранжевая, клик его ставит.
class _VersionRow extends StatelessWidget {
  const _VersionRow({required this.collapsed});
  final bool collapsed;

  static const _height = 46.0;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final hasUpdate = state.appUpdate != null;
    final title = 'Версия $appVersion${AppPaths.isDev ? ' dev' : ''}';
    final downloading = state.downloadingAppUpdate;
    final action = downloading
        ? state.updateProgressShort
        : state.checkingUpdates
        ? 'Проверяю обновления…'
        : hasUpdate
            ? 'Установить ${state.appUpdate!.version}'
            : 'Проверить обновления';

    return Tooltip(
      // В свёрнутом меню подписи не видно — она переезжает в подсказку.
      message: collapsed ? '$title\n$action' : '',
      waitDuration: const Duration(milliseconds: 300),
      child: Hover(
        builder: (context, hovered) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Есть обновление — строка сразу его ставит (с подтверждением), а не уводит в настройки.
          onTap: state.checkingUpdates || downloading
              ? null
              : hasUpdate
                  ? () => installAppUpdate(context)
                  : state.checkUpdates,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: _height,
            decoration: BoxDecoration(
              color: hasUpdate ? C.orange.withValues(alpha: 0.14) : (hovered ? C.hover : Colors.transparent),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: hasUpdate ? C.orange.withValues(alpha: 0.5) : Colors.transparent),
            ),
            child: Row(children: [
              const SizedBox(width: 13),
              SizedBox(
                width: 20,
                child: Center(
                  child: state.checkingUpdates || downloading
                      ? const Spinner(size: 18, icon: Icons.sync_rounded)
                      : Icon(hasUpdate ? Icons.download_rounded : Icons.sync_rounded,
                          size: 18, color: hasUpdate || hovered ? C.orange : C.muted),
                ),
              ),
              Expanded(
                child: SlideLabel(
                  collapsed: collapsed,
                  height: _height,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                                color: hovered || hasUpdate ? C.text : C.muted,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700)),
                        Text(action,
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(color: hasUpdate || hovered ? C.orange : C.muted, fontSize: 11)),
                      ],
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}class _PasteIntent extends Intent {
  const _PasteIntent();
}

/// Вставка из буфера. Если фокус в поле ввода — действие «выключено»,
/// и Ctrl+V уходит полю как обычная вставка текста.
class _PasteAction extends Action<_PasteIntent> {
  _PasteAction(this.onPaste);
  final VoidCallback onPaste;

  @override
  bool isEnabled(_PasteIntent intent) {
    final focused = FocusManager.instance.primaryFocus?.context;
    return focused == null || focused.findAncestorWidgetOfExactType<EditableText>() == null;
  }

  @override
  Object? invoke(_PasteIntent intent) {
    onPaste();
    return null;
  }
}