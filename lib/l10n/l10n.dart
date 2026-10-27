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

Lang _systemLang() => langForLocale(ui.PlatformDispatcher.instance.locale.languageCode);

/// Язык интерфейса для языка Windows [code] (ru, en, de…).
Lang langForLocale(String code) => const {'ru', 'uk', 'be', 'kk'}.contains(code.toLowerCase()) ? Lang.ru : Lang.en;

/// Перевод строки [ru] на текущий язык; {0}, {1}… заменяются на [args]. Нет перевода — русская строка.
/// Можно звать и для уже переведённой строки — она вернётся как есть.
String tr(String ru, [List<Object?> args = const []]) {
  final s = lang == Lang.en ? (en[ru] ?? ru) : ru;
  if (args.isEmpty) return s;
  // За один проход: «{1}» внутри подставленного текста (имя сервера, адрес) остаётся как есть.
  return s.replaceAllMapped(_placeholder, (m) {
    final i = int.parse(m.group(1)!);
    return i < args.length ? '${args[i]}' : m.group(0)!;
  });
}

final _placeholder = RegExp(r'\{(\d+)\}');
