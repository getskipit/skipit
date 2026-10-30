import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/util.dart';
import '../models/settings.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import 'app_menu.dart';
import 'flag_text.dart';
import 'servers_panel.dart';
import 'shell.dart';
import 'smooth_scroll.dart';
import 'theme.dart';
import 'widgets.dart';
import '../l10n/l10n.dart';

/// Главная: слева кнопка подключения и режимы, справа список серверов.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final Timer _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && AppScope.read(context).isConnected) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final connected = state.isConnected;

    final statusText = switch (state.status) {
      // Ядро работает, но сервер не отвечает — писать «Защищено» было бы неправдой.
      ConnStatus.connected when state.linkDown => tr('Нет связи'),
      ConnStatus.connected => tr('Защищено'),
      ConnStatus.connecting => tr('Подключаемся…'),
      ConnStatus.disconnecting => tr('Отключаемся…'),
      // Перед подключением закрывается другой VPN — это уже часть подключения, а не простой.
      ConnStatus.disconnected when state.closingOtherVpn => tr('Подключаемся…'),
      ConnStatus.disconnected => tr('Не подключено'),
    };

    final blockedCore = state.firewallBlockedCore;
    final Widget? notice = !connected
        ? null
        : blockedCore != null
            ? _NoticeBox(
                icon: Icons.gpp_bad_rounded,
                color: C.red,
                title: tr('Файрвол не пускает SkipIt в сеть'),
                text: tr('Разрешите в файрволе файл {0} и подключитесь снова', [blockedCore]),
                actionLabel: tr('Показать файл'),
                actionIcon: Icons.folder_open_rounded,
                onAction: () => state.showCoreFile(blockedCore),
              )
            : state.linkDown
                ? _NoticeBox(
                    icon: Icons.cloud_off_rounded,
                    color: C.red,
                    title: tr('VPN подключён, но связи нет'),
                    text: tr('Сервер не отвечает. Попробуйте переподключиться или выбрать другой сервер'),
                    actionLabel: tr('Переподключиться'),
                    actionIcon: Icons.refresh_rounded,
                    onAction: state.isBusy ? null : state.reconnect,
                  )
                : state.appRulesPending
                    ? _NoticeBox(
                        icon: Icons.info_rounded,
                        color: C.orange,
                        title: tr('Список программ изменён'),
                        text: tr('Правила по приложениям (Маршрутизация → Приложения) начнут действовать '
                            'после переподключения'),
                        actionLabel: tr('Применить'),
                        actionIcon: Icons.refresh_rounded,
                        onAction: state.isBusy ? null : state.reconnect,
                      )
                    : null;

    // Части, которые можно спрятать в Настройках → Внешний вид → «На главной».
    final show = state.settings.homeShows;
    final stage = Column(mainAxisSize: MainAxisSize.min, children: [
      ConnectGlow(
        active: connected,
        child: ConnectButton(
          connected: connected,
          // Стрелки «летят» только при подключении; отключение мгновенное, для него анимация не нужна.
          busy: state.status == ConnStatus.connecting || state.closingOtherVpn,
          onTap: () => connectOrToggle(context),
        ),
      ),
      const SizedBox(height: 22),
      Text(statusText.toUpperCase(),
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
            color: connected ? C.text : C.muted,
          )),
      Reveal(open: show('timer'), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(height: 6),
      Text(
        connected && state.connectedAt != null
            ? formatDuration(DateTime.now().difference(state.connectedAt!))
            : state.closingOtherVpn
                ? tr('Закрываю другой VPN…')
                : (state.status == ConnStatus.connecting ? tr('Нажмите, чтобы отменить') : tr('Нажмите, чтобы подключиться')),
        style: TextStyle(
          color: connected ? (C.isDark ? C.orangeLight : C.orange) : C.muted,
          fontSize: connected ? 18 : 13,
          fontWeight: connected ? FontWeight.w700 : FontWeight.w400,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      // Откуда сайты видят компьютер и стоит ли Kill Switch. Высота постоянная: строка появляется
      // через пару секунд после подключения, и всё, что ниже, не должно прыгать.
      const SizedBox(height: 5),
      SizedBox(
        height: 16,
        // Пока связи нет, последняя известная страна не показывается: сейчас это уже неправда.
        child: connected
            ? _ExitInfo(
                country: state.linkDown ? null : state.exitCountry,
                ip: state.linkDown ? null : state.exitIp,
                killSwitch: state.killSwitchOn,
                onCopyIp: (ip) async {
                  await Clipboard.setData(ClipboardData(text: ip));
                  state.toast(tr('IP скопирован'), kind: ToastKind.success, detail: ip);
                },
              )
            : null,
      ),
      ])),
      Reveal(open: show('mode'), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(height: 12),
      Segmented<ConnectionMode>(
        value: state.settings.mode,
        items: {
          for (final m in const [
            ConnectionMode.mixed,
            ConnectionMode.tun,
            ConnectionMode.systemProxy,
            ConnectionMode.proxyOnly,
          ])
            m: m.label,
        },
        onChanged: (m) => state.setMode(m),
      ),
      const SizedBox(height: 10),
      // Фиксированная высота: при смене режима колонка не «прыгает».
      SizedBox(
        width: 360,
        height: 34,
        child: Text(
          switch (state.settings.mode) {
            ConnectionMode.tun => tr('Весь трафик компьютера через VPN'),
            ConnectionMode.mixed => tr('Браузеры — через прокси, остальное — через TUN'),
            ConnectionMode.systemProxy => tr('Только браузеры и программы с поддержкой прокси'),
            ConnectionMode.proxyOnly =>
              tr('Система не меняется · SOCKS :{0} · HTTP :{1}', [state.settings.socksPort, state.settings.httpPort]) +
                  // Порты под паролем: без подсказки непонятно, почему программа с одним адресом не подключается.
                  (state.settings.portAuth ? tr('\nс логином и паролем — Настройки → Для опытных') : ''),
          },
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: C.muted, fontSize: 12),
        ),
      ),
      // Чем поднимать адаптер — только в режимах с TUN; строка плавно выезжает и прячется.
      Reveal(
        open: state.usesTun,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: _TunCorePicker(value: state.settings.tunCore, onChanged: state.setTunCore),
        ),
      ),
      ])),
      Reveal(open: show('speed'), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(height: 8),
      SizedBox(
        width: 360,
        // Счётчики меняются раз в секунду — перестраиваются только эти плитки.
        child: ListenableBuilder(
          listenable: state.stats,
          builder: (context, _) => Row(children: [
            Expanded(child: _Speed(icon: Icons.arrow_upward_rounded, label: tr('Отдача'), speed: state.stats.upSpeed, vpn: state.stats.vpnUp, direct: state.stats.directUp, active: connected)),
            const SizedBox(width: 10),
            Expanded(child: _Speed(icon: Icons.arrow_downward_rounded, label: tr('Загрузка'), speed: state.stats.downSpeed, vpn: state.stats.vpnDown, direct: state.stats.directDown, active: connected)),
          ]),
        ),
      ),
      ])),
      Reveal(open: show('routing'), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(height: 10),
      SizedBox(width: 360, child: _RoutingInfo(summary: state.routingSummary, onTap: () => state.openPage(AppState.routingPage))),
      ])),
      // Kill Switch держит интернет закрытым без VPN — это видно, пока его не снимут или VPN не вернётся.
      if (state.killSwitchHolding) ...[
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: _KillSwitchBox(onRelease: state.releaseKillSwitch),
        ),
      ],
      // Подсказки о том, что мешает VPN. Одна за раз, самая важная; при ошибке или закрытом
      // интернете не показываются — там уже сказано главное.
      if (!state.killSwitchHolding && state.lastError == null && notice != null) ...[
        const SizedBox(height: 14),
        ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360), child: notice),
      ],
      if (state.lastError != null) ...[
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: _ErrorBox(
            state.lastError!,
            key: ValueKey(state.lastError),
            onClose: state.clearError,
            // Адаптер TUN не поднялся — предлагаем сразу подключиться в режиме, которому он не нужен.
            actionLabel: state.tunFailed ? tr('Подключиться в режиме «Прокси»') : null,
            onAction: () async {
              await state.setMode(ConnectionMode.systemProxy);
              if (context.mounted) await connectOrToggle(context);
            },
          ),
        ),
      ],
    ]);

    return LayoutBuilder(
      builder: (context, c) => c.maxWidth >= 860
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 400,
                // Свой контроллер плавной прокрутки: основной контроллер страницы занят списком серверов.
                child: SmoothScroll(
                  builder: (context, controller) => SingleChildScrollView(
                    controller: controller,
                    padding: const EdgeInsets.fromLTRB(20, 40, 20, 24),
                    child: stage,
                  ),
                ),
              ),
              const Expanded(
                // Правый отступ вместе с дорожкой полосы прокрутки в списке даёт те же 24 точки.
                child: Padding(padding: EdgeInsets.fromLTRB(4, 24, 24 - scrollGutter, 0), child: ServersPanel()),
              ),
            ])
          : ListView(
              primary: true,
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
              children: [Center(child: stage), const SizedBox(height: 28), const ServersPanel(scrollable: false)],
            ),
    );
  }
}

/// Выбор ядра, которое поднимает TUN-адаптер: небольшая кнопка с выпадающим меню.
/// Название ядра на кнопке. Сначала гаснет старое название, затем проявляется новое; ширина кнопки меняется
/// всё это время — так длинная надпись не обрезается на глазах. Новое название ложится на скрытую сторону
/// AnimatedCrossFade, и стороны меняются местами.
class _CoreName extends StatefulWidget {
  const _CoreName(this.name);
  final String name;

  @override
  State<_CoreName> createState() => _CoreNameState();
}

class _CoreNameState extends State<_CoreName> {
  late String _first = widget.name, _second = widget.name;
  bool _showSecond = false;

  @override
  void didUpdateWidget(_CoreName old) {
    super.didUpdateWidget(old);
    if (widget.name == (_showSecond ? _second : _first)) return;
    if (_showSecond) {
      _first = widget.name;
    } else {
      _second = widget.name;
    }
    _showSecond = !_showSecond;
  }

  @override
  Widget build(BuildContext context) => AnimatedCrossFade(
        duration: const Duration(milliseconds: 320),
        sizeCurve: Curves.easeInOutCubic,
        firstCurve: const Interval(0.55, 1),
        secondCurve: const Interval(0.55, 1),
        alignment: Alignment.centerLeft,
        crossFadeState: _showSecond ? CrossFadeState.showSecond : CrossFadeState.showFirst,
        firstChild: Text(_first, maxLines: 1, softWrap: false, style: _TunCorePicker._coreStyle),
        secondChild: Text(_second, maxLines: 1, softWrap: false, style: _TunCorePicker._coreStyle),
      );
}

class _TunCorePicker extends StatelessWidget {
  const _TunCorePicker({required this.value, required this.onChanged});
  final TunCore value;
  final ValueChanged<TunCore> onChanged;

  static const _coreStyle = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700);

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tr('Как работает TUN: Xray или sing-box — пояснение внизу списка'),
        waitDuration: const Duration(milliseconds: 500),
        child: Hover(
          builder: (context, hovered) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () async {
              final picked = await showAppMenu<TunCore>(context, centered: true, items: [
                AppMenuItem(TunCore.xray, 'Xray',
                    checked: value == TunCore.xray,
                    description: tr('Всё делает ядро Xray: перехватывает трафик компьютера и решает, что отправить через '
                        'VPN-сервер, а что напрямую — мимо него')),
                AppMenuItem(TunCore.singbox, 'sing-box',
                    checked: value == TunCore.singbox,
                    description: tr('Трафик перехватывает ядро sing-box и передаёт его Xray, а тот решает, что отправить '
                        'через VPN-сервер, а что напрямую')),
              ]);
              if (picked != null) onChanged(picked);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
              decoration: BoxDecoration(
                color: hovered ? C.surface2 : C.surface,
                borderRadius: BorderRadius.circular(C.r(11)),
                border: Border.all(color: hovered ? C.orange.withValues(alpha: 0.5) : C.border),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(tr('Режим TUN'), style: TextStyle(color: C.muted, fontSize: 12)),
                const SizedBox(width: 8),
                _CoreName(value == TunCore.xray ? 'Xray' : 'sing-box'),
                const SizedBox(width: 4),
                Icon(Icons.expand_more_rounded, size: 18, color: hovered ? C.orange : C.muted),
              ]),
            ),
          ),
        ),
      );
}

/// Какая маршрутизация сейчас действует; клик открывает раздел «Маршрутизация».
class _RoutingInfo extends StatefulWidget {
  const _RoutingInfo({required this.summary, required this.onTap});
  final ({String sites, String? apps}) summary;
  final VoidCallback onTap;

  @override
  State<_RoutingInfo> createState() => _RoutingInfoState();
}

class _RoutingInfoState extends State<_RoutingInfo> {
  /// Последний текст про программы: пока строка плавно прячется, он ещё нужен на экране.
  String _apps = '';

  ({String sites, String? apps}) get summary => widget.summary;
  VoidCallback get onTap => widget.onTap;

  @override
  Widget build(BuildContext context) {
    if (summary.apps != null) _apps = summary.apps!;
    return _tile(context);
  }

  Widget _tile(BuildContext context) => Tooltip(
        message: tr('Открыть маршрутизацию'),
        waitDuration: const Duration(milliseconds: 500),
        child: Hover(
          builder: (context, hovered) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: hovered ? C.surface2 : C.surface,
                borderRadius: BorderRadius.circular(C.r(14)),
                border: Border.all(color: hovered ? C.orange.withValues(alpha: 0.5) : C.border),
              ),
              child: Row(children: [
                Icon(Icons.alt_route_rounded, size: 18, color: hovered ? C.orange : C.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Маршрутизация'), style: TextStyle(color: C.muted, fontSize: 11)),
                    FlagText(summary.sites,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    // Правила по программам — отдельной строкой; она плавно выезжает и прячется
                    // при смене режима (в режимах без TUN эти правила не действуют).
                    Reveal(
                      open: summary.apps != null,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(_apps, style: TextStyle(color: C.muted, fontSize: 12)),
                        ),
                      ),
                    ),
                  ]),
                ),
                Icon(Icons.chevron_right_rounded, size: 18, color: hovered ? C.orange : C.muted),
              ]),
            ),
          ),
        ),
      );
}

/// Kill Switch держит интернет закрытым: объяснение и кнопка, которая открывает его без VPN.
class _KillSwitchBox extends StatelessWidget {
  const _KillSwitchBox({required this.onRelease});
  final VoidCallback onRelease;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: C.orange.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(C.r(14)),
          border: Border.all(color: C.orange.withValues(alpha: 0.45)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.shield_rounded, size: 18, color: C.orange),
            const SizedBox(width: 8),
            Expanded(
              child: Text(tr('Интернет закрыт: Kill Switch'),
                  style: TextStyle(color: C.text, fontSize: 13, fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(tr('VPN не подключён, поэтому программы не выпускаются в сеть напрямую. '
              'Подключитесь снова или откройте интернет без VPN.'),
              style: TextStyle(color: C.muted, fontSize: 12.5)),
          const SizedBox(height: 10),
          GhostButton(label: tr('Открыть интернет без VPN'), icon: Icons.lock_open_rounded, onPressed: onRelease),
        ]),
      );
}

/// Подсказка на главной: что мешает VPN и кнопка, которая это исправляет.
class _NoticeBox extends StatelessWidget {
  const _NoticeBox({
    required this.icon,
    required this.color,
    required this.title,
    required this.text,
    required this.actionLabel,
    required this.actionIcon,
    required this.onAction,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String text;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(C.r(14)),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title, style: TextStyle(color: C.text, fontSize: 13, fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(text, style: TextStyle(color: C.muted, fontSize: 12.5)),
          const SizedBox(height: 10),
          GhostButton(label: actionLabel, icon: actionIcon, onPressed: onAction),
        ]),
      );
}

/// Строка под временем подключения: страна выхода (флаг и название) и отметка Kill Switch.
class _ExitInfo extends StatelessWidget {
  const _ExitInfo({required this.country, required this.ip, required this.killSwitch, required this.onCopyIp});
  final String? country;
  final String? ip;
  final bool killSwitch;
  final void Function(String ip) onCopyIp;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(color: C.muted, fontSize: 12);
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
      if (country != null) ...[
        Tooltip(
          message: tr('Из этой страны сайты видят ваш компьютер'),
          waitDuration: const Duration(milliseconds: 500),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            FlagIcon(country!, height: 11),
            const SizedBox(width: 6),
            Text(Flags.countryName(country!), style: style),
          ]),
        ),
      ],
      // Внешний IP: по нажатию копируется.
      if (country != null && ip != null) Text('  ·  ', style: style),
      if (ip != null)
        Flexible(
          child: Tooltip(
            message: tr('Внешний IP — с этого адреса сайты видят ваш компьютер. Нажмите, чтобы скопировать'),
            waitDuration: const Duration(milliseconds: 500),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => onCopyIp(ip!),
                child: Text(ip!, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
        ),
      if ((country != null || ip != null) && killSwitch) Text('  ·  ', style: style),
      if (killSwitch) ...[
        Icon(Icons.shield_rounded, size: 12, color: C.muted),
        const SizedBox(width: 4),
        Text('Kill Switch', style: style),
      ],
    ]);
  }
}

/// Сообщение об ошибке подключения. Закрывается крестиком и само исчезает через 10 секунд;
/// пока на нём курсор (читают или выделяют текст) — не исчезает.
class _ErrorBox extends StatefulWidget {
  const _ErrorBox(this.text, {super.key, required this.onClose, this.actionLabel, this.onAction});
  final String text;
  final VoidCallback onClose;

  /// Кнопка быстрого выхода из ситуации под текстом ошибки (например, сменить режим).
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  State<_ErrorBox> createState() => _ErrorBoxState();
}

class _ErrorBoxState extends State<_ErrorBox> {
  Timer? _timer;

  void _arm() {
    _timer?.cancel();
    // С кнопкой действия сообщение живёт дольше: нужно успеть прочитать и решить.
    _timer = Timer(Duration(seconds: widget.actionLabel != null ? 25 : 10), () {
      if (mounted) widget.onClose();
    });
  }

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => _timer?.cancel(),
        onExit: (_) => _arm(),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          decoration: BoxDecoration(
            color: C.red.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(C.r(14)),
            border: Border.all(color: C.red.withValues(alpha: 0.4)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SelectableText(widget.text, style: TextStyle(color: C.red, fontSize: 13)),
                if (widget.actionLabel != null) ...[
                  const SizedBox(height: 10),
                  GhostButton(label: widget.actionLabel!, icon: Icons.bolt_rounded, onPressed: widget.onAction),
                ],
              ]),
            ),
            Tooltip(
              message: tr('Закрыть'),
              child: Hover(
                builder: (context, hovered) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onClose,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Icon(Icons.close_rounded, size: 18, color: hovered ? C.text : C.red),
                  ),
                ),
              ),
            ),
          ]),
        ),
      );
}
class _Speed extends StatelessWidget {
  const _Speed({required this.icon, required this.label, required this.speed, required this.vpn, required this.direct, required this.active});
  final IconData icon;
  final String label;
  final int speed;

  /// Сколько всего прошло через VPN и сколько напрямую.
  final int vpn, direct;
  final bool active;

  Widget _total(String name, int bytes) => Row(children: [
        Text(name, style: TextStyle(color: C.muted, fontSize: 10.5)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(formatBytes(bytes),
              maxLines: 1, textAlign: TextAlign.right, style: TextStyle(color: C.muted, fontSize: 10.5)),
        ),
      ]);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(C.r(14)),
          border: Border.all(color: C.border),
        ),
        child: Row(children: [
          Icon(icon, size: 18, color: active ? C.orange : C.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(color: C.muted, fontSize: 11)),
              Text(active ? formatSpeed(speed) : '—',
                  maxLines: 1, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
              if (active) ...[
                const SizedBox(height: 2),
                _total('VPN', vpn),
                _total(tr('Напрямую'), direct),
              ],
            ]),
          ),
        ]),
      );
}
