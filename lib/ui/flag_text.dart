import 'package:flutter/material.dart';

import 'theme.dart';
import '../l10n/l10n.dart';

/// Windows не умеет рисовать эмодзи-флаги (🇩🇪 превращается в «DE»),
/// поэтому пары «региональных» символов заменяются картинками из assets/flags.
class Flags {
  static const _base = 0x1F1E6; // 🇦
  static const _last = 0x1F1FF; // 🇿

  static bool _isRegional(int rune) => rune >= _base && rune <= _last;

  /// Делит текст на куски: обычный текст и коды стран (`de`, `ru`) на месте флагов.
  static List<({String? text, String? country})> split(String input) {
    final parts = <({String? text, String? country})>[];
    final runes = input.runes.toList();
    final buf = StringBuffer();
    for (var i = 0; i < runes.length; i++) {
      if (i + 1 < runes.length && _isRegional(runes[i]) && _isRegional(runes[i + 1])) {
        if (buf.isNotEmpty) {
          parts.add((text: buf.toString(), country: null));
          buf.clear();
        }
        final cc = String.fromCharCodes([runes[i] - _base + 0x61, runes[i + 1] - _base + 0x61]);
        parts.add((text: null, country: cc));
        i++;
      } else {
        buf.writeCharCode(runes[i]);
      }
    }
    if (buf.isNotEmpty) parts.add((text: buf.toString(), country: null));
    return parts;
  }

  /// Флаг в начале названия отдельно: «🇩🇪 Germany» → (de, Germany).
  static (String?, String) leading(String name) {
    final parts = split(name.trimLeft());
    if (parts.isEmpty || parts.first.country == null) return (null, name);
    final rest = parts.skip(1).map((p) => p.text ?? String.fromCharCodes([
          p.country!.codeUnitAt(0) - 0x61 + _base,
          p.country!.codeUnitAt(1) - 0x61 + _base,
        ])).join().trim();
    return (parts.first.country, rest.isEmpty ? name : rest);
  }

  /// Для мест, где картинку показать нельзя (подсказка трея рисуется Windows): флаги просто убираются.
  static String toPlain(String input) =>
      split(input).map((p) => p.text ?? '').join().replaceAll(RegExp(r'\s{2,}'), ' ').trim();

  /// Эмодзи и их служебные символы (соединитель, выбор начертания, оттенки кожи, «клавиши»).
  static final _emoji = RegExp(
    '[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{2300}-\u{23FF}\u{FE00}-\u{FE0F}\u{E0020}-\u{E007F}‍⃣]',
    unicode: true,
  );

  /// Для меню значка в трее: оно рисуется средствами Windows без цветного шрифта эмодзи, и на месте
  /// каждого эмодзи получался пустой квадратик. Флаги и эмодзи убираются, текст остаётся:
  /// «Auto → [🚀 Оптимальная]» → «Auto → [Оптимальная]».
  static String forTray(String input) {
    final plain = toPlain(input);
    final text = plain
        .replaceAll(_emoji, '')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .replaceAllMapped(RegExp(r'([\[(«])\s+'), (m) => m.group(1)!)
        .replaceAllMapped(RegExp(r'\s+([\])»])'), (m) => m.group(1)!)
        .trim();
    // Название из одних эмодзи остаётся как есть: квадратик лучше пустой строки.
    return text.isEmpty ? plain : text;
  }

  /// Названия стран, где обычно стоят VPN-серверы. Для остальных показывается код страны.
  static Map<String, String> get _countries => {
    'ae': tr('ОАЭ'), 'al': tr('Албания'), 'am': tr('Армения'), 'ar': tr('Аргентина'), 'at': tr('Австрия'), 'au': tr('Австралия'),
    'az': tr('Азербайджан'), 'be': tr('Бельгия'), 'bg': tr('Болгария'), 'br': tr('Бразилия'), 'by': tr('Беларусь'), 'ca': tr('Канада'),
    'ch': tr('Швейцария'), 'cl': tr('Чили'), 'cn': tr('Китай'), 'cy': tr('Кипр'), 'cz': tr('Чехия'), 'de': tr('Германия'), 'dk': tr('Дания'),
    'ee': tr('Эстония'), 'eg': tr('Египет'), 'es': tr('Испания'), 'fi': tr('Финляндия'), 'fr': tr('Франция'), 'gb': tr('Великобритания'),
    'ge': tr('Грузия'), 'gr': tr('Греция'), 'hk': tr('Гонконг'), 'hr': tr('Хорватия'), 'hu': tr('Венгрия'), 'id': tr('Индонезия'),
    'ie': tr('Ирландия'), 'il': tr('Израиль'), 'in': tr('Индия'), 'is': tr('Исландия'), 'it': tr('Италия'), 'jp': tr('Япония'),
    'kg': tr('Киргизия'), 'kr': tr('Южная Корея'), 'kz': tr('Казахстан'), 'lt': tr('Литва'), 'lu': tr('Люксембург'), 'lv': tr('Латвия'),
    'md': tr('Молдова'), 'mx': tr('Мексика'), 'my': tr('Малайзия'), 'nl': tr('Нидерланды'), 'no': tr('Норвегия'),
    'nz': tr('Новая Зеландия'), 'pl': tr('Польша'), 'pt': tr('Португалия'), 'ro': tr('Румыния'), 'rs': tr('Сербия'), 'ru': tr('Россия'),
    'se': tr('Швеция'), 'sg': tr('Сингапур'), 'si': tr('Словения'), 'sk': tr('Словакия'), 'th': tr('Таиланд'), 'tr': tr('Турция'),
    'tw': tr('Тайвань'), 'ua': tr('Украина'), 'us': tr('США'), 'uz': tr('Узбекистан'), 'vn': tr('Вьетнам'), 'za': tr('ЮАР'),
  };

  /// Название страны по коду (`fi` → «Финляндия»); неизвестная — кодом (`XX`).
  static String countryName(String code) => _countries[code.toLowerCase()] ?? code.toUpperCase();

  /// Текст с флагами-картинками для Text.rich / Tooltip.richMessage.
  static InlineSpan span(String text, {TextStyle? style, double size = 13}) {
    final parts = split(text);
    return TextSpan(style: style, children: [
      for (var i = 0; i < parts.length; i++)
        if (parts[i].country != null) ...[
          WidgetSpan(alignment: PlaceholderAlignment.middle, child: FlagIcon(parts[i].country!, height: size)),
          if (i + 1 < parts.length && !(parts[i + 1].text?.startsWith(' ') ?? true)) const TextSpan(text: ' '),
        ] else
          TextSpan(text: parts[i].text),
    ]);
  }
}

/// Картинка флага; если такой страны нет — аккуратная плашка с кодом.
class FlagIcon extends StatelessWidget {
  const FlagIcon(this.country, {super.key, this.height = 14}) : round = false;

  /// Круглый флаг (как в списке серверов Happ).
  const FlagIcon.round(this.country, {super.key, double size = 26})
      : height = size,
        round = true;

  final String country;
  final double height;
  final bool round;

  @override
  Widget build(BuildContext context) {
    if (round) {
      return Container(
        width: height,
        height: height,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: C.border)),
        child: ClipOval(
          child: Image.asset(
            'assets/flags/$country.png',
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => Container(
              color: C.surface2,
              alignment: Alignment.center,
              child: Text(country.toUpperCase(),
                  style: TextStyle(fontSize: height * 0.36, fontWeight: FontWeight.w700, color: C.muted)),
            ),
          ),
        ),
      );
    }
    final width = height * 4 / 3;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height * 0.2),
      child: Image.asset(
        'assets/flags/$country.png',
        width: width,
        height: height,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => Container(
          width: width,
          height: height,
          color: C.surface2,
          alignment: Alignment.center,
          child: Text(country.toUpperCase(),
              style: TextStyle(fontSize: height * 0.55, fontWeight: FontWeight.w700, color: C.muted)),
        ),
      ),
    );
  }
}

/// Текст, в котором эмодзи-флаги показаны картинками.
class FlagText extends StatelessWidget {
  const FlagText(this.text, {super.key, this.style, this.maxLines, this.overflow, this.textAlign});
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final parts = Flags.split(text);
    if (parts.every((p) => p.country == null)) {
      return Text(text, style: style, maxLines: maxLines, overflow: overflow, textAlign: textAlign);
    }
    final fontSize = style?.fontSize ?? DefaultTextStyle.of(context).style.fontSize ?? 14;
    return Text.rich(
      TextSpan(children: [
        for (var i = 0; i < parts.length; i++)
          if (parts[i].country != null) ...[
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: FlagIcon(parts[i].country!, height: fontSize * 0.95),
            ),
            // Зазор после флага, если в тексте его нет (частый случай «🇩🇪Germany»).
            if (i + 1 < parts.length && !(parts[i + 1].text?.startsWith(' ') ?? true)) const TextSpan(text: ' '),
          ] else
            TextSpan(text: parts[i].text),
      ]),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
  }
}
