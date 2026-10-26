import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/l10n/en.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/l10n/l10n.dart';
import 'package:skipit/state/app_state.dart';

import 'l10n/dart_strings.dart';

/// Русские строки, которые не переводятся: по ним программа узнаёт свои же сообщения или это служебные ключи.
const _notTranslated = {
  'ошибк', 'сбой', 'не удалось', 'предупреждение:', // уровень строки журнала (log_store.dart)
  '{0}|запасной', // ключ запомненного адреса подписки
};

/// Все русские строки программы (кроме шаблонов RegExp) — ключи перевода.
Map<String, String> _keysInLib() {
  final keys = <String, String>{};
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
    final path = f.path.replaceAll(r'\', '/');
    if (!path.endsWith('.dart') || path.startsWith('lib/l10n/')) continue;
    final src = f.readAsStringSync();
    for (final u in Scanner(src).scan()) {
      if (!u.hasCyrillic || isRegExpArg(src, u) || _notTranslated.contains(u.key)) continue;
      keys.putIfAbsent(u.key, () => path);
    }
  }
  return keys;
}

int _maxPlaceholder(String s) {
  var n = -1;
  for (final m in RegExp(r'\{(\d+)\}').allMatches(s)) {
    final v = int.parse(m.group(1)!);
    if (v > n) n = v;
  }
  return n;
}

void main() {
  test('у каждой русской строки есть английский перевод с теми же подстановками', () {
    final missing = <String>[];
    final wrongArgs = <String>[];
    for (final e in _keysInLib().entries) {
      final t = en[e.key];
      if (t == null) {
        missing.add('${e.value}: ${e.key}');
      } else if (_maxPlaceholder(t) != _maxPlaceholder(e.key)) {
        wrongArgs.add('${e.key} → $t');
      }
    }
    expect(missing, isEmpty, reason: 'нет перевода');
    expect(wrongArgs, isEmpty, reason: 'подстановки не совпадают');
  });

  test('в английских строках нет русских букв', () {
    final bad = [
      for (final e in en.entries)
        if (cyrillic.hasMatch(e.value) && e.value != 'Русский') '${e.key} → ${e.value}',
    ];
    expect(bad, isEmpty);
  });

  test('в словаре нет лишних строк', () {
    final keys = _keysInLib().keys.toSet();
    expect([for (final k in en.keys) if (!keys.contains(k)) k], isEmpty);
  });

  test('язык по Windows: русский для ru, uk, be, kk, иначе английский', () {
    for (final code in ['ru', 'uk', 'be', 'kk', 'RU']) {
      expect(langForLocale(code), Lang.ru, reason: code);
    }
    for (final code in ['en', 'de', 'fr', 'zh', 'tr', 'pl']) {
      expect(langForLocale(code), Lang.en, reason: code);
    }
  });

  test('при запуске язык из настроек включается до первых строк журнала', () async {
    await AppPaths.init();
    final tmp = await Directory.systemTemp.createTemp('skipit-test');
    addTearDown(() async {
      lang = Lang.ru;
      await tmp.delete(recursive: true);
    });
    AppPaths.dataDir = tmp;
    await File(AppPaths.stateFile).writeAsString('{"settings":{"language":"en"}}');
    final state = AppState();
    await state.loadForTest();
    expect(lang, Lang.en);
    // Строка журнала, которую программа пишет сразу после загрузки, — уже по-английски.
    state.log.add('app', tr('Служба SkipIt на месте: {0}', ['skipit-service 4']));
    expect(state.log.lines.last.text, 'SkipIt service is in place: skipit-service 4');
    expect(state.log.current?.title, 'No connection');
  });

  test('tr: подстановки и язык', () {
    lang = Lang.en;
    expect(tr('Ссылка скопирована'), en['Ссылка скопирована']);
    expect(tr('строка без перевода'), 'строка без перевода');
    lang = Lang.ru;
    expect(tr('Ядро завершилось (код {0})', [3]), 'Ядро завершилось (код 3)');
    expect(resolveLang('en'), Lang.en);
    expect(resolveLang('ru'), Lang.ru);
  });
}
