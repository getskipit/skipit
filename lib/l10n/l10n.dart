import 'dart:io';
import 'dart:ui' as ui;

import 'en.dart';

/// Язык интерфейса. Тексты в коде пишутся по-русски и проходят через [tr]; английские — в en.dart
/// (ключ — русская строка). Полноту перевода проверяет test/l10n_test.dart.
enum Lang { ru, en }

/// Текущий язык: меняется из настроек (Настройки → Внешний вид → «Язык»), после чего окно перестраивается.
Lang lang = Lang.ru;

/// Язык по настройке: 'ru', 'en' или 'auto' — по языку Windows: русский, украинский, белорусский
/// и казахский — русский интерфейс, остальные — английский. В тестах — всегда русский.
Lang resolveLang(String setting) => switch (setting) {
      'ru' => Lang.ru,
      'en' => Lang.en,
      _ => Platform.environment['FLUTTER_TEST'] == 'true' ? Lang.ru : _systemLang(),
    };

Lang _systemLang() {
  final code = ui.PlatformDispatcher.instance.locale.languageCode.toLowerCase();
  return const {'ru', 'uk', 'be', 'kk'}.contains(code) ? Lang.ru : Lang.en;
}

/// Перевод строки [ru] на текущий язык; {0}, {1}… заменяются на [args]. Нет перевода — русская строка.
/// Можно звать и для уже переведённой строки — она вернётся как есть.
String tr(String ru, [List<Object?> args = const []]) {
  var s = lang == Lang.en ? (en[ru] ?? ru) : ru;
  for (var i = 0; i < args.length; i++) {
    s = s.replaceAll('{$i}', '${args[i]}');
  }
  return s;
}
