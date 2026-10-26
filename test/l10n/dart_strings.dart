/// Разбор строковых литералов в исходниках Dart — для перевода интерфейса (test/l10n_test.dart): находит
/// строки с русским текстом, в том числе склеенные соседние ('…' '…') и с подстановками ($x, ${…}).
library;

final cyrillic = RegExp('[А-Яа-яЁё]');

/// Часть литерала: текст ([value] — как в программе, [source] — как в исходнике) или подстановка ([expr]).
class Part {
  Part.text(this.source, this.value)
      : expr = null,
        exprStart = 0,
        braced = false;
  Part.interp(this.expr, this.exprStart, {this.braced = true})
      : source = '',
        value = '';

  /// Подстановка записана как ${…}, а не $имя.
  final bool braced;
  final String source;
  final String value;
  final String? expr;

  /// Где в файле начинается выражение подстановки.
  final int exprStart;
  bool get isText => expr == null;
}

class Literal {
  Literal(this.start, this.end, this.prefix, this.quote, this.parts);
  final int start;
  final int end;

  /// 'r' у «сырых» строк, иначе пусто.
  final String prefix;
  final String quote;
  final List<Part> parts;
}

/// Соседние литералы, которые Dart склеивает в одну строку.
class Unit {
  Unit(this.literals);
  final List<Literal> literals;
  int get start => literals.first.start;
  int get end => literals.last.end;

  List<Part> get parts => [for (final l in literals) ...l.parts];
  bool get hasCyrillic => parts.any((p) => p.isText && cyrillic.hasMatch(p.value));

  /// Строка-ключ перевода: текст как в программе, подстановки — {0}, {1}…
  String get key {
    final b = StringBuffer();
    var n = 0;
    for (final p in parts) {
      b.write(p.isText ? p.value : '{${n++}}');
    }
    return b.toString();
  }

  int get argCount => parts.where((p) => !p.isText).length;
}

class Scanner {
  Scanner(this.src);
  final String src;
  final units = <Unit>[];

  /// Все строки файла, в том числе вложенные в подстановки.
  List<Unit> scan() {
    _code(0, src.length, topLevel: true);
    units.sort((a, b) => a.start.compareTo(b.start));
    return units;
  }

  static bool _ident(String c) => RegExp(r'[A-Za-z0-9_$]').hasMatch(c);

  /// Код от [from] до закрывающей «}» (если не [topLevel]) или до [to]. Возвращает, где кончился.
  int _code(int from, int to, {bool topLevel = false}) {
    var i = from;
    var depth = 0;
    while (i < to) {
      final c = src[i];
      if (src.startsWith('//', i)) {
        final e = src.indexOf('\n', i);
        i = e < 0 ? to : e;
        continue;
      }
      if (src.startsWith('/*', i)) {
        final e = src.indexOf('*/', i + 2);
        i = e < 0 ? to : e + 2;
        continue;
      }
      final rawStart = c == 'r' && i + 1 < to && (src[i + 1] == '"' || src[i + 1] == "'") && (i == 0 || !_ident(src[i - 1]));
      if (c == '"' || c == "'" || rawStart) {
        {
          final unit = <Literal>[];
          var j = i;
          while (true) {
            final lit = _string(j);
            unit.add(lit);
            j = lit.end;
            var k = j;
            while (k < to && ' \t\r\n'.contains(src[k])) {
              k++;
            }
            final isStr = k < to &&
                (src[k] == '"' || src[k] == "'" || (src[k] == 'r' && k + 1 < to && (src[k + 1] == '"' || src[k + 1] == "'")));
            if (!isStr) break;
            j = k;
          }
          units.add(Unit(unit));
          i = j;
          continue;
        }
      }
      if (c == '{') depth++;
      if (c == '}') {
        if (!topLevel && depth == 0) return i;
        depth--;
      }
      i++;
    }
    return i;
  }

  Literal _string(int start) {
    var i = start;
    var prefix = '';
    if (src[i] == 'r') {
      prefix = 'r';
      i++;
    }
    final q = src[i];
    final triple = src.startsWith(q * 3, i);
    final quote = triple ? q * 3 : q;
    i += quote.length;
    final parts = <Part>[];
    var textStart = i;
    final value = StringBuffer();
    void flush(int end) {
      if (end > textStart) parts.add(Part.text(src.substring(textStart, end), value.toString()));
      value.clear();
    }

    while (i < src.length) {
      if (src.startsWith(quote, i)) {
        flush(i);
        return Literal(start, i + quote.length, prefix, quote, parts);
      }
      final c = src[i];
      if (prefix.isEmpty && c == r'\') {
        final n = src[i + 1];
        switch (n) {
          case 'n':
            value.write('\n');
            i += 2;
          case 'r':
            value.write('\r');
            i += 2;
          case 't':
            value.write('\t');
            i += 2;
          case 'u':
            if (src[i + 2] == '{') {
              final e = src.indexOf('}', i);
              value.writeCharCode(int.parse(src.substring(i + 3, e), radix: 16));
              i = e + 1;
            } else {
              value.writeCharCode(int.parse(src.substring(i + 2, i + 6), radix: 16));
              i += 6;
            }
          case 'x':
            value.writeCharCode(int.parse(src.substring(i + 2, i + 4), radix: 16));
            i += 4;
          default:
            value.write(n);
            i += 2;
        }
        continue;
      }
      if (prefix.isEmpty && c == r'$') {
        if (src[i + 1] == '{') {
          flush(i);
          final end = _code(i + 2, src.length);
          parts.add(Part.interp(src.substring(i + 2, end), i + 2));
          i = end + 1;
          textStart = i;
          continue;
        }
        var e = i + 1;
        while (e < src.length && RegExp(r'[A-Za-z0-9_]').hasMatch(src[e])) {
          e++;
        }
        flush(i);
        parts.add(Part.interp(src.substring(i + 1, e), i + 1, braced: false));
        i = e;
        textStart = i;
        continue;
      }
      value.write(c);
      i++;
    }
    throw FormatException('Незакрытая строка', src, start);
  }
}

/// Что стоит перед строкой: «RegExp(» — шаблон поиска, «tr(» — уже переведена.
String before(String src, int pos) {
  var i = pos - 1;
  while (i >= 0 && ' \t\r\n'.contains(src[i])) {
    i--;
  }
  final from = i - 20 < 0 ? 0 : i - 20;
  return src.substring(from, i + 1);
}

bool isRegExpArg(String src, Unit u) => RegExp(r'RegExp\($').hasMatch(before(src, u.start));
bool isWrapped(String src, Unit u) => RegExp(r'(^|[^A-Za-z0-9_])tr\($').hasMatch(before(src, u.start));
