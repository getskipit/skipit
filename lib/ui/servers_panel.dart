import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/util.dart';
import '../core/windows.dart';
import '../core/xray_config.dart';
import '../models/server.dart';
import '../models/subscription.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import 'app_menu.dart';
import 'flag_text.dart';
import 'shell.dart';
import 'smooth_scroll.dart';
import 'theme.dart';
import 'widgets.dart';

/// Список серверов на главной: поиск, группы подписок с информацией, строки серверов.
class ServersPanel extends StatefulWidget {
  const ServersPanel({super.key, this.scrollable = true});

  /// false — панель встроена в общий прокручиваемый список (узкое окно).
  final bool scrollable;

  @override
  State<ServersPanel> createState() => _ServersPanelState();
}

/// Ширина дорожки полосы прокрутки справа от списка серверов.
const scrollGutter = 14.0;

class _ServersPanelState extends State<ServersPanel> {
  String _query = '';
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Карточки групп по id подписки — чтобы после перестановки плавно довезти их на новые места.
  final _slides = <String, GlobalKey<_MoveSlideState>>{};

  /// Перестановка закреплённых подписок: карточки не перескакивают, а съезжаются на новые места.
  void _move(AppState state, Subscription moved, Subscription target) {
    final before = {
      for (final e in _slides.entries)
        if (e.value.currentState != null) e.key: e.value.currentState!.top,
    };
    state.moveSubscription(moved, target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final e in _slides.entries) {
        final slide = e.value.currentState;
        final old = before[e.key];
        if (slide == null || old == null) continue;
        final delta = old - slide.top;
        if (delta.abs() > 0.5) slide.slideFrom(delta);
      }
    });
  }

  void _clearSearch() {
    _search.clear();
    setState(() => _query = '');
  }
  /// Поиск идёт по названию подписки (тогда показываются все её серверы) и по названию сервера.
  /// По протоколу и адресу не ищем: «vless» иначе находил бы всё подряд.
  List<ServerProfile> _filter(Subscription? sub, List<ServerProfile> servers) {
    if (_query.isEmpty) return servers;
    if (sub != null && Flags.toPlain(sub.displayName).toLowerCase().contains(_query)) return servers;
    return servers.where((s) => Flags.toPlain(s.name).toLowerCase().contains(_query)).toList();
  }

  Future<void> _add(BuildContext context) async {
    final text = await promptText(
      context,
      title: 'Добавить подписку',
      hint: 'Ссылка на подписку или сервера: https://…, vless://, vmess://, trojan://, ss://, hy2://, happ://…',
      maxLines: 5,
      ok: 'Добавить',
    );
    if (text != null && text.trim().isNotEmpty && context.mounted) {
      await AppScope.read(context).importText(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final hasAny = state.subscriptions.isNotEmpty || state.servers.isNotEmpty;
    final groups = <(Subscription?, List<ServerProfile>)>[
      // Закреплённые подписки — первыми; внутри каждой группы порядок остаётся прежним.
      for (final sub in [...state.subscriptions.where((s) => s.pinned), ...state.subscriptions.where((s) => !s.pinned)])
        (sub, _filter(sub, state.serversOf(sub.id))),
      if (state.serversOf(null).isNotEmpty) (null, _filter(null, state.serversOf(null))),
      // При поиске группы без совпадений не показываем.
    ].where((g) => _query.isEmpty || g.$2.isNotEmpty).toList();
    // Порядок меняется только среди закреплённых и только в полном списке (без поиска).
    final pinnedCount = state.subscriptions.where((s) => s.pinned).length;
    bool canDrag(Subscription sub) => sub.pinned && pinnedCount > 1 && _query.isEmpty;

    final header = Row(children: [
      Expanded(
        child: TextField(
          controller: _search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded),
            hintText: 'Поиск по названию сервера или подписки',
            // Крестик появляется, когда в поле что-то введено, и очищает поиск одним кликом.
            suffixIcon: _search.text.isEmpty
                ? null
                : Tooltip(
                    message: 'Очистить',
                    child: Hover(
                      builder: (context, hovered) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _clearSearch,
                        child: Icon(Icons.close_rounded, size: 18, color: hovered ? C.orange : C.muted),
                      ),
                    ),
                  ),
          ),
          onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
        ),
      ),
      const SizedBox(width: 6),
      _IconAction(
        tooltip: 'Проверить задержку (пинг) всех серверов',
        icon: Icons.speed_rounded,
        busy: state.pinging,
        onCancel: state.cancelPing,
        cancelTooltip: 'Остановить проверку задержки',
        onTap: () => state.ping(state.servers),
      ),
      _MenuAction(
        tooltip: 'Ещё',
        items: const [
          AppMenuItem('add', 'Добавить подписку', icon: Icons.add_rounded),
          AppMenuItem('paste', 'Вставить из буфера', icon: Icons.content_paste_rounded, hint: 'Ctrl+V'),
          AppMenuItem.divider(),
          AppMenuItem('update', 'Обновить все подписки', icon: Icons.sync_rounded),
        ],
        onSelected: (v) {
          switch (v) {
            case 'add':
              _add(context);
            case 'paste':
              importFromClipboard(context);
            case 'update':
              state.updateAllSubscriptions();
          }
        },
      ),
    ]);

    final children = <Widget>[
      header,
      const SizedBox(height: 14),
      if (!hasAny)
        _EmptyState(onAdd: () => _add(context))
      else if (groups.isEmpty)
        Panel(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Center(child: Text('По запросу «$_query» ничего не найдено', style: TextStyle(color: C.muted))),
        )
      else
        for (final (sub, list) in groups)
          _MoveSlide(
            key: _slides.putIfAbsent(sub?.id ?? 'manual', GlobalKey<_MoveSlideState>.new),
            child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            // Закреплённые подписки можно менять местами: заголовок одной перетаскивают на другую.
            child: DragTarget<Subscription>(
              onWillAcceptWithDetails: (d) => sub != null && canDrag(sub) && d.data != sub,
              onAcceptWithDetails: (d) => _move(state, d.data, sub!),
              builder: (context, incoming, _) {
                final moved = incoming.firstOrNull;
                // Перетаскивают снизу вверх — подписка встанет над этой, сверху вниз — под ней.
                final above = moved != null &&
                    sub != null &&
                    state.subscriptions.indexOf(moved) > state.subscriptions.indexOf(sub);
                return Stack(clipBehavior: Clip.none, children: [
                  _GroupCard(
                    key: ValueKey(sub?.id ?? 'manual'),
                    subscription: sub,
                    servers: list,
                    draggable: sub != null && canDrag(sub),
                  ),
                  // Оранжевая черта в промежутке между карточками — место, куда встанет подписка.
                  if (moved != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: above ? -9 : null,
                      bottom: above ? null : -9,
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(color: C.orange, borderRadius: BorderRadius.circular(2)),
                      ),
                    ),
                ]);
              },
            ),
            ),
          ),
    ];

    return widget.scrollable
        // Справа — своя дорожка для полосы прокрутки, чтобы она не ложилась на карточки и кнопки.
        ? ListView(primary: true, padding: const EdgeInsets.only(right: scrollGutter, bottom: 24), children: children)
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

/// Обёртка карточки в списке: после перестановки доезжает со старого места на новое.
class _MoveSlide extends StatefulWidget {
  const _MoveSlide({super.key, required this.child});
  final Widget child;

  @override
  State<_MoveSlide> createState() => _MoveSlideState();
}

class _MoveSlideState extends State<_MoveSlide> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 260), value: 1);
  double _from = 0;

  /// Верх карточки на экране.
  double get top => (context.findRenderObject() as RenderBox).localToGlobal(Offset.zero).dy;

  /// Карточка уже стоит на новом месте; показываем её сдвинутой на [delta] и возвращаем в ноль.
  void slideFrom(double delta) {
    _from = delta;
    _anim.forward(from: 0);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _anim,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, _from * (1 - Curves.easeOutCubic.transform(_anim.value))),
          child: child,
        ),
        child: widget.child,
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
        child: Column(children: [
          const AppBadge(size: 56),
          const SizedBox(height: 16),
          const Text('Пока нет серверов', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('Скопируйте ссылку на подписку и нажмите Ctrl+V',
              textAlign: TextAlign.center, style: TextStyle(color: C.muted)),
          const SizedBox(height: 18),
          GradientButton(label: 'Добавить подписку', icon: Icons.add_rounded, onPressed: onAdd),
        ]),
      );
}

/// Маленькая круглая кнопка-иконка с подсветкой при наведении.
class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.busy = false,
    this.onCancel,
    this.cancelTooltip,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;
  final bool busy;

  /// Если задано — нажатие во время работы останавливает её (подсказка тогда [cancelTooltip]).
  final VoidCallback? onCancel;
  final String? cancelTooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: busy && onCancel != null ? (cancelTooltip ?? tooltip) : tooltip,
        child: Hover(
          enabled: busy ? onCancel != null : onTap != null,
          builder: (context, hovered) => GestureDetector(
            // Занятая кнопка всё равно забирает нажатие: иначе оно проваливалось в заголовок
            // подписки и сворачивало список серверов.
            behavior: HitTestBehavior.opaque,
            onTap: busy ? (onCancel ?? () {}) : onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: hovered ? C.hover : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: busy
                    // Пока идёт работа, оживает сам значок кнопки: стрелки обновления вращаются,
                    // остальные значки (проверка задержки) мигают — так действия не путаются.
                    ? Spinner(size: 20, icon: icon, pulse: icon != Icons.sync_rounded)
                    : Icon(icon, size: 20, color: hovered ? C.orange : C.muted),
              ),
            ),
          ),
        ),
      );
}

/// Кнопка «…» с выпадающим меню.
class _MenuAction extends StatelessWidget {
  const _MenuAction({required this.tooltip, required this.items, required this.onSelected});
  final String tooltip;
  final List<AppMenuItem<String>> items;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => Builder(
        builder: (btn) => _IconAction(
          tooltip: tooltip,
          icon: Icons.more_horiz_rounded,
          onTap: () async {
            final v = await showAppMenu(btn, items: items);
            if (v != null) onSelected(v);
          },
        ),
      );
}


class _GroupCard extends StatefulWidget {
  const _GroupCard({super.key, required this.subscription, required this.servers, this.draggable = false});
  final Subscription? subscription;
  final List<ServerProfile> servers;

  /// Заголовок можно перетащить на другую закреплённую подписку, чтобы поменять их местами.
  final bool draggable;

  @override
  State<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<_GroupCard> {
  bool _manualExpanded = true;

  /// Заголовок этой подписки сейчас перетаскивают — карточка бледнеет, чтобы было видно, какую несут.
  bool _dragging = false;

  Future<void> _edit(AppState state, Subscription sub) async {
    final name = TextEditingController(text: sub.name);
    final url = TextEditingController(text: sub.url);
    final interval = TextEditingController(text: '${sub.updateIntervalHours}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Подписка'),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Название')),
            const SizedBox(height: 12),
            TextField(controller: url, decoration: const InputDecoration(labelText: 'URL')),
            const SizedBox(height: 12),
            TextField(
              controller: interval,
              decoration: const InputDecoration(labelText: 'Автообновление, часов (0 — выключено)'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          GradientButton(label: 'Сохранить', onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true) return;
    sub.name = name.text.trim();
    sub.url = url.text.trim();
    sub.updateIntervalHours = asInt(interval.text) ?? sub.updateIntervalHours;
    state.changed();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final sub = widget.subscription;
    final expanded = sub?.expanded ?? _manualExpanded;
    final updating = sub != null && state.updatingSubs.contains(sub.id);

    void toggle() {
      if (sub == null) {
        setState(() => _manualExpanded = !_manualExpanded);
      } else {
        sub.expanded = !sub.expanded;
        state.changed();
      }
    }

    final subtitle = sub == null
        ? '${widget.servers.length} серв.'
        : [
            if (sub.lastUpdated != null) formatDateTime(sub.lastUpdated!),
            sub.updateIntervalHours > 0 ? 'Автообновление — ${sub.updateIntervalHours} ч.' : 'Без автообновления',
          ].join('  |  ');

    // Перетаскивание заголовка: за указателем едет маленькая плашка с названием, а не вся карточка —
    // развёрнутая подписка бывает выше окна. Обычный клик по заголовку работает как раньше.
    Widget dragHandle(Widget header) => sub == null || !widget.draggable
        ? header
        : Draggable<Subscription>(
            data: sub,
            axis: Axis.vertical,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            onDragStarted: () => setState(() => _dragging = true),
            onDragEnd: (_) => setState(() => _dragging = false),
            feedback: Material(
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 280),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: C.surface2,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: C.orange),
                ),
                child: FlagText(sub.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
              ),
            ),
            child: header,
          );

    return AnimatedOpacity(
      opacity: _dragging ? 0.45 : 1,
      duration: const Duration(milliseconds: 140),
      child: Container(
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: C.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Заголовок группы.
        dragHandle(Hover(
          builder: (context, hovered) => GestureDetector(
            onTap: toggle,
            child: Container(
              color: hovered ? C.hover : Colors.transparent,
              padding: const EdgeInsets.fromLTRB(10, 12, 8, 12),
              child: Row(children: [
                AnimatedRotation(
                  turns: expanded ? 0 : -0.25,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  child: Icon(Icons.expand_more_rounded, color: C.muted),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Flexible(
                        child: FlagText(sub?.displayName ?? 'Мои серверы',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                      ),
                      // Значок закреплённой подписки.
                      if (sub?.pinned ?? false) ...[
                        const SizedBox(width: 6),
                        Tooltip(
                          message: widget.draggable
                              ? 'Закреплена вверху списка. Перетащите заголовок на другую закреплённую подписку, '
                                  'чтобы поменять их местами'
                              : 'Закреплена вверху списка',
                          child: const Icon(Icons.push_pin_rounded, size: 14, color: C.orange),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 2),
                    Text(subtitle, maxLines: 1, style: TextStyle(color: C.muted, fontSize: 11.5)),
                  ]),
                ),
                if (sub != null)
                  _IconAction(
                    tooltip: 'Обновить подписку',
                    icon: Icons.sync_rounded,
                    busy: updating,
                    onTap: () => state.updateSubscription(sub),
                  ),
                _IconAction(
                  tooltip: sub != null
                      ? 'Проверить задержку (пинг) серверов этой подписки'
                      : 'Проверить задержку (пинг) серверов этого списка',
                  icon: Icons.speed_rounded,
                  busy: state.pinging,
                  onCancel: state.cancelPing,
                  cancelTooltip: 'Остановить проверку задержки',
                  onTap: () => state.ping(widget.servers),
                ),
                // У серверов, добавленных вручную, действий над группой нет — меню только у подписок.
                if (sub != null)
                  _MenuAction(
                    tooltip: 'Ещё',
                    items: [
                      AppMenuItem('pin', sub.pinned ? 'Открепить' : 'Закрепить вверху',
                          icon: sub.pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded),
                      const AppMenuItem('edit', 'Изменить', icon: Icons.edit_rounded),
                      const AppMenuItem('copy', 'Скопировать ссылку', icon: Icons.link_rounded),
                      const AppMenuItem.divider(),
                      const AppMenuItem('delete', 'Удалить подписку', icon: Icons.delete_outline_rounded, danger: true),
                    ],
                    onSelected: (v) async {
                      switch (v) {
                        case 'pin':
                          sub.pinned = !sub.pinned;
                          state.changed();
                        case 'edit':
                          await _edit(state, sub);
                        case 'copy':
                          await Clipboard.setData(ClipboardData(text: sub.url));
                          state.toast('Ссылка скопирована');
                        case 'delete':
                          if (context.mounted &&
                              await confirm(context, 'Удалить подписку?', 'Все её серверы тоже будут удалены.')) {
                            state.deleteSubscription(sub);
                          }
                      }
                    },
                  ),
              ]),
            ),
          ),
        )),
        if (sub != null) _SubscriptionBar(sub),
        if (sub?.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(sub!.error!, style: TextStyle(color: C.red, fontSize: 12)),
          ),
        Reveal(
          open: expanded,
          child: Column(children: [for (final s in widget.servers) _ServerRow(server: s)]),
        ),
      ]),
      ),
    );
  }
}

/// Трафик, срок действия, поддержка и объявление провайдера.
class _SubscriptionBar extends StatelessWidget {
  const _SubscriptionBar(this.sub);
  final Subscription sub;

  @override
  Widget build(BuildContext context) {
    final total = sub.total ?? 0;
    final hasTraffic = sub.total != null || sub.upload != null || sub.download != null;
    final progress = total > 0 ? (sub.used / total).clamp(0.0, 1.0) : 0.0;
    final expire = sub.expire;
    final daysLeft = expire?.difference(DateTime.now()).inDays;
    final announce = sub.announce;
    if (!hasTraffic && expire == null && sub.supportUrl == null && (announce == null || announce.isEmpty)) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(12)),
      child: Column(children: [
        if (hasTraffic || expire != null || sub.supportUrl != null)
          Row(children: [
            if (hasTraffic)
              Expanded(
                child: Stack(alignment: Alignment.center, children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: total > 0 ? progress : 0,
                      minHeight: 18,
                      backgroundColor: C.border,
                      color: progress > 0.9 ? C.red : C.orange.withValues(alpha: 0.75),
                    ),
                  ),
                  Text(
                    total > 0 ? '${formatBytes(sub.used)} / ${formatBytes(total)}' : '${formatBytes(sub.used)} · безлимит',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: C.text),
                  ),
                ]),
              )
            else
              const Spacer(),
            if (expire != null) ...[
              const SizedBox(width: 12),
              Text(
                'Истекает: ${formatDate(expire)}',
                style: TextStyle(fontSize: 12, color: (daysLeft ?? 99) < 3 ? C.red : C.muted),
              ),
            ],
            if (sub.supportUrl != null)
              _IconAction(
                tooltip: 'Поддержка',
                icon: Icons.support_agent_rounded,
                onTap: () => WinSys.openUrl(sub.supportUrl!),
              ),
          ]),
        if (announce != null && announce.isNotEmpty) ...[
          if (hasTraffic || expire != null || sub.supportUrl != null) const SizedBox(height: 8),
          FlagText(announce, textAlign: TextAlign.center, style: TextStyle(color: C.muted, fontSize: 12, height: 1.4)),
        ],
      ]),
    );
  }
}

class _ServerRow extends StatelessWidget {
  const _ServerRow({required this.server});
  final ServerProfile server;

  Future<void> _menu(BuildContext context, AppState state, Offset? at) async {
    final v = await showAppMenu<String>(context, at: at, items: [
      const AppMenuItem('ping', 'Проверить задержку (пинг)', icon: Icons.speed_rounded),
      const AppMenuItem('json', 'Показать JSON', icon: Icons.data_object_rounded),
      if (server.subscriptionId == null) ...const [
        AppMenuItem.divider(),
        AppMenuItem('delete', 'Удалить', icon: Icons.delete_outline_rounded, danger: true),
      ],
    ]);
    if (!context.mounted) return;
    switch (v) {
      case 'ping':
        await state.ping([server]);
      case 'json':
        await _showJson(context, state);
      case 'delete':
        state.deleteServer(server);
    }
  }

  /// Конфиг Xray, с которым программа подключается к этому серверу (с текущими настройками и маршрутизацией).
  Future<void> _showJson(BuildContext context, AppState state) async {
    final String json;
    try {
      json = const JsonEncoder.withIndent('  ')
          .convert(XrayConfig.build(server: server, routing: state.selectedRouting, settings: state.settings));
    } catch (e) {
      state.toast('Не удалось собрать конфиг: $e');
      return;
    }
    // Тот же контроллер плавной прокрутки колесом, что и на страницах программы.
    final scroll = SmoothScrollController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: FlagText(server.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        content: Container(
          width: 760,
          height: 520,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: C.surface2,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: C.border),
          ),
          // Только здесь ползунок всегда виден и светлее обычного: конфиг длинный, а на тёмной
          // подложке стандартный ползунок терялся. В остальной программе он прежний.
          child: ScrollbarTheme(
            data: ScrollbarThemeData(
              thumbVisibility: WidgetStateProperty.all(true),
              thickness: WidgetStateProperty.all(7),
              radius: const Radius.circular(4),
              thumbColor: WidgetStateProperty.resolveWith((s) =>
                  s.contains(WidgetState.dragged) || s.contains(WidgetState.hovered)
                      ? C.orange.withValues(alpha: 0.85)
                      : C.muted.withValues(alpha: 0.6)),
            ),
            child: Scrollbar(
              controller: scroll,
              child: SingleChildScrollView(
                controller: scroll,
                padding: const EdgeInsets.only(right: 12),
                child: SelectableText(json,
                    style: TextStyle(fontFamily: 'Consolas', fontSize: 12.5, height: 1.45, color: C.text)),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть')),
          GradientButton(
            label: 'Скопировать',
            icon: Icons.copy_rounded,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: json));
              state.toast('JSON скопирован');
            },
          ),
        ],
      ),
    );
    scroll.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final selected = state.settings.selectedServerId == server.id;
    final (country, name) = Flags.leading(server.name);
    return Hover(
      builder: (context, hovered) => GestureDetector(
        onTap: () => state.selectServer(server.id),
        onSecondaryTapUp: (d) => _menu(context, state, d.globalPosition),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            color: selected ? C.orange.withValues(alpha: 0.10) : (hovered ? C.hover : Colors.transparent),
            border: Border(top: BorderSide(color: C.border)),
          ),
          child: Row(children: [
            // Оранжевая метка слева у выбранного сервера.
            AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 3,
              height: 60,
              color: selected ? C.orange : Colors.transparent,
            ),
            const SizedBox(width: 13),
            country != null ? FlagIcon.round(country, size: 26) : _NoFlag(server: server),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                FlagText(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 4),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  Tag(server.protocolLabel, color: C.isDark ? C.orangeLight : C.orange),
                  if (server.transportLabel.isNotEmpty) Tag(server.transportLabel),
                  if (server.isJson) Tag('JSON', color: C.cyan),
                ]),
              ]),
            ),
            if (server.warning != null)
              Tooltip(
                message: server.warning!,
                child: const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Icon(Icons.warning_amber_rounded, size: 16, color: C.orangeLight),
                ),
              ),
            if (server.delayMs != null || state.pinging) DelayBadge(server.delayMs, testing: state.pinging),
            Builder(
              builder: (btn) => AnimatedOpacity(
                opacity: hovered ? 1 : 0.35,
                duration: const Duration(milliseconds: 140),
                child: IconButton(
                  tooltip: 'Действия',
                  icon: Icon(Icons.more_vert_rounded, size: 18, color: C.muted),
                  onPressed: () => _menu(btn, state, null),
                ),
              ),
            ),
            const SizedBox(width: 4),
          ]),
        ),
      ),
    );
  }
}

/// Сервер без флага в названии — кружок с глобусом.
class _NoFlag extends StatelessWidget {
  const _NoFlag({required this.server});
  final ServerProfile server;

  @override
  Widget build(BuildContext context) => Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(color: C.surface2, shape: BoxShape.circle, border: Border.all(color: C.border)),
        child: Icon(Icons.public_rounded, size: 16, color: C.muted),
      );
}
