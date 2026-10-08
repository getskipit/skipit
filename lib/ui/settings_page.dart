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

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();

  /// Версии уже определены, и какого-то ядра нет на месте.
  static bool _coresMissing(AppState state) =>
      state.coreVersions.isNotEmpty && CoreSpec.all.any((c) => state.coreVersions[c.name] == null);
}

class _SettingsPageState extends State<SettingsPage> {
  /// Поиск по настройкам: остаются строки, в названии или подписи которых есть введённый текст.
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

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

    final sections = <Widget>[
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
            _PortSecretRow(
              title: 'Логин портов',
              what: 'логин',
              value: s.portUser,
              onReset: state.resetPortUser,
            ),
            _PortSecretRow(
              title: 'Пароль портов',
              what: 'пароль',
              value: s.portPassword,
              onReset: state.resetPortPassword,
            ),
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
            subtitleColor: SettingsPage._coresMissing(state) ? C.red : null,
            trailing: SettingsPage._coresMissing(state)
                ? Tooltip(
                    message: 'Ядро не найдено — переустановите SkipIt',
                    child: Icon(Icons.error_rounded, color: C.red, size: 20),
                  )
                : const SizedBox.shrink(),
          ),
        ]),
    ];

    final query = _query.trim().toLowerCase();
    final found = sections.any((s) => switch (s) {
          _Section s => _found(s.title, s.children, query).isNotEmpty,
          _CollapsibleSection s => _found(s.title, s.children, query).isNotEmpty,
          _ => true,
        });
    return _SettingsQuery(
      query: query,
      child: ListView(
        primary: true,
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          PageHeader('Настройки', subtitle: 'Изменения портов и ядра применяются при следующем подключении', actions: [
            SizedBox(
              width: 260,
              child: TextField(
                controller: _search,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'Поиск по настройкам',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Очистить',
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () => setState(() {
                            _search.clear();
                            _query = '';
                          }),
                        ),
                ),
              ),
            ),
          ]),
          ...sections,
          if (!found)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text('Ничего не найдено. Попробуйте другое слово — например, «порт» или «трей».',
                  style: TextStyle(color: C.muted, fontSize: 13)),
            ),
        ],
      ),
    );
  }
}

/// Текст поиска по настройкам (строчными буквами; пустой — поиска нет) — для разделов страницы.
class _SettingsQuery extends InheritedWidget {
  const _SettingsQuery({required this.query, required super.child});
  final String query;

  static String of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SettingsQuery>()?.query ?? '';

  @override
  bool updateShouldNotify(_SettingsQuery old) => old.query != query;
}

/// Ключевые слова строк настроек (по названию строки): слова, которыми настройку ищут, хотя в её
/// названии и подписи их нет.
const _keywords = <String, String>{
  'Тема': 'оформление цвет тёмная темная светлая ночная dark light вид',
  'Меньше анимаций': 'анимация плавность тормозит лагает производительность слабый компьютер',
  'Права администратора': 'админ администратор uac перезапуск',
  'Запускать от имени администратора': 'админ администратор uac права',
  'Запускать вместе с Windows': 'автозапуск автозагрузка старт включение компьютера',
  'Сворачивать в трей при закрытии': 'трей значок крестик закрыть фон свернуть',
  'Уведомления Windows': 'оповещения сообщения всплывающие',
  'Подключаться при запуске': 'автоподключение автозапуск старт',
  'Переподключаться при сбое': 'обрыв падение автоматически восстановить',
  'Ядро для TUN': 'xray sing-box singbox адаптер ядро',
  'Kill Switch': 'килл свитч защита утечка обрыв блокировка интернета',
  'Автовыбор сервера': 'лучший быстрый пинг авто',
  'Разрешить подключения из локальной сети': 'lan wifi роутер телефон раздать другим устройствам',
  'Тип проверки': 'пинг задержка ping tcp скорость',
  'Обновлять при запуске': 'подписка серверы список',
  'Обновлять через VPN': 'подписка прокси',
  'SOCKS-порт': 'порт прокси proxy socks5 10808',
  'HTTP-порт': 'порт прокси proxy 10809',
  'Пароль на локальные порты': 'логин авторизация защита доступ безопасность',
  'Логин портов': 'пароль авторизация пользователь',
  'Пароль портов': 'логин авторизация сменить сбросить',
  'Порт API статистики': 'порт счётчик трафик 10813',
  'IPv6': 'ipv6 айпи адрес',
  'Сниффинг': 'sniffing домен определение',
  'MTU TUN-адаптера': 'mtu пакет адаптер',
  'Уровень логов': 'журнал логи отладка debug info warning подробность',
  'Адрес для проверки': 'пинг задержка url ссылка тест',
  'User-Agent': 'ua юзер агент заголовок подписка',
  'Отправлять HWID': 'устройство идентификатор лимит',
  'HWID устройства': 'идентификатор устройство скопировать',
  'Папка данных': 'файлы логи журнал открыть',
  'Перенос настроек': 'экспорт импорт резервная копия бэкап backup сохранить перенести',
  'Версия SkipIt': 'обновление обновить update новая версия',
  'Канал обновлений': 'бета beta стабильный обновление',
  'Ядра': 'xray sing-box версия ядро',
};

/// Строки раздела [title], подходящие под поиск [query]: по названию строки, её подписи и ключевым
/// словам — должны найтись все слова запроса. Если под поиск подходит название раздела — весь раздел.
List<Widget> _found(String title, List<Widget> rows, String query) {
  if (query.isEmpty) return rows;
  final words = query.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  bool has(String text) => words.every(text.toLowerCase().contains);
  if (has(title)) return rows;
  return [
    for (final row in rows)
      if (switch (row) {
        _Row r => has('${r.title} ${r.subtitle} ${_keywords[r.title] ?? ''}'),
        _PortSecretRow r => has('${r.title} ${_keywords[r.title] ?? ''}'),
        _ => false,
      })
        row,
  ];
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // При поиске остаются только подходящие строки; раздел без них не показывается.
    final rows = _found(title, children, _SettingsQuery.of(context));
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
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
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const Divider(height: 1),
              rows[i],
            ],
          ]),
        ),
      ]),
    );
  }
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

/// Логин или пароль локальных портов: скрыт точками, пока его не попросят показать; копируется и
/// сменяется на новый случайный кнопками.
class _PortSecretRow extends StatefulWidget {
  const _PortSecretRow({required this.title, required this.what, required this.value, required this.onReset});
  final String title;

  /// «логин» или «пароль» — для подсказок кнопок и вопроса о смене.
  final String what;
  final String value;
  final VoidCallback onReset;

  @override
  State<_PortSecretRow> createState() => _PortSecretRowState();
}

class _PortSecretRowState extends State<_PortSecretRow> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) => _Row(
        title: widget.title,
        subtitle: _shown ? widget.value : '•' * 16,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            tooltip: '${_shown ? 'Скрыть' : 'Показать'} ${widget.what}',
            icon: Icon(_shown ? Icons.visibility_off_rounded : Icons.visibility_rounded),
            onPressed: () => setState(() => _shown = !_shown),
          ),
          IconButton(
            tooltip: 'Скопировать ${widget.what}',
            icon: const Icon(Icons.copy_rounded),
            onPressed: () => Clipboard.setData(ClipboardData(text: widget.value)),
          ),
          IconButton(
            tooltip: 'Новый ${widget.what}',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () async {
              final ok = await confirm(
                  context,
                  'Сменить ${widget.what} портов?',
                  'Старый ${widget.what} перестанет действовать. Программам, в которые он вписан, понадобится новый.',
                  ok: 'Сменить');
              if (ok) widget.onReset();
            },
          ),
        ]),
      );
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
  Widget build(BuildContext context) {
    // При поиске раздел раскрыт сам и показывает только подходящие строки.
    final query = _SettingsQuery.of(context);
    final rows = _found(widget.title, widget.children, query);
    if (rows.isEmpty) return const SizedBox.shrink();
    final open = _open || query.isNotEmpty;
    return _card(rows, open);
  }

  Widget _card(List<Widget> rows, bool open) => Padding(
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
                      turns: open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      child: Icon(Icons.expand_more_rounded, color: hovered ? C.orange : C.muted),
                    ),
                  ]),
                ),
              ),
            ),
            Reveal(
              open: open,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Column(children: [
                  for (final child in rows) ...[const Divider(height: 1), child],
                  const SizedBox(height: 4),
                ]),
              ),
            ),
          ]),
        ),
      );
}