import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// QR-коды по стандарту ISO/IEC 18004: показ ссылки сервера кодом ([QrCode.encode]) и распознавание кода
/// на снимке экрана или картинке ([QrDecoder.decode]). Без сторонних пакетов.
class QrCode {
  QrCode._(this.version, this.size, this.modules);

  final int version;
  final int size;

  /// modules[y][x] — тёмный модуль.
  final List<List<bool>> modules;

  /// Сколько байт текста помещается в самый большой код (версия 40, уровень коррекции L).
  static const maxBytes = 2953;

  /// Код для [text] (UTF-8). Уровень коррекции M (код читается и с частично испорченной картинки),
  /// для длинного текста — L. null — текст не помещается даже в самый большой код.
  static QrCode? encode(String text) {
    final data = utf8.encode(text);
    for (final ecl in const [_Ecl.m, _Ecl.l]) {
      for (var ver = 1; ver <= 40; ver++) {
        final ccBits = ver <= 9 ? 8 : 16;
        if (4 + ccBits + data.length * 8 <= _numDataCodewords(ver, ecl) * 8) return _build(ver, ecl, data);
      }
    }
    return null;
  }

  static QrCode _build(int ver, _Ecl ecl, List<int> data) {
    final bits = _Bits()
      ..add(4, 4)
      ..add(data.length, ver <= 9 ? 8 : 16);
    for (final b in data) {
      bits.add(b, 8);
    }
    final capacity = _numDataCodewords(ver, ecl) * 8;
    bits.add(0, math.min(4, capacity - bits.length));
    bits.add(0, (8 - bits.length % 8) % 8);
    final codewords = bits.bytes();
    for (var pad = 0xEC; codewords.length < capacity ~/ 8; pad ^= 0xEC ^ 0x11) {
      codewords.add(pad);
    }
    final grid = _Grid(ver);
    grid.drawCodewords(_addEccAndInterleave(codewords, ver, ecl));
    var best = -1;
    var bestPenalty = 0;
    for (var mask = 0; mask < 8; mask++) {
      grid.applyMask(mask);
      grid.drawFormat(ecl, mask);
      final p = grid.penalty();
      if (best < 0 || p < bestPenalty) {
        best = mask;
        bestPenalty = p;
      }
      grid.applyMask(mask);
    }
    grid.applyMask(best);
    grid.drawFormat(ecl, best);
    return QrCode._(ver, grid.size, grid.modules);
  }
}

/// Распознавание QR-кодов в картинке оттенков серого (0 — чёрный, 255 — белый): снимок экрана, файл,
/// картинка из буфера обмена. Ищет три угловых квадрата, по ним — сетку модулей; рассчитан на
/// снимки экрана и картинки без сильного перекоса перспективы. Светлый код на тёмном фоне тоже находится.
class QrDecoder {
  /// Тексты всех найденных кодов (без повторов); пусто — кодов нет.
  static List<String> decode(Uint8List gray, int width, int height) {
    if (width < 21 || height < 21 || gray.length < width * height) return const [];
    final found = <String>[];
    final thresholds = {_otsu(gray, width * height), 128};
    for (final invert in const [false, true]) {
      for (final t in thresholds) {
        final img = _Binary(gray, width, height, t, invert);
        for (final text in _decodeBinary(img)) {
          if (!found.contains(text)) found.add(text);
        }
        if (found.isNotEmpty) return found;
      }
    }
    return found;
  }

  static List<String> _decodeBinary(_Binary img) {
    final centers = _FinderFinder(img).find();
    if (centers.length < 3) return const [];
    // Самые надёжные кандидаты — найденные больше одного раза; перебор троек ограничен.
    centers.sort((a, b) => b.count.compareTo(a.count));
    final list = centers.take(24).toList();
    final results = <String>[];
    final used = <_Center>{};
    final triples = <({double score, _Center a, _Center b, _Center c})>[];
    for (var i = 0; i < list.length; i++) {
      for (var j = i + 1; j < list.length; j++) {
        for (var k = j + 1; k < list.length; k++) {
          final s = _tripleScore(list[i], list[j], list[k]);
          if (s != null) triples.add((score: s, a: list[i], b: list[j], c: list[k]));
        }
      }
    }
    triples.sort((x, y) => x.score.compareTo(y.score));
    for (final t in triples) {
      if (used.contains(t.a) || used.contains(t.b) || used.contains(t.c)) continue;
      final text = _decodeAt(img, t.a, t.b, t.c);
      if (text != null) {
        results.add(text);
        used.addAll([t.a, t.b, t.c]);
      }
    }
    return results;
  }

  /// Насколько тройка похожа на углы одного кода (меньше — лучше); null — не похожа.
  static double? _tripleScore(_Center a, _Center b, _Center c) {
    final sizes = [a.module, b.module, c.module]..sort();
    if (sizes[2] > sizes[0] * 1.6) return null;
    final ab = _dist(a, b), bc = _dist(b, c), ac = _dist(a, c);
    final sides = [ab, bc, ac]..sort();
    final leg1 = sides[0], leg2 = sides[1], hyp = sides[2];
    if (leg2 > leg1 * 1.4) return null;
    final expected = math.sqrt(leg1 * leg1 + leg2 * leg2);
    final skew = (hyp - expected).abs() / expected;
    if (skew > 0.15) return null;
    final module = (a.module + b.module + c.module) / 3;
    // Между центрами угловых квадратов не меньше 14 модулей (версия 1: 21 − 7).
    if (leg1 < module * 12) return null;
    return skew + (leg2 / leg1 - 1);
  }

  static double _dist(_Center a, _Center b) => math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));

  static String? _decodeAt(_Binary img, _Center p, _Center q, _Center r) {
    // Левый верхний угол — напротив самой длинной стороны.
    _Center tl, tr, bl;
    final pq = _dist(p, q), qr = _dist(q, r), pr = _dist(p, r);
    if (qr >= pq && qr >= pr) {
      (tl, tr, bl) = (p, q, r);
    } else if (pr >= pq && pr >= qr) {
      (tl, tr, bl) = (q, p, r);
    } else {
      (tl, tr, bl) = (r, p, q);
    }
    // Ось y смотрит вниз: у обычного (не зеркального) кода правый верхний — по часовой стрелке от левого нижнего.
    if ((tr.x - tl.x) * (bl.y - tl.y) - (tr.y - tl.y) * (bl.x - tl.x) < 0) (tr, bl) = (bl, tr);
    final module = (tl.module + tr.module + bl.module) / 3;
    final estimate = ((_dist(tl, tr) + _dist(tl, bl)) / 2 / module + 7).round();
    final candidates = <int>{};
    final v0 = ((estimate - 17) / 4).round();
    for (final v in [v0, v0 - 1, v0 + 1]) {
      if (v >= 1 && v <= 40) candidates.add(v);
    }
    for (final ver in candidates) {
      final grid = _sample(img, tl, tr, bl, ver);
      // С версии 7 версия записана в самом коде — если она другая, пробуем её.
      if (ver >= 7) {
        final written = _readVersion(grid);
        if (written != null && written != ver) {
          final text = _decodeGrid(_sample(img, tl, tr, bl, written), written);
          if (text != null) return text;
          continue;
        }
      }
      final text = _decodeGrid(grid, ver);
      if (text != null) return text;
    }
    return null;
  }

  /// Сетка модулей версии [ver]: центры угловых квадратов — в модулях (3,5; 3,5), (size − 3,5; 3,5), (3,5; size − 3,5).
  static List<List<bool>> _sample(_Binary img, _Center tl, _Center tr, _Center bl, int ver) {
    final size = ver * 4 + 17;
    final span = size - 7.0;
    final ux = (tr.x - tl.x) / span, uy = (tr.y - tl.y) / span;
    final vx = (bl.x - tl.x) / span, vy = (bl.y - tl.y) / span;
    return [
      for (var y = 0; y < size; y++)
        [
          for (var x = 0; x < size; x++)
            img.dark((tl.x + (x - 3) * ux + (y - 3) * vx).floor(), (tl.y + (x - 3) * uy + (y - 3) * vy).floor()),
        ],
    ];
  }

  static int? _readVersion(List<List<bool>> grid) {
    final size = grid.length;
    int? best;
    var bestDist = 4;
    for (final copy in [0, 1]) {
      var bits = 0;
      for (var i = 0; i < 18; i++) {
        final a = size - 11 + i % 3, b = i ~/ 3;
        if (copy == 0 ? grid[b][a] : grid[a][b]) bits |= 1 << i;
      }
      for (var v = 7; v <= 40; v++) {
        final d = _bitCount(bits ^ _versionBits(v));
        if (d < bestDist) {
          bestDist = d;
          best = v;
        }
      }
    }
    return best;
  }

  static String? _decodeGrid(List<List<bool>> grid, int ver) {
    final size = grid.length;
    // Формат (уровень коррекции и маска) записан дважды; берём ближайший к допустимым.
    var c1 = 0, c2 = 0;
    for (var i = 0; i <= 5; i++) {
      if (grid[i][8]) c1 |= 1 << i;
    }
    if (grid[7][8]) c1 |= 1 << 6;
    if (grid[8][8]) c1 |= 1 << 7;
    if (grid[8][7]) c1 |= 1 << 8;
    for (var i = 9; i < 15; i++) {
      if (grid[8][14 - i]) c1 |= 1 << i;
    }
    for (var i = 0; i < 8; i++) {
      if (grid[8][size - 1 - i]) c2 |= 1 << i;
    }
    for (var i = 8; i < 15; i++) {
      if (grid[size - 15 + i][8]) c2 |= 1 << i;
    }
    _Ecl? ecl;
    var mask = 0;
    var bestDist = 4;
    for (final e in _Ecl.values) {
      for (var m = 0; m < 8; m++) {
        final f = _formatBits(e, m);
        final d = math.min(_bitCount(c1 ^ f), _bitCount(c2 ^ f));
        if (d < bestDist) {
          bestDist = d;
          ecl = e;
          mask = m;
        }
      }
    }
    if (ecl == null) return null;
    final layout = _Grid(ver);
    final raw = layout.readCodewords(grid, mask);
    final data = _deinterleaveAndCorrect(raw, ver, ecl);
    if (data == null) return null;
    return _parseData(data, ver);
  }

  static String? _parseData(List<int> data, int ver) {
    final r = _BitReader(data);
    final out = BytesBuilder();
    const alnum = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ \$%*+-./:';
    while (r.left >= 4) {
      final mode = r.read(4);
      switch (mode) {
        case 0:
          return _text(out);
        case 1:
          var n = r.read(ver <= 9 ? 10 : (ver <= 26 ? 12 : 14));
          while (n >= 3) {
            out.add(utf8.encode(r.read(10).toString().padLeft(3, '0')));
            n -= 3;
          }
          if (n == 2) out.add(utf8.encode(r.read(7).toString().padLeft(2, '0')));
          if (n == 1) out.add(utf8.encode(r.read(4).toString()));
        case 2:
          var n = r.read(ver <= 9 ? 9 : (ver <= 26 ? 11 : 13));
          while (n >= 2) {
            final v = r.read(11);
            if (v ~/ 45 >= 45) return null;
            out.add(utf8.encode(alnum[v ~/ 45] + alnum[v % 45]));
            n -= 2;
          }
          if (n == 1) {
            final v = r.read(6);
            if (v >= 45) return null;
            out.add(utf8.encode(alnum[v]));
          }
        case 4:
          final n = r.read(ver <= 9 ? 8 : 16);
          if (r.left < n * 8) return null;
          for (var i = 0; i < n; i++) {
            out.addByte(r.read(8));
          }
        case 7:
          // ECI — кодировка; ссылки серверов всегда в UTF-8, номер пропускаем.
          final first = r.read(8);
          if (first & 0x80 != 0) r.read(first & 0x40 == 0 ? 8 : 16);
        case 3:
          r.read(16);
        case 5:
          break;
        case 9:
          r.read(8);
        default:
          return out.isEmpty ? null : _text(out);
      }
      if (r.left < 0) return null;
    }
    return _text(out);
  }

  static String? _text(BytesBuilder out) => out.isEmpty ? null : utf8.decode(out.takeBytes(), allowMalformed: true);

  static int _otsu(Uint8List gray, int n) {
    final hist = List<int>.filled(256, 0);
    for (var i = 0; i < n; i++) {
      hist[gray[i]]++;
    }
    var sum = 0.0;
    for (var i = 0; i < 256; i++) {
      sum += i * hist[i];
    }
    var sumB = 0.0, wB = 0, best = 0.0, threshold = 128;
    for (var t = 0; t < 256; t++) {
      wB += hist[t];
      if (wB == 0) continue;
      final wF = n - wB;
      if (wF == 0) break;
      sumB += t * hist[t];
      final mB = sumB / wB, mF = (sum - sumB) / wF;
      final between = wB * wF * (mB - mF) * (mB - mF);
      if (between > best) {
        best = between;
        threshold = t + 1;
      }
    }
    return threshold;
  }
}

/// Чёрно-белая картинка: тёмный — ярче порога не стал (или наоборот при [invert]).
class _Binary {
  _Binary(Uint8List gray, this.width, this.height, int threshold, bool invert) : bits = Uint8List(width * height) {
    for (var i = 0; i < width * height; i++) {
      bits[i] = (gray[i] < threshold) != invert ? 1 : 0;
    }
  }

  final int width;
  final int height;
  final Uint8List bits;

  bool dark(int x, int y) => x >= 0 && y >= 0 && x < width && y < height && bits[y * width + x] == 1;
}

class _Center {
  _Center(this.x, this.y, this.module);
  double x;
  double y;
  double module;
  int count = 1;
}

/// Поиск угловых квадратов: в строке ищутся участки чёрный-белый-чёрный-белый-чёрный в пропорции 1:1:3:1:1,
/// затем то же проверяется по вертикали и ещё раз по горизонтали через найденный центр.
class _FinderFinder {
  _FinderFinder(this.img);
  final _Binary img;
  final centers = <_Center>[];

  List<_Center> find() {
    final w = img.width;
    for (var y = 0; y < img.height; y++) {
      final counts = [0, 0, 0, 0, 0];
      var state = 0;
      final row = y * w;
      for (var x = 0; x < w; x++) {
        if (img.bits[row + x] == 1) {
          if (state & 1 == 1) state++;
          counts[state]++;
        } else if (state & 1 == 0) {
          if (state == 4) {
            if (_ratioOk(counts)) _handle(counts, y, x);
            counts
              ..[0] = counts[2]
              ..[1] = counts[3]
              ..[2] = counts[4]
              ..[3] = 1
              ..[4] = 0;
            state = 3;
          } else {
            state++;
            counts[state]++;
          }
        } else {
          counts[state]++;
        }
      }
      if (state == 4 && _ratioOk(counts)) _handle(counts, y, w);
    }
    return centers;
  }

  static bool _ratioOk(List<int> c) {
    final total = c[0] + c[1] + c[2] + c[3] + c[4];
    if (total < 7) return false;
    final m = total / 7, v = m / 2;
    return (m - c[0]).abs() < v &&
        (m - c[1]).abs() < v &&
        (3 * m - c[2]).abs() < 3 * v &&
        (m - c[3]).abs() < v &&
        (m - c[4]).abs() < v;
  }

  void _handle(List<int> counts, int y, int endX) {
    final total = counts.reduce((a, b) => a + b);
    var cx = endX - counts[4] - counts[3] - counts[2] / 2;
    final cy = _cross(cx.floor(), y, total, vertical: true);
    if (cy == null) return;
    final hx = _cross(cx.floor(), cy.value.floor(), total, vertical: false);
    if (hx == null) return;
    cx = hx.value;
    final module = (hx.total + cy.total) / 14;
    for (final c in centers) {
      if ((c.x - cx).abs() <= c.module * 1.5 && (c.y - cy.value).abs() <= c.module * 1.5 &&
          (c.module - module).abs() <= math.max(1, c.module * 0.5)) {
        c
          ..x = (c.x * c.count + cx) / (c.count + 1)
          ..y = (c.y * c.count + cy.value) / (c.count + 1)
          ..module = (c.module * c.count + module) / (c.count + 1)
          ..count += 1;
        return;
      }
    }
    if (centers.length < 200) centers.add(_Center(cx, cy.value, module));
  }

  /// Проверка поперёк: из точки ([x], [y]) внутри центра квадрата — в обе стороны по столбцу ([vertical])
  /// или по строке. Возвращает центр по этой оси и длину узора.
  ({double value, int total})? _cross(int x, int y, int originalTotal, {required bool vertical}) {
    final limit = vertical ? img.height : img.width;
    final start = vertical ? y : x;
    bool dark(int p) => vertical ? img.dark(x, p) : img.dark(p, y);
    if (!dark(start)) return null;
    final c = [0, 0, 0, 0, 0];
    var p = start;
    while (p >= 0 && dark(p)) {
      c[2]++;
      p--;
    }
    while (p >= 0 && !dark(p)) {
      c[1]++;
      p--;
    }
    while (p >= 0 && dark(p)) {
      c[0]++;
      p--;
    }
    p = start + 1;
    while (p < limit && dark(p)) {
      c[2]++;
      p++;
    }
    while (p < limit && !dark(p)) {
      c[3]++;
      p++;
    }
    while (p < limit && dark(p)) {
      c[4]++;
      p++;
    }
    final total = c.reduce((a, b) => a + b);
    if (5 * (total - originalTotal).abs() >= 2 * originalTotal) return null;
    if (!_ratioOk(c)) return null;
    return (value: p - c[4] - c[3] - c[2] / 2, total: total);
  }
}

// ---------- устройство кода ----------

enum _Ecl {
  l(1),
  m(0),
  q(3),
  h(2);

  // Порядок L, M, Q, H — как строки таблиц ниже (по index).
  const _Ecl(this.formatBits);
  final int formatBits;
}

const _eccPerBlock = [
  [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
  [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
  [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
  [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
];

const _numBlocks = [
  [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
  [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
  [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
  [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
];

int _numRawDataModules(int ver) {
  var result = (16 * ver + 128) * ver + 64;
  if (ver >= 2) {
    final numAlign = ver ~/ 7 + 2;
    result -= (25 * numAlign - 10) * numAlign - 55;
    if (ver >= 7) result -= 36;
  }
  return result;
}

int _numDataCodewords(int ver, _Ecl ecl) =>
    _numRawDataModules(ver) ~/ 8 - _eccPerBlock[ecl.index][ver] * _numBlocks[ecl.index][ver];

/// Для тестов: сколько байт данных (с заголовком) вмещает версия [ver] на уровне [level] (L, M, Q, H).
int qrDataCodewordsForTest(int ver, String level) =>
    _numDataCodewords(ver, _Ecl.values.firstWhere((e) => e.name == level.toLowerCase()));

/// Для тестов: байты коррекции, служебные биты формата и версии.
List<int> qrEccForTest(List<int> data, int degree) => _eccFor(data, degree);
int qrFormatBitsForTest(String level, int mask) =>
    _formatBits(_Ecl.values.firstWhere((e) => e.name == level.toLowerCase()), mask);
int qrVersionBitsForTest(int ver) => _versionBits(ver);

int _formatBits(_Ecl ecl, int mask) {
  final data = ecl.formatBits << 3 | mask;
  var rem = data;
  for (var i = 0; i < 10; i++) {
    rem = (rem << 1) ^ ((rem >> 9) * 0x537);
  }
  return (data << 10 | rem) ^ 0x5412;
}

int _versionBits(int ver) {
  var rem = ver;
  for (var i = 0; i < 12; i++) {
    rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
  }
  return ver << 12 | rem;
}

int _bitCount(int v) {
  var n = 0;
  for (; v != 0; v &= v - 1) {
    n++;
  }
  return n;
}

List<int> _alignmentPositions(int ver) {
  if (ver == 1) return const [];
  final numAlign = ver ~/ 7 + 2;
  final step = (ver * 8 + numAlign * 3 + 5) ~/ (numAlign * 4 - 4) * 2;
  final result = List<int>.filled(numAlign, 6);
  for (var i = numAlign - 1, pos = ver * 4 + 17 - 7; i >= 1; i--, pos -= step) {
    result[i] = pos;
  }
  return result;
}

bool _maskBit(int mask, int x, int y) => switch (mask) {
      0 => (x + y) % 2 == 0,
      1 => y % 2 == 0,
      2 => x % 3 == 0,
      3 => (x + y) % 3 == 0,
      4 => (x ~/ 3 + y ~/ 2) % 2 == 0,
      5 => x * y % 2 + x * y % 3 == 0,
      6 => (x * y % 2 + x * y % 3) % 2 == 0,
      _ => ((x + y) % 2 + x * y % 3) % 2 == 0,
    };

/// Сетка модулей версии: служебные узоры (угловые квадраты, полосы синхронизации, выравнивание,
/// формат, версия) и порядок, в котором по ней идут байты данных.
class _Grid {
  _Grid(this.version)
      : size = version * 4 + 17,
        modules = List.generate(version * 4 + 17, (_) => List.filled(version * 4 + 17, false)),
        function = List.generate(version * 4 + 17, (_) => List.filled(version * 4 + 17, false)) {
    for (var i = 0; i < size; i++) {
      _set(6, i, i % 2 == 0);
      _set(i, 6, i % 2 == 0);
    }
    for (final (cx, cy) in [(3, 3), (size - 4, 3), (3, size - 4)]) {
      for (var dy = -4; dy <= 4; dy++) {
        for (var dx = -4; dx <= 4; dx++) {
          final x = cx + dx, y = cy + dy;
          if (x < 0 || y < 0 || x >= size || y >= size) continue;
          final d = math.max(dx.abs(), dy.abs());
          _set(x, y, d != 2 && d != 4);
        }
      }
    }
    final align = _alignmentPositions(version);
    final last = align.length - 1;
    for (var i = 0; i < align.length; i++) {
      for (var j = 0; j < align.length; j++) {
        if ((i == 0 && j == 0) || (i == 0 && j == last) || (i == last && j == 0)) continue;
        for (var dy = -2; dy <= 2; dy++) {
          for (var dx = -2; dx <= 2; dx++) {
            _set(align[i] + dx, align[j] + dy, math.max(dx.abs(), dy.abs()) != 1);
          }
        }
      }
    }
    drawFormat(_Ecl.l, 0);
    if (version >= 7) {
      final bits = _versionBits(version);
      for (var i = 0; i < 18; i++) {
        final bit = (bits >> i) & 1 == 1;
        final a = size - 11 + i % 3, b = i ~/ 3;
        _set(a, b, bit);
        _set(b, a, bit);
      }
    }
  }

  final int version;
  final int size;
  final List<List<bool>> modules;
  final List<List<bool>> function;

  void _set(int x, int y, bool dark) {
    modules[y][x] = dark;
    function[y][x] = true;
  }

  void drawFormat(_Ecl ecl, int mask) {
    final bits = _formatBits(ecl, mask);
    bool bit(int i) => (bits >> i) & 1 == 1;
    for (var i = 0; i <= 5; i++) {
      _set(8, i, bit(i));
    }
    _set(8, 7, bit(6));
    _set(8, 8, bit(7));
    _set(7, 8, bit(8));
    for (var i = 9; i < 15; i++) {
      _set(14 - i, 8, bit(i));
    }
    for (var i = 0; i < 8; i++) {
      _set(size - 1 - i, 8, bit(i));
    }
    for (var i = 8; i < 15; i++) {
      _set(8, size - 15 + i, bit(i));
    }
    _set(8, size - 8, true);
  }

  /// Модули данных в порядке записи: столбцы по два справа налево, змейкой вверх и вниз.
  Iterable<(int, int)> _dataOrder() sync* {
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5;
      for (var vert = 0; vert < size; vert++) {
        for (var j = 0; j < 2; j++) {
          final x = right - j;
          final upward = (right + 1) & 2 == 0;
          final y = upward ? size - 1 - vert : vert;
          if (!function[y][x]) yield (x, y);
        }
      }
    }
  }

  void drawCodewords(List<int> data) {
    var i = 0;
    for (final (x, y) in _dataOrder()) {
      if (i >= data.length * 8) break;
      modules[y][x] = (data[i >> 3] >> (7 - (i & 7))) & 1 == 1;
      i++;
    }
  }

  List<int> readCodewords(List<List<bool>> grid, int mask) {
    final count = _numRawDataModules(version) ~/ 8;
    final out = List<int>.filled(count, 0);
    var i = 0;
    for (final (x, y) in _dataOrder()) {
      if (i >= count * 8) break;
      if (grid[y][x] != _maskBit(mask, x, y)) out[i >> 3] |= 1 << (7 - (i & 7));
      i++;
    }
    return out;
  }

  void applyMask(int mask) {
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        if (!function[y][x] && _maskBit(mask, x, y)) modules[y][x] = !modules[y][x];
      }
    }
  }

  /// Штраф маски по стандарту: длинные полосы, квадраты 2×2, похожие на угловой квадрат узоры, перекос
  /// тёмного и светлого.
  int penalty() {
    var result = 0;
    bool at(int x, int y, bool rows) => rows ? modules[y][x] : modules[x][y];
    for (final rows in const [true, false]) {
      for (var a = 0; a < size; a++) {
        var run = 1;
        for (var b = 1; b < size; b++) {
          if (at(b, a, rows) == at(b - 1, a, rows)) {
            run++;
            if (run == 5) result += 3;
            if (run > 5) result++;
          } else {
            run = 1;
          }
        }
        for (var b = 0; b + 10 < size; b++) {
          var p1 = true, p2 = true;
          const pattern = [true, false, true, true, true, false, true, false, false, false, false];
          for (var k = 0; k < 11; k++) {
            if (at(b + k, a, rows) != pattern[k]) p1 = false;
            if (at(b + k, a, rows) != pattern[10 - k]) p2 = false;
          }
          if (p1) result += 40;
          if (p2) result += 40;
        }
      }
    }
    var darkCount = 0;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        if (modules[y][x]) darkCount++;
        if (x + 1 < size && y + 1 < size) {
          final c = modules[y][x];
          if (c == modules[y][x + 1] && c == modules[y + 1][x] && c == modules[y + 1][x + 1]) result += 3;
        }
      }
    }
    final total = size * size;
    final k = (((darkCount * 20 - total * 10).abs() + total - 1) ~/ total) - 1;
    return result + math.max(0, k) * 10;
  }
}

// ---------- коррекция ошибок (Рида — Соломона над GF(256)) ----------

final _exp = () {
  final t = List<int>.filled(512, 0);
  var x = 1;
  for (var i = 0; i < 255; i++) {
    t[i] = x;
    x <<= 1;
    if (x & 0x100 != 0) x ^= 0x11D;
  }
  for (var i = 255; i < 512; i++) {
    t[i] = t[i - 255];
  }
  return t;
}();

final _log = () {
  final t = List<int>.filled(256, 0);
  for (var i = 0; i < 255; i++) {
    t[_exp[i]] = i;
  }
  return t;
}();

int _mul(int a, int b) => a == 0 || b == 0 ? 0 : _exp[_log[a] + _log[b]];
int _div(int a, int b) => a == 0 ? 0 : _exp[(_log[a] + 255 - _log[b]) % 255];

/// Коэффициенты g(x) = (x − α⁰)(x − α¹)…(x − α^(degree−1)), от старшего: g[0] = 1.
List<int> _generator(int degree) {
  var g = [1];
  for (var i = 0; i < degree; i++) {
    final next = List<int>.filled(g.length + 1, 0);
    for (var j = 0; j < g.length; j++) {
      next[j] ^= g[j];
      next[j + 1] ^= _mul(g[j], _exp[i]);
    }
    g = next;
  }
  return g;
}

List<int> _eccFor(List<int> data, int degree) {
  final g = _generator(degree);
  final msg = [...data, ...List.filled(degree, 0)];
  for (var i = 0; i < data.length; i++) {
    final coef = msg[i];
    if (coef == 0) continue;
    for (var j = 1; j <= degree; j++) {
      msg[i + j] ^= _mul(g[j], coef);
    }
  }
  return msg.sublist(data.length);
}

({int numBlocks, int eccLen, int numShort, int shortDataLen}) _blockLayout(int ver, _Ecl ecl) {
  final numBlocks = _numBlocks[ecl.index][ver];
  final eccLen = _eccPerBlock[ecl.index][ver];
  final raw = _numRawDataModules(ver) ~/ 8;
  final numShort = numBlocks - raw % numBlocks;
  return (numBlocks: numBlocks, eccLen: eccLen, numShort: numShort, shortDataLen: raw ~/ numBlocks - eccLen);
}

List<int> _addEccAndInterleave(List<int> data, int ver, _Ecl ecl) {
  final l = _blockLayout(ver, ecl);
  final blocks = <List<int>>[];
  var k = 0;
  for (var i = 0; i < l.numBlocks; i++) {
    final len = l.shortDataLen + (i < l.numShort ? 0 : 1);
    final dat = data.sublist(k, k + len);
    k += len;
    blocks.add([...dat, if (i < l.numShort) 0, ..._eccFor(dat, l.eccLen)]);
  }
  final out = <int>[];
  for (var i = 0; i < blocks[0].length; i++) {
    for (var j = 0; j < blocks.length; j++) {
      if (i != l.shortDataLen || j >= l.numShort) out.add(blocks[j][i]);
    }
  }
  return out;
}

List<int>? _deinterleaveAndCorrect(List<int> raw, int ver, _Ecl ecl) {
  final l = _blockLayout(ver, ecl);
  final width = l.shortDataLen + 1 + l.eccLen;
  final blocks = List.generate(l.numBlocks, (_) => List<int>.filled(width, 0, growable: true));
  var k = 0;
  for (var i = 0; i < width; i++) {
    for (var j = 0; j < l.numBlocks; j++) {
      if (i != l.shortDataLen || j >= l.numShort) blocks[j][i] = raw[k++];
    }
  }
  final out = <int>[];
  for (var j = 0; j < l.numBlocks; j++) {
    final block = blocks[j];
    if (j < l.numShort) block.removeAt(l.shortDataLen);
    if (!_correct(block, l.eccLen)) return null;
    out.addAll(block.sublist(0, block.length - l.eccLen));
  }
  return out;
}

/// Исправляет ошибки в блоке [msg] (данные и [nsym] байт коррекции, от старшего коэффициента) на месте.
/// false — ошибок больше, чем можно исправить.
bool _correct(List<int> msg, int nsym) {
  final n = msg.length;
  int eval(int x) {
    var y = 0;
    for (final c in msg) {
      y = _mul(y, x) ^ c;
    }
    return y;
  }

  final synd = [for (var i = 0; i < nsym; i++) eval(_exp[i])];
  if (synd.every((s) => s == 0)) return true;
  // Берлекэмп — Мэсси: многочлен локаторов ошибок Λ(x), коэффициенты от младшего.
  var c = <int>[1], b = <int>[1];
  var len = 0, m = 1, bb = 1;
  for (var i = 0; i < nsym; i++) {
    var d = synd[i];
    for (var j = 1; j <= len && j < c.length; j++) {
      d ^= _mul(c[j], synd[i - j]);
    }
    if (d == 0) {
      m++;
      continue;
    }
    final coef = _div(d, bb);
    final next = List<int>.filled(math.max(c.length, b.length + m), 0);
    for (var j = 0; j < c.length; j++) {
      next[j] = c[j];
    }
    for (var j = 0; j < b.length; j++) {
      next[j + m] ^= _mul(coef, b[j]);
    }
    if (2 * len <= i) {
      b = c;
      len = i + 1 - len;
      bb = d;
      m = 1;
    } else {
      m++;
    }
    c = next;
  }
  if (2 * len > nsym) return false;
  int evalLow(List<int> p, int x) {
    var y = 0;
    for (var j = p.length - 1; j >= 0; j--) {
      y = _mul(y, x) ^ p[j];
    }
    return y;
  }

  // Поиск корней (Ченя): ошибка в байте k, если Λ(X⁻¹) = 0, где X = α^(n − 1 − k).
  final positions = <int>[];
  for (var k = 0; k < n; k++) {
    final xInv = _exp[(255 - (n - 1 - k) % 255) % 255];
    if (evalLow(c, xInv) == 0) positions.add(k);
  }
  if (positions.length != len) return false;
  // Форни: Ω(x) = S(x)Λ(x) mod x^nsym, величина e = X·Ω(X⁻¹) / Λ'(X⁻¹).
  final omega = List<int>.filled(nsym, 0);
  for (var i = 0; i < nsym; i++) {
    for (var j = 0; j < c.length && i + j < nsym; j++) {
      omega[i + j] ^= _mul(synd[i], c[j]);
    }
  }
  final deriv = [for (var j = 1; j < c.length; j++) j.isOdd ? c[j] : 0];
  for (final k in positions) {
    final x = _exp[(n - 1 - k) % 255];
    final xInv = _exp[(255 - (n - 1 - k) % 255) % 255];
    final denom = evalLow(deriv, xInv);
    if (denom == 0) return false;
    msg[k] ^= _mul(x, _div(evalLow(omega, xInv), denom));
  }
  for (var i = 0; i < nsym; i++) {
    if (eval(_exp[i]) != 0) return false;
  }
  return true;
}

class _Bits {
  final _list = <bool>[];
  int get length => _list.length;

  void add(int value, int count) {
    for (var i = count - 1; i >= 0; i--) {
      _list.add((value >> i) & 1 == 1);
    }
  }

  List<int> bytes() {
    final out = List<int>.filled(_list.length ~/ 8, 0, growable: true);
    for (var i = 0; i < out.length * 8; i++) {
      if (_list[i]) out[i >> 3] |= 1 << (7 - (i & 7));
    }
    return out;
  }
}

class _BitReader {
  _BitReader(this.data);
  final List<int> data;
  var _pos = 0;

  int get left => data.length * 8 - _pos;

  int read(int count) {
    var v = 0;
    for (var i = 0; i < count; i++) {
      final p = _pos++;
      final bit = p < data.length * 8 ? (data[p >> 3] >> (7 - (p & 7))) & 1 : 0;
      v = v << 1 | bit;
    }
    return v;
  }
}
