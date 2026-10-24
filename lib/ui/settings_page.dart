import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/paths.dart';
import '../core/updates.dart';
import '../core/util.dart';
import '../core/tray.dart';
import '../core/windows.dart';
import '../core/xray_config.dart';
import '../models/settings.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../version.dart';
import 'app_icon.dart';
import 'groups.dart';
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
  state.toast('Скачиваю обновление ${release.version}',
      kind: ToastKind.update, detail: 'Сколько скачано — в строке версии внизу слева');
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

  /// Открытая группа настроек; null — плитки всех групп.
  int? _group;

  /// Выбранная группа в виде «Списком».
  int _listGroup = 0;

  /// Счётчик повторных нажатий на раздел в меню ([AppState.pageReselected]), который страница уже видела.
  int? _seenReselect;
  final _searchKey = GlobalKey();

  /// Страница, показанная сейчас (ключ в AnimatedSwitcher ниже).
  Key? _shownKey;

  /// Прежняя страница и на сколько её сдвинуть вверх, пока она гаснет.
  final _outShift = ValueNotifier<(Key?, double)>((null, 0));

  /// Прокрутка к началу при смене страницы (плитки ↔ группа ↔ поиск): новая страница сразу стоит
  /// в начале, а прежняя, пока гаснет, сдвигается на прежнюю прокрутку — остаётся на месте, а не
  /// уезжает на глазах к своему началу.
  void _scrollToTop() {
    final scroll = PrimaryScrollController.maybeOf(context);
    if (scroll == null || !scroll.hasClients) return;
    _outShift.value = (_shownKey, scroll.offset);
    scroll.jumpTo(0);
  }

  /// Как в «Логах», где страницу двигает переключатель групп: при возврате плитки плавно поднимаются снизу
  /// на своё место, при открытии группы её страница плавно опускается сверху. Уходящая страница не сдвигается.
  /// Сдвиг идёт с первого кадра по кривой самого перехода — так же, как там движется переключатель: к моменту,
  /// когда страница проявляется, остаётся мягкий доезд. Сдвиг только во второй половине перехода проходил
  /// почти весь, пока страница ещё прозрачная, и в конце она заметно «подпрыгивала».
  static Widget _rise(bool tiles, Animation<double> anim, Widget child) => AnimatedBuilder(
        animation: anim,
        builder: (context, child) => anim.status == AnimationStatus.reverse
            ? child!
            : Transform.translate(offset: Offset(0, (tiles ? 54 : -54) * (1 - anim.value)), child: child),
        child: child,
      );

  @override
  void dispose() {
    _outShift.dispose();
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
            // Ключ — по названию: строки выше могут появиться или исчезнуть (поиск, фрагментация),
            // и без него поле взяло бы значение соседнего.
            child: TextFormField(
              key: ValueKey(title),
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
              key: ValueKey(title),
              initialValue: value,
              onChanged: (v) {
                set(v.trim());
                state.changed();
              },
            ),
          ),
        );

    // Поле фрагментации: значение сохраняется, только если его примет ядро (см. [XrayConfig.fragmentValueOk]).
    Widget fragmentField(String title, String subtitle, String value, void Function(String) set,
            {bool packets = false, bool zero = true}) =>
        _Row(
          title: title,
          subtitle: subtitle,
          trailing: SizedBox(
            width: 140,
            child: TextFormField(
              key: ValueKey(title),
              initialValue: value,
              textAlign: TextAlign.center,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: (v) =>
                  XrayConfig.fragmentValueOk(v!.trim(), packets: packets, zero: zero) ? null : 'Например, $value',
              onChanged: (v) {
                if (!XrayConfig.fragmentValueOk(v.trim(), packets: packets, zero: zero)) return;
                set(v.trim());
                state.changed();
              },
            ),
          ),
        );

    // Поле числа соединений mux: от −1 до 1024 (см. [XrayConfig.muxValue]).
    Widget muxField(String title, String subtitle, int value, void Function(int) set) => _Row(
          title: title,
          subtitle: subtitle,
          trailing: SizedBox(
            width: 110,
            child: TextFormField(
              key: ValueKey(title),
              initialValue: '$value',
              textAlign: TextAlign.center,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^-?\d{0,4}'))],
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: (v) => _muxOk(v!) ? null : 'От −1 до 1024',
              onChanged: (v) {
                if (!_muxOk(v)) return;
                set(int.parse(v));
                state.changed();
              },
            ),
          ),
        );

    final groups = <_Group>[
      _Group(
        Icons.bolt_rounded,
        'Подключение',
        'Kill Switch, блокировка рекламы, автовыбор сервера, режим TUN',
        'Kill Switch ${s.killSwitch ? 'включён' : 'выключен'} · TUN: ${s.tunCore == TunCore.xray ? 'Xray' : 'sing-box'}',
        [
        _Section('', [
          toggle('Подключаться при запуске', 'Автоматически включать VPN при автозапуске', s.connectOnStart,
              (v) => s.connectOnStart = v),
          toggle('Переподключаться при сбое', 'Перезапускать ядро, если оно упало', s.autoReconnect,
              (v) => s.autoReconnect = v),
          toggle('Автовыбор сервера', 'Перед подключением выбирать самый быстрый сервер подписки', s.autoSelect,
              (v) => s.autoSelect = v),
          toggle(
              'Kill Switch',
              'Если VPN оборвался, интернет закрывается, а не идёт напрямую — пока VPN не вернётся или вы сами '
                  'его не откроете. Действует в режимах TUN и «Смешанный»; локальная сеть остаётся доступной',
              s.killSwitch,
              (v) => state.setKillSwitch(v)),
          _Row(
            title: 'Блокировать рекламу и трекеры',
            subtitle: 'Не пускает к рекламным и следящим сайтам из готового списка гео-базы — во всех программах, '
                'которые идут через VPN. Рекламу внутри видео (YouTube) так не убрать: она приходит с того же адреса, '
                'что и само видео, — для неё нужно расширение браузера, например uBlock Origin',
            trailing: AppSwitch(value: s.adBlock, onChanged: (v) => state.setAdBlock(v)),
          ),
          _Row(
            title: 'Режим TUN',
            subtitle: switch (s.tunCore) {
              TunCore.xray => 'Xray: всё делает ядро Xray — перехватывает трафик компьютера и решает, что отправить '
                  'через VPN-сервер, а что напрямую, мимо него',
              TunCore.singbox => 'sing-box: трафик перехватывает ядро sing-box и передаёт его Xray, а тот решает, что '
                  'отправить через VPN-сервер, а что напрямую',
            },
            trailing: Segmented<TunCore>(
              value: s.tunCore,
              items: const {TunCore.xray: 'Xray', TunCore.singbox: 'sing-box'},
              onChanged: (v) {
                s.tunCore = v;
                state.changed();
              },
            ),
          ),
          _RevealRow(
            open: s.tunCore == TunCore.singbox,
            row: _Row(
              title: 'Сетевой стек sing-box',
              subtitle: switch (s.singboxStack) {
                'system' => 'System: соединения обрабатывает сама Windows — быстрее и легче для процессора',
                'gvisor' => 'gVisor: стек внутри самого sing-box — медленнее, но выручает, если с другими что-то не работает',
                _ => 'Mixed: TCP обрабатывает Windows, UDP — gVisor. Подходит большинству',
              },
              trailing: Segmented<String>(
                value: s.singboxStack,
                items: const {'system': 'System', 'gvisor': 'gVisor', 'mixed': 'Mixed'},
                onChanged: (v) {
                  s.singboxStack = v;
                  state.changed();
                },
              ),
            ),
          ),
        ]),
      ]),
      _Group(
        Icons.palette_rounded,
        'Внешний вид',
        'Тема, масштаб, где стоит меню, что показывать на главной, анимации',
        '${switch (s.theme) { AppTheme.dark => 'Тёмная', AppTheme.black => 'Чёрная', AppTheme.light => 'Светлая', AppTheme.system => 'Как в Windows' }} · '
            '${s.uiScale} % · меню ${s.navTop ? 'сверху' : 'слева'}',
        [
        _Section('', [
          _Row(
            title: 'Тема',
            subtitle: s.theme == AppTheme.black
                ? 'Чёрная: фон совсем чёрный — для экранов AMOLED и OLED'
                : '«Как в системе» следует за настройкой Windows',
            trailing: Segmented<AppTheme>(
              value: s.theme,
              items: const {
                AppTheme.dark: 'Тёмная',
                AppTheme.black: 'Чёрная',
                AppTheme.light: 'Светлая',
                AppTheme.system: 'Как в системе',
              },
              onChanged: (v) {
                s.theme = v;
                state.changed();
              },
            ),
          ),
          _Row(
            title: 'Цвет акцента',
            subtitle: 'Кнопки, переключатели, подсветка меню и знак SkipIt. Предупреждения остаются оранжевыми',
            trailing: _AccentPicker(
              value: Accent.values.asNameMap()[s.accent] ?? Accent.orange,
              onChanged: (v) {
                s.accent = v.name;
                state.changed();
              },
            ),
          ),
          _Row(
            title: 'Значок',
            subtitle: 'Значок окна и трея. На панели задач, рабочем столе и в «Пуске» Windows показывает прежний',
            trailing: _IconPicker(
              value: IconStyle.values.asNameMap()[s.iconStyle] ?? IconStyle.classic,
              onChanged: (v) {
                s.iconStyle = v.name;
                state.changed();
              },
            ),
          ),
          _Row(
            title: 'Скругление углов',
            subtitle: 'Углы карточек, кнопок и полей',
            trailing: Segmented<double>(
              value: s.corners,
              items: Palette.cornerSteps,
              onChanged: (v) {
                s.corners = v;
                state.changed();
              },
            ),
          ),
          _Row(
            title: 'Масштаб',
            subtitle: 'Размер всего окна: текста, значков и отступов. Меньше — больше помещается на экране',
            trailing: Segmented<int>(
              value: s.uiScale,
              items: {for (final p in AppSettings.uiScales) p: '$p %'},
              onChanged: (v) {
                s.uiScale = v;
                state.changed();
              },
            ),
          ),
          _Row(
            title: 'Расположение меню',
            subtitle: 'Где стоят разделы программы: слева или вдоль верхнего края окна',
            trailing: Segmented<bool>(
              value: s.navTop,
              items: const {false: 'Слева', true: 'Сверху'},
              onChanged: (v) {
                s.navTop = v;
                state.changed();
              },
            ),
          ),
          _Row(
            title: 'Вид настроек',
            subtitle: s.settingsList
                ? 'Списком: слева группы, справа настройки выбранной'
                : 'Плитки: сначала группы, у каждой своя страница',
            trailing: Segmented<bool>(
              value: s.settingsList,
              items: const {false: 'Плитки', true: 'Списком'},
              // Смена вида оставляет открытой ту же группу: в ней только что и меняли вид.
              onChanged: (v) {
                if (v) {
                  if (_group != null) _listGroup = _group!;
                } else {
                  _group = _listGroup;
                }
                s.settingsList = v;
                state.changed();
              },
            ),
          ),
          _Row(
            title: 'Вид логов',
            subtitle: s.logsList
                ? 'Списком: слева группы, справа журнал выбранной'
                : 'Плитки: сначала группы, у каждой своя страница',
            trailing: Segmented<bool>(
              value: s.logsList,
              items: const {false: 'Плитки', true: 'Списком'},
              onChanged: (v) {
                s.logsList = v;
                state.changed();
              },
            ),
          ),
          _Row(
            title: 'На главной',
            subtitle: 'Что показывать под кнопкой подключения. Ошибки и подсказки видны всегда',
            trailing: const SizedBox.shrink(),
            below: _PartChips(
              items: AppSettings.homeParts,
              selected: {for (final p in AppSettings.homeParts.keys) if (s.homeShows(p)) p},
              onToggle: (p) {
                s.homeHidden.contains(p) ? s.homeHidden.remove(p) : s.homeHidden.add(p);
                state.changed();
              },
            ),
          ),
          _Row(
            title: 'Карточка подписки',
            subtitle: s.subDetailed
                ? 'Подробная: крупные цифры трафика и срока, кнопки кабинета и поддержки, объявление целиком'
                : 'Компактная: трафик и срок одной строкой',
            trailing: Segmented<bool>(
              value: s.subDetailed,
              items: const {false: 'Компактная', true: 'Подробная'},
              onChanged: (v) {
                s.subDetailed = v;
                state.changed();
              },
            ),
          ),
          _Row(
            title: 'Пункты меню',
            subtitle: 'Какие разделы видны в меню. Главная и Настройки — всегда',
            trailing: const SizedBox.shrink(),
            below: _PartChips(
              items: AppSettings.menuPages,
              selected: {for (final p in AppSettings.menuPages.keys) if (!s.menuHidden.contains(p)) p},
              onToggle: (p) {
                s.menuHidden.contains(p) ? s.menuHidden.remove(p) : s.menuHidden.add(p);
                state.changed();
              },
            ),
          ),
          toggle('Меньше анимаций', 'Списки, меню и переходы срабатывают сразу, без плавного движения. Для слабых компьютеров',
              s.reduceMotion, (v) => s.reduceMotion = v),
        ]),
      ]),
      _Group(
        Icons.cloud_sync_rounded,
        'Подписки и серверы',
        'Когда обновлять подписки, как проверять задержку серверов',
        'Проверка: ${s.pingType == PingType.realDelay ? 'реальная' : 'TCP'}',
        [
        _Section('Подписки', [
          toggle('Обновлять при запуске', 'Загружать свежий список серверов при старте', s.updateSubsOnStart,
              (v) => s.updateSubsOnStart = v),
          toggle('Обновлять через VPN', 'Если подключено — качать подписку через туннель', s.updateViaProxy,
              (v) => s.updateViaProxy = v),
        ]),
        _Section('Проверка задержки', [
          _Row(
            title: 'Тип проверки',
            subtitle: switch (s.pingType) {
              PingType.realDelay => 'Реальная: через каждый сервер открывается адрес проверки — видно, работает ли '
                  'сервер на самом деле и сколько ждать ответа. Точнее, но дольше',
              PingType.tcp => 'TCP: только стучится в порт сервера напрямую — быстро, но сервер может отвечать '
                  'и при этом не пропускать трафик',
            },
            trailing: Segmented<PingType>(
              value: s.pingType,
              items: const {PingType.realDelay: 'Реальная', PingType.tcp: 'TCP'},
              onChanged: (v) {
                s.pingType = v;
                state.changed();
              },
            ),
          ),
          _Row(
            title: 'Адрес для проверки',
            subtitle: 'Его открывает «Реальная» проверка через каждый сервер. Подойдёт любой адрес, который быстро '
                'отвечает коротким ответом',
            trailing: AppDropdown<String>(
              value: s.testUrlOwn ? '' : s.testUrl,
              items: {...AppSettings.testUrls, '': 'Свой адрес'},
              onChanged: (v) {
                s.testUrlOwn = v.isEmpty;
                if (v.isNotEmpty) s.testUrl = v;
                state.changed();
              },
            ),
          ),
          _RevealRow(
            open: s.testUrlOwn,
            row: _Row(
              title: 'Свой адрес проверки',
              subtitle: 'Начинается с http:// или https://',
              trailing: SizedBox(
                width: 340,
                child: TextFormField(
                  // Новый ключ при каждом открытии: поле берёт текущий адрес, а не прежний.
                  key: ValueKey('Свой адрес проверки ${s.testUrlOwn}'),
                  initialValue: s.testUrl,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (v) => _testUrlOk(v!.trim()) ? null : 'Нужен адрес вида https://example.com/…',
                  onChanged: (v) {
                    if (!_testUrlOk(v.trim())) return;
                    s.testUrl = v.trim();
                    state.changed();
                  },
                ),
              ),
            ),
          ),
        ]),
      ]),
      _Group(
        Icons.desktop_windows_rounded,
        'Программа',
        'Автозапуск, трей, уведомления, перенос настроек, «Починить сеть» и сброс',
        'Автозапуск ${state.autostart ? 'включён' : 'выключен'}',
        [
        _Section('', [
          toggle('Запускать вместе с Windows', 'Запускать приложение при входе в Windows', state.autostart,
              (v) => state.setAutostart(v)),
          toggle('Сворачивать в трей при закрытии', 'Крестик прячет окно в трей, VPN продолжает работать. Выход — через меню значка в трее',
              s.closeToTray, (v) => s.closeToTray = v),
          toggle('Уведомления Windows', 'Пока окно спрятано, сообщать: VPN оборвался, переподключился, связи через сервер нет. '
                  'И напоминать, что программа осталась в трее',
              s.notifications, (v) => s.notifications = v),
        ]),
        _Section('Данные', [
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
        ]),
        _Section('Сброс', [
          _Row(
            title: 'Сбросить настройки',
            subtitle: 'Все настройки вернутся к стандартным. Подписки, серверы, профили маршрутизации, правила '
                'программ, HWID и пароль портов останутся',
            trailing: GhostButton(
              label: 'Сбросить',
              icon: Icons.restart_alt_rounded,
              onPressed: () async {
                final ok = await confirm(context, 'Сбросить настройки?',
                    'Все настройки вернутся к стандартным. Подписки, серверы, профили и правила программ останутся.',
                    ok: 'Сбросить');
                if (!ok) return;
                final error = await state.resetSettings();
                state.toast(error ?? 'Настройки сброшены', kind: error == null ? ToastKind.success : ToastKind.error);
              },
            ),
          ),
          _Row(
            title: 'Починить сеть',
            subtitle: 'Если интернет пропал или VPN «застрял»: отключает VPN, закрывает зависшие ядра, возвращает '
                'прокси Windows, убирает адаптеры SkipIt и фильтры Kill Switch, очищает кэш DNS',
            trailing: GhostButton(
              label: 'Починить',
              icon: Icons.build_rounded,
              busy: state.repairing,
              onPressed: state.isBusy
                  ? null
                  : () async {
                      final ok = await confirm(context, 'Починить сеть?', 'VPN отключится, если он подключён.',
                          ok: 'Починить');
                      if (!ok) return;
                      await state.repairNetwork();
                      state.toast('Готово: сеть приведена в порядок', kind: ToastKind.success);
                    },
            ),
          ),
          _Row(
            title: 'Удалить все данные',
            subtitle: 'Удаляет подписки, серверы, профили, правила и настройки — как после новой установки. HWID '
                'останется, поэтому провайдер не посчитает компьютер новым устройством',
            trailing: GhostButton(
              label: 'Удалить',
              icon: Icons.delete_forever_rounded,
              onPressed: () async {
                final ok = await confirm(context, 'Удалить все данные?',
                    'Подписки, серверы, профили, правила программ и настройки будут удалены без возможности '
                        'вернуть. Чтобы сохранить их, сначала нажмите «Экспорт» выше, в разделе «Данные».');
                if (!ok) return;
                final error = await state.deleteAllData();
                state.toast(error ?? 'Все данные удалены', kind: error == null ? ToastKind.success : ToastKind.error);
              },
            ),
          ),
        ]),
      ]),
      _Group(
        Icons.construction_rounded,
        'Для опытных',
        'User-Agent и HWID, IPv6, MTU, фрагментация, шумы, Mux, локальные порты, уровень логов',
        banner: Reveal(
          open: !s.advancedHintSeen,
          child: Padding(
            // Те же поля, что у разделов (_Section): плашка ровно по ширине карточек.
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 18),
            child: Panel(
              child: Row(children: [
                Icon(Icons.info_rounded, color: C.orange),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Эти настройки нужны редко. Неверное значение может сломать подключение. Если что-то '
                    'перестало работать — «Настройки → Программа → Сбросить настройки»',
                    style: TextStyle(color: C.text, height: 1.4),
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: () {
                    s.advancedHintSeen = true;
                    state.changed();
                  },
                  child: const Text('Понятно'),
                ),
              ]),
            ),
          ),
        ),
        [s.fragment ? 'фрагментация' : '', s.noise ? 'шумы' : '', s.mux ? 'Mux' : ''].any((e) => e.isNotEmpty)
            ? 'Включено: ${[s.fragment ? 'фрагментация' : '', s.noise ? 'шумы' : '', s.mux ? 'Mux' : ''].where((e) => e.isNotEmpty).join(', ')}'
            : 'Обычно менять не нужно',
        [
        _Section('Подписки', [
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
        _Section('Сеть', [
          toggle('IPv6', 'Включить IPv6 в туннеле и DNS', s.ipv6, (v) => s.ipv6 = v),
          number('MTU TUN-адаптера', 'Обычно 1500 или 9000', s.mtu, (v) => s.mtu = v),
          toggle('Сниффинг', 'Определять домен по TLS/HTTP/QUIC — нужен для маршрутизации по сайтам', s.sniffing,
              (v) => s.sniffing = v),
          text(
              'Исключения системного прокси',
              'Адреса через «;», которые идут мимо прокси в режимах «Смешанный» и «Прокси». '
                  'Пустое поле — стандартный список',
              s.proxyBypass.isEmpty ? WinSys.defaultProxyBypass : s.proxyBypass,
              // Стандартный список не сохраняем: если он изменится в новой версии, человек получит новый.
              (v) => s.proxyBypass = v == WinSys.defaultProxyBypass ? '' : v),
          toggle('Разрешить подключения из локальной сети', 'Раздавать прокси другим устройствам (0.0.0.0)', s.allowLan,
              (v) => s.allowLan = v),
        ]),
        _Section('Соединение с сервером', [
          toggle(
              'Фрагментация',
              'Отправлять начало соединения с сервером частями — помогает, если интернет-провайдер не пускает '
                  'к серверу. Только серверы из ссылок с TLS или Reality, не конфиги провайдера в JSON',
              s.fragment,
              (v) => s.fragment = v),
          if (s.fragment) ...[
            fragmentField('Фрагментация: пакеты', 'tlshello — приветствие TLS; 1-3 — первые пакеты соединения',
                s.fragmentPackets, (v) => s.fragmentPackets = v, packets: true),
            fragmentField('Фрагментация: длина части', 'Байт, число или диапазон: 100-200', s.fragmentLength,
                (v) => s.fragmentLength = v, zero: false),
            fragmentField('Фрагментация: пауза', 'Миллисекунд между частями: 10-20', s.fragmentInterval,
                (v) => s.fragmentInterval = v),
          ],
          toggle(
              'Шумы (Noises)',
              'Перед соединением с сервером отправлять лишний UDP-пакет — мешает распознать и заблокировать '
                  'QUIC. Только серверы Hysteria и mKCP из ссылок, не конфиги провайдера в JSON',
              s.noise,
              (v) => s.noise = v),
          if (s.noise) ...[
            _Row(
              title: 'Шумы: вид пакета',
              subtitle: 'Случайный подходит почти всегда. Текст, Hex и Base64 — заданный пакет, если провайдер '
                  'или инструкция назвали конкретное значение',
              trailing: Segmented<String>(
                value: s.noiseType,
                items: const {'rand': 'Случайный', 'str': 'Текст', 'hex': 'Hex', 'base64': 'Base64'},
                onChanged: (v) {
                  s.noiseType = v;
                  state.changed();
                },
              ),
            ),
            if (s.noiseType == 'rand')
              fragmentField('Шумы: длина пакета', 'Байт, число или диапазон: 10-20', s.noisePacket,
                  (v) => s.noisePacket = v, zero: false)
            else
              _Row(
                title: 'Шумы: пакет',
                subtitle: switch (s.noiseType) {
                  'hex' => 'Байты в шестнадцатеричном виде, например 0a1b2c. Неверное значение — шумов нет',
                  'base64' => 'Байты в Base64. Неверное значение — шумов нет',
                  _ => 'Текст пакета как есть. Пустое поле — шумов нет',
                },
                trailing: SizedBox(
                  width: 260,
                  child: TextFormField(
                    // Свой ключ у каждого вида: поле показывает сохранённый пакет и проверяет его заново.
                    key: ValueKey('noiseData/${s.noiseType}'),
                    initialValue: s.noiseData,
                    autovalidateMode: AutovalidateMode.always,
                    validator: (v) => XrayConfig.noiseDataOk(s.noiseType, v!) ? null : 'Ядро не примет такой пакет',
                    onChanged: (v) {
                      s.noiseData = v;
                      state.changed();
                    },
                  ),
                ),
              ),
            fragmentField('Шумы: пауза', 'Миллисекунд после пакета: 10-16', s.noiseDelay, (v) => s.noiseDelay = v),
          ],
          toggle(
              'Мультиплексирование (Mux)',
              'Несколько соединений программ идут по одному соединению с сервером: новые открываются быстрее, '
                  'но при потерях тормозят все сразу. Нужен сервер на Xray. Не действует на серверы с Vision, '
                  'XHTTP и конфиги провайдера в JSON',
              s.mux,
              (v) => s.mux = v),
          if (s.mux) ...[
            muxField('Mux: TCP-соединения', 'Сколько соединений программ идёт по одному соединению с сервером, '
                'от −1 до 1024. −1 — TCP мимо mux. Обычно 8', s.muxConcurrency, (v) => s.muxConcurrency = v),
            muxField('Mux: XUDP-соединения', 'То же для UDP (игры, звонки), от −1 до 1024. −1 — UDP мимо mux, '
                '0 — вместе с TCP. Обычно 16', s.muxXudp, (v) => s.muxXudp = v),
          ],
        ]),
        _Section('Локальные порты', [
          number('SOCKS-порт', 'Локальный SOCKS5-прокси', s.socksPort, (v) => s.socksPort = v),
          number('HTTP-порт', 'Используется системным прокси', s.httpPort, (v) => s.httpPort = v),
          toggle(
              'Пароль на локальные порты',
              'Другие программы смогут ходить через SOCKS-порт только с логином и паролем. HTTP-порт закрыт '
                  'паролем в режиме «Только порты»; в остальных режимах он открыт: им пользуются Windows и '
                  'программы, запомнившие системный прокси',
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
        ]),
        _Section('Журнал', [
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
        ]),
      ]),
      _Group(
        Icons.info_rounded,
        'О программе',
        'Версия, обновления и их канал, версии ядер',
        state.appUpdate != null ? 'Доступна версия ${state.appUpdate!.version}' : 'Версия $appVersion',
        alert: SettingsPage._coresMissing(state) ? C.red : (state.appUpdate != null ? C.orange : null),
        [
        _Section('', [
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
      ]),
    ];

    // Ушли в другой раздел меню — поиск сбрасывается, открытая группа закрывается: вернувшись, человек
    // видит плитки всех групп.
    // То же, когда «Настройки» нажали в меню ещё раз, уже находясь в них.
    final reselected = _seenReselect != null && _seenReselect != state.pageReselected;
    _seenReselect = state.pageReselected;
    if ((state.pageIndex != AppState.settingsPage || reselected) && (_query.isNotEmpty || _group != null)) {
      _search.clear();
      _query = '';
      _group = null;
      if (reselected) _scrollToTop();
    }
    final query = _query.trim().toLowerCase();
    // Ключ держит одно и то же поле поиска при смене заголовка (плитки ↔ группа ↔ поиск): иначе поле
    // создавалось бы заново после первой же буквы и теряло фокус.
    final search = SizedBox(
      key: _searchKey,
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
    );
    const hint = 'Изменения портов и ядра применяются при следующем подключении';

    void openGroup(int? i) {
      setState(() => _group = i);
      _scrollToTop();
    }

    Widget headerFor(_Group? g) => GroupHeader(
        page: 'Настройки',
        backTooltip: 'Все настройки',
        group: g,
        hint: hint,
        trailing: search,
        onBack: () => openGroup(null));
    final Widget header;
    final List<Widget> body;
    // Вид «Списком»: слева группы, справа настройки выбранной (поиск и в нём ищет по всем группам).
    final listMode = s.settingsList && query.isEmpty;
    final listGroup = _listGroup.clamp(0, groups.length - 1);
    if (query.isNotEmpty) {
      // Поиск — по всем группам сразу; у раздела без своего названия подписью служит название группы.
      final sections = [
        for (final g in groups)
          for (final sec in g.sections) _Section(sec.title.isEmpty ? g.title : '${g.title} · ${sec.title}', sec.children),
      ];
      final found = sections.any((s) => _found(s.title, s.children, query).isNotEmpty);
      header = headerFor(null);
      body = [
        ...sections,
        if (!found)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text('Ничего не найдено. Попробуйте другое слово — например, «порт» или «трей».',
                style: TextStyle(color: C.muted, fontSize: 13)),
          ),
      ];
    } else if (listMode) {
      header = headerFor(null);
      body = [if (groups[listGroup].banner != null) groups[listGroup].banner!, ...groups[listGroup].sections];
    } else if (_group != null) {
      final g = groups[_group!];
      header = headerFor(g);
      body = [if (g.banner != null) g.banner!, ...g.sections];
    } else {
      header = headerFor(null);
      body = [GroupGrid(groups: groups, onOpen: openGroup)];
    }
    return _SettingsQuery(
      query: query,
      // Заголовок со стрелкой назад и поиском закреплён: прокручиваются только настройки под ним.
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        Expanded(
          child: GroupListLayout(
            groups: listMode ? groups : null,
            selected: listGroup,
            onSelect: (i) {
              setState(() => _listGroup = i);
              _scrollToTop();
            },
            child: ListView(primary: true, padding: const EdgeInsets.only(top: 2, bottom: 28), children: [
        // Плитки, страница группы и результаты поиска сменяют друг друга плавно: старое гаснет,
        // новое проявляется и чуть подъезжает (страница группы — справа, плитки — слева).
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (current, previous) =>
              Stack(alignment: Alignment.topCenter, children: [...previous, if (current != null) current]),
          // Без наложения: старая страница гаснет за первую половину, новая проявляется во второй.
          transitionBuilder: (child, anim) => _rise(child.key == const ValueKey('grid'), anim, FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: const Interval(0.5, 1)),
            child: SlideTransition(
              position: Tween(
                begin: Offset(child.key == const ValueKey('grid') ? -0.03 : 0.03, 0),
                end: Offset.zero,
              ).animate(anim),
              child: ValueListenableBuilder<(Key?, double)>(
                valueListenable: _outShift,
                builder: (context, shift, child) => shift.$1 == child!.key && shift.$1 != _shownKey && shift.$2 != 0
                    ? Transform.translate(offset: Offset(0, -shift.$2), child: child)
                    : child,
                child: child,
              ),
            ),
          )),
          child: KeyedSubtree(
            key: _shownKey = ValueKey(query.isNotEmpty
                ? 'search'
                : listMode
                    ? 'list$listGroup'
                    : (_group == null ? 'grid' : 'group$_group')),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body),
          ),
        ),
          ]),
          ),
        ),
      ]),
    );
  }
}

/// Группа настроек: плитка на первой странице «Настроек» и своя страница с разделами.
class _Group extends PageGroup {
  const _Group(super.icon, super.title, super.description, super.summary, this.sections, {super.alert, this.banner});
  final List<_Section> sections;

  /// Плашка над настройками группы (в поиске не показывается).
  final Widget? banner;
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
  'Тема': 'оформление цвет тёмная темная светлая чёрная черная amoled oled ночная dark light black вид',
  'Масштаб': 'размер крупнее мельче меньше уменьшить увеличить шрифт текст zoom интерфейс',
  'Цвет акцента': 'цвет акцент оранжевый синий фиолетовый розовый зелёный зеленый оформление кастомизация',
  'Значок': 'значок иконка icon трей панель задач логотип вид кастомизация',
  'Скругление углов': 'углы радиус скругление острые круглые оформление кастомизация',
  'Расположение меню': 'вёрстка верстка меню сверху слева сбоку панель навигация разделы',
  'Вид настроек': 'настройки плитки список списком одной страницей вёрстка верстка группы',
  'Вид логов': 'логи журнал журналы плитки список списком вёрстка верстка группы',
  'На главной': 'главная экран скрыть спрятать показать скорость трафик режим маршрутизация таймер время страна',
  'Карточка подписки': 'подписка трафик срок карточка подробная компактная минимализм кастомизация',
  'Пункты меню': 'меню разделы скрыть спрятать убрать серверы маршрутизация проверка логи кастомизация',
  'Меньше анимаций': 'анимация плавность тормозит лагает производительность слабый компьютер',
  'Запускать вместе с Windows': 'автозапуск автозагрузка старт включение компьютера',
  'Сворачивать в трей при закрытии': 'трей значок крестик закрыть фон свернуть',
  'Уведомления Windows': 'оповещения сообщения всплывающие',
  'Подключаться при запуске': 'автоподключение автозапуск старт',
  'Переподключаться при сбое': 'обрыв падение автоматически восстановить',
  'Режим TUN': 'ядро xray sing-box singbox адаптер',
  'Сетевой стек sing-box': 'stack стек gvisor system mixed системный смешанный адаптер',
  'Kill Switch': 'килл свитч защита утечка обрыв блокировка интернета',
  'Блокировать рекламу и трекеры': 'реклама баннеры трекеры слежка счётчики счетчики adblock ads блокировщик',
  'Автовыбор сервера': 'лучший быстрый пинг авто',
  'Разрешить подключения из локальной сети': 'lan wifi роутер телефон раздать другим устройствам',
  'Тип проверки': 'пинг задержка ping tcp скорость реальная real delay',
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
  'Фрагментация': 'fragment фрагмент блокировка обход dpi tls',
  'Шумы (Noises)': 'noise шум блокировка обход dpi quic hysteria udp',
  'Шумы: вид пакета': 'noise шум rand str string hex base64 тип',
  'Шумы: пакет': 'noise шум str string hex base64 содержимое',
  'Мультиплексирование (Mux)': 'mux мультиплексор xudp соединения',
  'Mux: TCP-соединения': 'mux мультиплексор потоки concurrency',
  'Mux: XUDP-соединения': 'mux мультиплексор udp потоки игры',
  'Уровень логов': 'журнал логи отладка debug info warning подробность',
  'Адрес для проверки': 'пинг задержка url ссылка тест google cloudflare apple firefox gstatic',
  'Свой адрес проверки': 'пинг задержка url ссылка тест свой',
  'Исключения системного прокси': 'proxy bypass обход мимо исключить localhost локальные адреса',
  'User-Agent': 'ua юзер агент заголовок подписка',
  'Отправлять HWID': 'устройство идентификатор лимит',
  'HWID устройства': 'идентификатор устройство скопировать',
  'Папка данных': 'файлы логи журнал открыть',
  'Перенос настроек': 'экспорт импорт резервная копия бэкап backup сохранить перенести',
  'Версия SkipIt': 'обновление обновить update новая версия',
  'Канал обновлений': 'бета beta стабильный обновление',
  'Ядра': 'xray sing-box версия ядро',
  'Сбросить настройки': 'сброс по умолчанию стандартные заводские восстановить',
  'Починить сеть': 'сброс интернет пропал не работает завис зависло адаптер tun прокси dns восстановить',
  'Удалить все данные': 'сброс очистить стереть всё подписки серверы',
};

bool _testUrlOk(String v) {
  final u = Uri.tryParse(v);
  return u != null && (u.scheme == 'http' || u.scheme == 'https') && u.host.isNotEmpty;
}

bool _muxOk(String v) {
  final n = int.tryParse(v.trim());
  return n != null && n >= -1 && n <= 1024;
}

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
        _RevealRow r => r.open && has('${r.row.title} ${r.row.subtitle} ${_keywords[r.row.title] ?? ''}'),
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
        // Раздел без названия — единственный или первый в своей группе: заголовок ему не нужен.
        if (title.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(title.toUpperCase(),
              style: TextStyle(color: C.orange, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.6)),
        ),
        Panel(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
          child: Column(children: [
            for (var i = 0; i < rows.length; i++)
              if (rows[i] case final _RevealRow r)
                _RevealRow(open: r.open, row: r.row, divider: i > 0)
              else ...[
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

/// Строка, которая плавно появляется и сворачивается вместе со своей чертой-разделителем (её ставит
/// раздел), а не выскакивает рывком.
/// Выбор вида значка: сами значки, выбранный — в рамке цвета акцента.
class _IconPicker extends StatelessWidget {
  const _IconPicker({required this.value, required this.onChanged});
  final IconStyle value;
  final ValueChanged<IconStyle> onChanged;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (final style in IconStyle.values)
          Tooltip(
            message: style.label,
            waitDuration: const Duration(milliseconds: 400),
            child: Hover(
              builder: (context, hovered) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(style),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(C.r(12)),
                    border: Border.all(
                      color: style == value ? C.orange : (hovered ? C.border : Colors.transparent),
                      width: 2,
                    ),
                  ),
                  child: style == IconStyle.classic
                      ? Image.asset('assets/icon.png', width: 30, height: 30, filterQuality: FilterQuality.medium)
                      : CustomPaint(size: const Size.square(30), painter: SkipItIconPainter(style, C.palette.accent)),
                ),
              ),
            ),
          ),
      ]);
}

/// Выбор цвета акцента: кружки цветов, выбранный — с галочкой.
class _AccentPicker extends StatelessWidget {
  const _AccentPicker({required this.value, required this.onChanged});
  final Accent value;
  final ValueChanged<Accent> onChanged;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (final a in Accent.values)
          Tooltip(
            message: a.label,
            waitDuration: const Duration(milliseconds: 400),
            child: Hover(
              builder: (context, hovered) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(a),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                          colors: [a.light, a.main], begin: Alignment.topLeft, end: Alignment.bottomRight),
                      border: Border.all(
                        color: a == value ? C.text : (hovered ? C.muted : Colors.transparent),
                        width: 2,
                      ),
                    ),
                    child: a == value ? const Icon(Icons.check_rounded, size: 16, color: Colors.white) : null,
                  ),
                ),
              ),
            ),
          ),
      ]);
}

class _RevealRow extends StatelessWidget {
  const _RevealRow({required this.open, required this.row, this.divider = false});
  final bool open;
  final _Row row;
  final bool divider;

  @override
  Widget build(BuildContext context) =>
      Reveal(open: open, child: Column(children: [if (divider) const Divider(height: 1), row]));
}

class _Row extends StatelessWidget {
  const _Row({required this.title, required this.subtitle, required this.trailing, this.subtitleColor, this.below});
  final String title;
  final String subtitle;
  final Widget trailing;

  /// Широкий элемент под подписью (например, набор выключателей), а не справа от неё.
  final Widget? below;

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
              if (below != null) ...[const SizedBox(height: 10), below!],
            ]),
          ),
          const SizedBox(width: 16),
          trailing,
        ]),
      );
}

/// Набор выключателей-«таблеток»: каждый пункт включается и выключается отдельно.
class _PartChips extends StatelessWidget {
  const _PartChips({required this.items, required this.selected, required this.onToggle});
  final Map<String, String> items;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 6, runSpacing: 6, children: [
        for (final MapEntry(:key, :value) in items.entries)
          () {
            final on = selected.contains(key);
            // Свой Hover, как у остальных кнопок: курсор-палец и подсветка при наведении.
            return Hover(
              builder: (context, hovered) => GestureDetector(
                onTap: () => onToggle(key),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.fromLTRB(8, 6, 10, 6),
                  decoration: BoxDecoration(
                    color: on
                        ? C.orange.withValues(alpha: hovered ? 0.22 : 0.14)
                        : (hovered ? Color.alphaBlend(C.hover, C.surface2) : C.surface2),
                    borderRadius: BorderRadius.circular(C.r(10)),
                    border: Border.all(
                        color: on || hovered ? C.orange.withValues(alpha: hovered ? 0.8 : 0.6) : C.border),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(on ? Icons.check_rounded : Icons.add_rounded,
                        size: 16, color: on || hovered ? C.orange : C.muted),
                    const SizedBox(width: 4),
                    Text(value, style: TextStyle(fontSize: 13, color: on || hovered ? C.text : C.muted)),
                  ]),
                ),
              ),
            );
          }(),
      ]);
}

