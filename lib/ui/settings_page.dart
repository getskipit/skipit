import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/paths.dart';
import '../core/updates.dart';
import '../core/util.dart';
import '../core/tray.dart';
import '../core/windows.dart';
import '../models/settings.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../version.dart';
import 'theme.dart';
import 'widgets.dart';

/// Скачивает установщик новой версии, запускает его и закрывает программу (чтобы файлы можно было заменить).
Future<void> installAppUpdate(BuildContext context) async {
  final state = AppScope.read(context);
  final release = state.appUpdate;
  if (release == null) return;
  if (state.downloadingAppUpdate) return;
  // Сначала вопрос, потом скачивание: так нажатие сразу даёт ответ, а не десять секунд тишины.
  final ok = await confirm(context, 'Обновить SkipIt до ${release.version}?',
      'Программа скачает установщик, затем VPN отключится, программа закроется и откроется установщик новой версии.',
      ok: 'Скачать и установить');
  if (!ok) return;
  state.toast('Скачиваю обновление ${release.version}…', kind: ToastKind.info);
  String? installer;
  try {
    installer = await state.downloadAppUpdate();
  } catch (e) {
    state.toast('Не удалось скачать обновление: ${describeNetError(e)}');
    return;
  }
  if (installer == null) return;
  try {
    await Process.start(installer, const ['/SP-'], mode: ProcessStartMode.detached);
  } catch (e) {
    // Windows не дала запустить установщик (например, защита от неподписанных программ). Раньше это
    // проходило молча: программа оставалась открытой, и было непонятно, что обновление не случилось.
    state.log.add('update', 'Не удалось запустить установщик: ${Updates.launchFailure(e)}');
    if (!context.mounted) return;
    final show = await confirm(context, 'Windows не разрешила запустить установщик', Updates.launchFailure(e),
        ok: 'Показать файл');
    if (show) await Process.run(AppPaths.explorer, ['/select,$installer']);
    return;
  }
  await state.shutdown();
  await Tray.quit();
  exit(0);
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  /// Версии уже определены, и какого-то ядра нет на месте.
  static bool _coresMissing(AppState state) =>
      state.coreVersions.isNotEmpty && CoreSpec.all.any((c) => state.coreVersions[c.name] == null);
  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final s = state.settings;

    Widget toggle(String title, String subtitle, bool value, void Function(bool) set) => _Row(
          title: title,
          subtitle: subtitle,
          trailing: AppSwitch(
            value: value,
            onChanged: (v) {
              set(v);
              state.changed();
            },
          ),
        );

    Widget number(String title, String subtitle, int value, void Function(int) set) => _Row(
          title: title,
          subtitle: subtitle,
          trailing: SizedBox(
            width: 110,
            child: TextFormField(
              initialValue: '$value',
              textAlign: TextAlign.center,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (v) {
                final n = asInt(v);
                if (n != null && n > 0 && n < 65536) {
                  set(n);
                  state.changed();
                }
              },
            ),
          ),
        );

    Widget text(String title, String subtitle, String value, void Function(String) set, {double width = 340}) => _Row(
          title: title,
          subtitle: subtitle,
          trailing: SizedBox(
            width: width,
            child: TextFormField(
              initialValue: value,
              onChanged: (v) {
                set(v.trim());
                state.changed();
              },
            ),
          ),
        );

    return ListView(
      primary: true,
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        const PageHeader('Настройки', subtitle: 'Изменения портов и ядра применяются при следующем подключении'),
        _Section('Оформление', [
          _Row(
            title: 'Тема',
            subtitle: '«Как в системе» следует за настройкой Windows',
            trailing: Segmented<AppTheme>(
              value: s.theme,
              items: const {AppTheme.dark: 'Тёмная', AppTheme.light: 'Светлая', AppTheme.system: 'Как в системе'},
              onChanged: (v) {
                s.theme = v;
                state.changed();
              },
            ),
          ),
          toggle('Меньше анимаций', 'Списки, меню и переходы срабатывают сразу, без плавного движения. Для слабых компьютеров',
              s.reduceMotion, (v) => s.reduceMotion = v),
        ]),
        _Section('Система', [
          _Row(
            title: 'Права администратора',
            subtitle: state.isAdmin ? 'Есть — режим TUN доступен' : 'Нет — для режима TUN нужен перезапуск',
            // Без прав TUN не включится — подпись красная, чтобы это было видно сразу.
            subtitleColor: state.isAdmin ? null : C.red,
            trailing: state.isAdmin
                ? Icon(Icons.verified_user_rounded, color: C.green)
                : GhostButton(
                    label: 'Перезапустить',
                    icon: Icons.admin_panel_settings_rounded,
                    onPressed: () async {
                      if (await WinSys.relaunchAsAdmin(const [])) {
                        await state.shutdown();
                        await Tray.quit();
                        exit(0);
                      }
                    },
                  ),
          ),
          toggle('Запускать от имени администратора',
              'Нужно для режимов TUN и «Смешанный». При запуске Windows спросит разрешение', s.runAsAdmin,
              (v) => s.runAsAdmin = v),
          toggle('Запускать вместе с Windows', 'Запускать приложение при входе в Windows', state.autostart,
              (v) => state.setAutostart(v)),
          toggle('Сворачивать в трей при закрытии', 'Крестик прячет окно в трей, VPN продолжает работать. Выход — через меню значка в трее',
              s.closeToTray, (v) => s.closeToTray = v),
          toggle('Уведомления Windows', 'Пока окно спрятано, сообщать: VPN оборвался, переподключился, связи через сервер нет. '
                  'И напоминать, что программа осталась в трее',
              s.notifications, (v) => s.notifications = v),
          toggle('Подключаться при запуске', 'Автоматически включать VPN при автозапуске', s.connectOnStart,
              (v) => s.connectOnStart = v),
          toggle('Переподключаться при сбое', 'Перезапускать ядро, если оно упало', s.autoReconnect,
              (v) => s.autoReconnect = v),
        ]),
        _Section('Подключение', [
          _Row(
            title: 'Ядро для TUN',
            subtitle: s.tunCore == TunCore.xray
                ? 'Xray: адаптер поднимает то же ядро, что и подключение, sing-box не запускается'
                : 'sing-box держит адаптер и передаёт трафик в Xray. Действует в режимах TUN и «Смешанный»',
            trailing: Segmented<TunCore>(
              value: s.tunCore,
              items: const {TunCore.singbox: 'sing-box', TunCore.xray: 'Xray'},
              onChanged: (v) {
                s.tunCore = v;
                state.changed();
              },
            ),
          ),
          toggle(
              'Kill Switch',
              'Если VPN оборвался, интернет закрывается, а не идёт напрямую — пока VPN не вернётся или вы сами '
                  'его не откроете. Действует в режимах TUN и «Смешанный»; локальная сеть остаётся доступной',
              s.killSwitch,
              (v) => state.setKillSwitch(v)),
          toggle('Автовыбор сервера', 'Перед подключением выбирать самый быстрый сервер подписки', s.autoSelect,
              (v) => s.autoSelect = v),
          toggle('Разрешить подключения из локальной сети', 'Раздавать прокси другим устройствам (0.0.0.0)', s.allowLan,
              (v) => s.allowLan = v),
        ]),
        _Section('Проверка задержки', [
          _Row(
            title: 'Тип проверки',
            subtitle: 'Реальная — запрос через сервер, TCP — только доступность порта',
            trailing: Segmented<PingType>(
              value: s.pingType,
              items: const {PingType.realDelay: 'Реальная', PingType.tcp: 'TCP'},
              onChanged: (v) {
                s.pingType = v;
                state.changed();
              },
            ),
          ),
        ]),
        _Section('Подписки', [
          toggle('Обновлять при запуске', 'Загружать свежий список серверов при старте', s.updateSubsOnStart,
              (v) => s.updateSubsOnStart = v),
          toggle('Обновлять через VPN', 'Если подключено — качать подписку через туннель', s.updateViaProxy,
              (v) => s.updateViaProxy = v),        ]),
        _CollapsibleSection('Дополнительно', 'Порты, MTU, сниффинг, логи, адрес проверки, User-Agent и HWID — обычно менять не нужно', [
          number('SOCKS-порт', 'Локальный SOCKS5-прокси', s.socksPort, (v) => s.socksPort = v),
          number('HTTP-порт', 'Используется системным прокси', s.httpPort, (v) => s.httpPort = v),
          toggle(
              'Пароль на локальные порты',
              'Другие программы смогут ходить через порты SOCKS и HTTP только с логином и паролем. HTTP-порт '
                  'остаётся без пароля в режимах «Смешанный» и «Прокси»: им пользуется Windows, а она пароль '
                  'передать не умеет',
              s.portAuth,
              (v) => state.setPortAuth(v)),
          if (s.portAuth) ...[
            _Row(
              title: 'Логин портов',
              subtitle: AppSettings.portUser,
              trailing: IconButton(
                tooltip: 'Скопировать логин',
                icon: const Icon(Icons.copy_rounded),
                onPressed: () => Clipboard.setData(const ClipboardData(text: AppSettings.portUser)),
              ),
            ),
            _PortPasswordRow(state: state),
          ],
          number('Порт API статистики', 'Для счётчиков трафика', s.apiPort, (v) => s.apiPort = v),
          toggle('IPv6', 'Включить IPv6 в туннеле и DNS', s.ipv6, (v) => s.ipv6 = v),
          toggle('Сниффинг', 'Определять домен по TLS/HTTP/QUIC — нужен для маршрутизации по сайтам', s.sniffing,
              (v) => s.sniffing = v),
          number('MTU TUN-адаптера', 'Обычно 9000 или 1500', s.mtu, (v) => s.mtu = v),
          _Row(
            title: 'Уровень логов',
            subtitle: 'debug — максимум подробностей',
            trailing: AppDropdown<String>(
              value: s.logLevel,
              items: const {'debug': 'debug', 'info': 'info', 'warning': 'warning', 'error': 'error', 'none': 'none'},
              onChanged: (v) {
                s.logLevel = v;
                state.changed();
              },
            ),
          ),
          text('Адрес для проверки', 'Должен отвечать быстро (204)', s.testUrl, (v) => s.testUrl = v),
          _Row(
            title: 'User-Agent',
            subtitle: 'Некоторые панели отдают разный формат по User-Agent',
            trailing: SizedBox(
              width: 340,
              child: _UserAgentField(
                value: s.userAgent,
                onChanged: (v) {
                  // Пустое поле — это стандартное значение, а не пустой заголовок в запросе.
                  s.userAgent = v.isEmpty ? AppSettings.defaultUserAgent : v;
                  state.changed();
                },
              ),
            ),
          ),
          toggle('Отправлять HWID', 'Заголовки x-hwid / x-device-os для лимита устройств у провайдера', s.sendHwid,
              (v) => s.sendHwid = v),
          _Row(
            title: 'HWID устройства',
            subtitle: s.hwid,
            trailing: IconButton(
              icon: const Icon(Icons.copy_rounded),
              onPressed: () => Clipboard.setData(ClipboardData(text: s.hwid)),
            ),
          ),
        ]),
        _Section('О приложении', [
          _Row(
            title: 'Папка данных',
            subtitle: 'Настройки, подписки и журнал (папка logs)',
            trailing: GhostButton(
              label: 'Открыть',
              icon: Icons.folder_open_rounded,
              onPressed: () => Process.run(AppPaths.explorer, [AppPaths.dataDir.path]),
            ),
          ),
          // Подписки на диске зашифрованы для этой учётной записи Windows: перенести их на другой
          // компьютер копированием папки нельзя — для этого экспорт и импорт.
          _Row(
            title: 'Перенос настроек',
            subtitle: 'Подписки хранятся зашифрованными для вашей учётной записи Windows. '
                'Для переноса на другой компьютер сохраните их в файл',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              GhostButton(
                label: 'Экспорт',
                icon: Icons.upload_rounded,
                onPressed: () async {
                  final ok = await confirm(context, 'Сохранить настройки в файл?',
                      'В файле будут ссылки подписок и ключи серверов открытым текстом. '
                          'Храните его как пароль и удалите после переноса.');
                  if (!ok) return;
                  final dir = await WinSys.pickFolder();
                  if (dir == null) return;
                  try {
                    final path = await state.exportData(dir);
                    state.toast('Сохранено: ${path.split(r'\').last}');
                  } catch (e) {
                    state.toast('Не удалось сохранить файл: ${describeNetError(e)}');
                  }
                },
              ),
              const SizedBox(width: 8),
              GhostButton(
                label: 'Импорт',
                icon: Icons.download_rounded,
                onPressed: () async {
                  final path = await WinSys.pickFile(filter: 'Настройки SkipIt (*.json)|*.json');
                  if (path == null || !context.mounted) return;
                  final ok = await confirm(context, 'Заменить настройки?',
                      'Текущие подписки, серверы и настройки будут заменены содержимым файла.');
                  if (!ok) return;
                  final error = await state.importData(path);
                  state.toast(error ?? 'Настройки загружены из файла',
                      kind: error == null ? ToastKind.success : ToastKind.error);
                },
              ),
            ]),
          ),
          _Row(
            title: 'Версия SkipIt',
            subtitle: [
              appVersion,
              if (AppPaths.isDev) 'тестовая сборка, данные отдельно от установленной программы',
              if (state.appUpdate != null) 'доступна ${state.appUpdate!.version}',
              if (state.lastUpdateCheck != null) 'проверено ${formatDateTime(state.lastUpdateCheck!)}',
            ].join(' · '),
            trailing: Wrap(spacing: 8, children: [
              if (state.appUpdate != null)
                state.downloadingAppUpdate
                    ? Row(mainAxisSize: MainAxisSize.min, children: [
                        const Spinner(size: 20),
                        const SizedBox(width: 8),
                        Text(state.updateProgressLabel, style: TextStyle(color: C.muted, fontSize: 12.5)),
                      ])
                    : GradientButton(
                        label: 'Обновить',
                        icon: Icons.download_rounded,
                        onPressed: () => installAppUpdate(context),
                      ),
              GhostButton(
                label: 'Проверить обновления',
                icon: Icons.system_update_alt_rounded,
                busy: state.checkingUpdates,
                onPressed: state.checkUpdates,
              ),
            ]),
          ),
          _Row(
            title: 'Канал обновлений',
            subtitle: s.updateChannel == UpdateChannel.beta
                ? 'Бета: вместе с релизами приходят и пре-релизы — новые функции раньше, но возможны ошибки'
                : 'Стабильный: только стабильные версии',
            trailing: Segmented<UpdateChannel>(
              value: s.updateChannel,
              items: const {UpdateChannel.stable: 'Стабильный', UpdateChannel.beta: 'Бета'},
              onChanged: (v) {
                s.updateChannel = v;
                state.appUpdate = null;
                state.changed();
                state.checkUpdates(silent: true);
              },
            ),
          ),
          // Ядра вложены в программу и обновляются только вместе с ней — здесь лишь их версии, одной строкой.
          // Значок появляется, только если какое-то ядро не найдено (повреждённая установка).
          _Row(
            title: 'Ядра',
            subtitle: [
              for (final core in CoreSpec.all) '${core.name} ${state.coreVersions[core.name] ?? '— не найдено'}',
            ].join(' · '),
            subtitleColor: _coresMissing(state) ? C.red : null,
            trailing: _coresMissing(state)
                ? Tooltip(
                    message: 'Ядро не найдено — переустановите SkipIt',
                    child: Icon(Icons.error_rounded, color: C.red, size: 20),
                  )
                : const SizedBox.shrink(),
          ),
        ]),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(28, 0, 28, 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(title.toUpperCase(),
                style: const TextStyle(color: C.orange, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.6)),
          ),
          Panel(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
            child: Column(children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                children[i],
              ],
            ]),
          ),
        ]),
      );
}

/// Поле User-Agent с кнопкой «Сбросить»: она появляется, когда значение отличается от стандартного.
class _UserAgentField extends StatefulWidget {
  const _UserAgentField({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_UserAgentField> createState() => _UserAgentFieldState();
}

class _UserAgentFieldState extends State<_UserAgentField> {
  late final _text = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _text,
        decoration: InputDecoration(
          suffixIcon: _text.text.trim() == AppSettings.defaultUserAgent
              ? null
              : Tooltip(
                  message: 'Сбросить: ${AppSettings.defaultUserAgent}',
                  child: Hover(
                    builder: (context, hovered) => GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        setState(() => _text.text = AppSettings.defaultUserAgent);
                        widget.onChanged(AppSettings.defaultUserAgent);
                      },
                      child: Icon(Icons.restart_alt_rounded, size: 18, color: hovered ? C.orange : C.muted),
                    ),
                  ),
                ),
        ),
        onChanged: (v) {
          setState(() {});
          widget.onChanged(v.trim());
        },
      );
}

/// Пароль локальных портов: скрыт точками, пока его не попросят показать; копируется и сменяется кнопками.
class _PortPasswordRow extends StatefulWidget {
  const _PortPasswordRow({required this.state});
  final AppState state;

  @override
  State<_PortPasswordRow> createState() => _PortPasswordRowState();
}

class _PortPasswordRowState extends State<_PortPasswordRow> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final password = state.settings.portPassword;
    return _Row(
      title: 'Пароль портов',
      subtitle: _shown ? password : '•' * 16,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: _shown ? 'Скрыть пароль' : 'Показать пароль',
          icon: Icon(_shown ? Icons.visibility_off_rounded : Icons.visibility_rounded),
          onPressed: () => setState(() => _shown = !_shown),
        ),
        IconButton(
          tooltip: 'Скопировать пароль',
          icon: const Icon(Icons.copy_rounded),
          onPressed: () => Clipboard.setData(ClipboardData(text: password)),
        ),
        IconButton(
          tooltip: 'Новый пароль',
          icon: const Icon(Icons.refresh_rounded),
          onPressed: () async {
            final ok = await confirm(context, 'Сменить пароль портов?',
                'Старый пароль перестанет действовать. Программам, в которые он вписан, понадобится новый.',
                ok: 'Сменить');
            if (ok) state.resetPortPassword();
          },
        ),
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.title, required this.subtitle, required this.trailing, this.subtitleColor});
  final String title;
  final String subtitle;
  final Widget trailing;

  /// Цвет подписи, если на неё нужно обратить внимание (по умолчанию — приглушённый).
  final Color? subtitleColor;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              SelectableText(subtitle,
                  style: TextStyle(
                    color: subtitleColor ?? C.muted,
                    fontSize: 12,
                    fontWeight: subtitleColor != null ? FontWeight.w600 : null,
                  )),
            ]),
          ),
          const SizedBox(width: 16),
          trailing,
        ]),
      );
}

/// Секция, свёрнутая по умолчанию — для технических параметров.
class _CollapsibleSection extends StatefulWidget {
  const _CollapsibleSection(this.title, this.hint, this.children);
  final String title;
  final String hint;
  final List<Widget> children;

  @override
  State<_CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<_CollapsibleSection> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(28, 0, 28, 18),
        // Заголовок и содержимое — одна карточка: раскрытый список не «отрывается» от своего заголовка.
        child: Container(
          decoration: BoxDecoration(
            color: C.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: C.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Hover(
              builder: (context, hovered) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _open = !_open),
                child: Container(
                  color: hovered ? C.hover : Colors.transparent,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(widget.title.toUpperCase(),
                            style: const TextStyle(
                                color: C.orange, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.6)),
                        const SizedBox(height: 3),
                        Text(widget.hint, style: TextStyle(color: C.muted, fontSize: 12)),
                      ]),
                    ),
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      child: Icon(Icons.expand_more_rounded, color: hovered ? C.orange : C.muted),
                    ),
                  ]),
                ),
              ),
            ),
            Reveal(
              open: _open,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Column(children: [
                  for (final child in widget.children) ...[const Divider(height: 1), child],
                  const SizedBox(height: 4),
                ]),
              ),
            ),
          ]),
        ),
      );
}