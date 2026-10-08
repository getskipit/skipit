import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

final _random = Random();

/// Сервер ответил, но отказом (код 4xx или 5xx). От «сервер недоступен» отличается тем, что
/// повторять запрос другим путём бессмысленно: он дошёл.
class ServerRefused implements Exception {
  ServerRefused(this.status);
  final int status;

  /// Что это значит для подписки — простыми словами.
  String get reason => switch (status) {
        402 => 'сервер сообщает, что подписка не оплачена или закончилась (код 402)',
        401 || 403 => 'сервер отказал в доступе (код $status): ссылка больше не действует '
            'или превышено число устройств',
        404 || 410 => 'подписка не найдена (код $status): ссылка больше не действует',
        429 => 'сервер просит подождать: слишком много запросов (код 429)',
        >= 500 => 'сервер подписки сейчас не работает (код $status)',
        _ => 'сервер ответил отказом (код $status)',
      };

  /// Отказ окончательный: сервер работает и ответил по существу (в отличие от сбоя 5xx).
  bool get isFinal => status < 500 && status != 429;

  @override
  String toString() => 'Сервер ответил $status';
}

/// Слово в нужной форме после числа: `plural(3, 'раз', 'раза', 'раз')` → «раза».
/// [one] — для 1, 21, 31…; [few] — для 2–4, 22–24…; [many] — для остальных.
String plural(int n, String one, String few, String many) {
  final d = n.abs() % 100;
  if (d >= 11 && d <= 14) return many;
  return switch (d % 10) { 1 => one, 2 || 3 || 4 => few, _ => many };
}

/// Понятное описание сетевой ошибки для пользователя (подробности остаются в журнале).
String describeNetError(Object e) {
  if (e is ServerRefused) return '${e.reason[0].toUpperCase()}${e.reason.substring(1)}';
  if (e is TimeoutException) return 'Сервер не ответил вовремя';
  if (e is SocketException) {
    // 10013 / 10057 — Windows не дала открыть соединение: так выглядит блокировка файрволом
    // (например, simplewall ещё не разрешил новый файл программы).
    final code = e.osError?.errorCode;
    if (code == 10013 || code == 10057) {
      return 'Соединение заблокировано. Если установлен файрвол или антивирус — разрешите в нём SkipIt';
    }
    return 'Нет соединения с сервером — проверьте интернет';
  }
  if (e is HandshakeException) return 'Не удалось установить защищённое соединение с сервером';
  return scrubUrls(e.toString().replaceFirst(RegExp(r'^(Http)?Exception: '), ''));
}

/// Оставляет от адресов в тексте только имя сервера. В ссылке на подписку путь и параметры — это ключ
/// доступа к VPN, а сетевые ошибки печатают адрес целиком («…, uri = https://…/sub/КЛЮЧ»): в журнал
/// на диске и в окно такой текст попадать не должен.
String scrubUrls(String text) => text.replaceAllMapped(
      RegExp(r'(https?://)([^/\s,;)]+)[^\s,;)]*', caseSensitive: false),
      (m) => '${m[1]}${m[2]!.split('@').last}/…',
    );
/// Случайный пароль для локальных входов ядра: 32 шестнадцатеричных знака.
String randomSecret() {
  final random = Random.secure();
  return [for (var i = 0; i < 16; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}

/// Случайный пароль локальных портов: 24 знака — заглавные и строчные буквы, цифры и знаки «-+_.»,
/// каждого вида хотя бы по одному. Знаков вроде «@», «:», «/» нет: они ломают адрес прокси.
String randomPassword() {
  const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ', lower = 'abcdefghijkmnopqrstuvwxyz', digits = '23456789', signs = '-+_.';
  const all = '$upper$lower$digits$signs';
  final random = Random.secure();
  while (true) {
    final password = [for (var i = 0; i < 24; i++) all[random.nextInt(all.length)]].join();
    if ([upper, lower, digits, signs].every((kind) => password.split('').any(kind.contains))) return password;
  }
}

String newId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
    '${_random.nextInt(0x7fffffff).toRadixString(36)}';

/// Декодирует base64 / base64url с отсутствующим паддингом. null — если это не base64.
String? tryBase64Decode(String input) {
  var s = input.trim().replaceAll(RegExp(r'\s'), '');
  if (s.isEmpty) return null;
  s = s.replaceAll('-', '+').replaceAll('_', '/').replaceAll('=', '');
  final rem = s.length % 4;
  if (rem == 1) return null;
  if (rem > 0) s = s.padRight(s.length + 4 - rem, '=');
  try {
    return utf8.decode(base64.decode(s));
  } catch (_) {
    return null;
  }
}

/// Значения заголовков подписок могут приходить как `base64:....`.
String decodeMaybeBase64Prefixed(String value) {
  final v = value.trim();
  if (v.toLowerCase().startsWith('base64:')) {
    return tryBase64Decode(v.substring(7)) ?? v;
  }
  return v;
}

String urlDecode(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

bool parseBool(Object? value, [bool fallback = false]) {
  if (value == null) return fallback;
  if (value is bool) return value;
  switch (value.toString().trim().toLowerCase()) {
    case 'true' || '1' || 'yes' || 'on':
      return true;
    case 'false' || '0' || 'no' || 'off':
      return false;
  }
  return fallback;
}

int? asInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return num.tryParse(value.toString().trim())?.toInt();
}

List<String> splitLines(String text) => text
    .split(RegExp(r'[\r\n]+'))
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toList();

Map<String, dynamic> deepCopyMap(Map<String, dynamic> map) =>
    jsonDecode(jsonEncode(map)) as Map<String, dynamic>;

String formatBytes(num bytes) {
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 ? 0 : (value < 10 ? 2 : 1);
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

String formatSpeed(num bytesPerSecond) => '${formatBytes(bytesPerSecond)}/с';

String _two(int n) => n.toString().padLeft(2, '0');

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '$h:${_two(m)}:${_two(s)}' : '${_two(m)}:${_two(s)}';
}

String formatDate(DateTime d) => '${_two(d.day)}.${_two(d.month)}.${d.year}';

String formatDateTime(DateTime d) =>
    '${formatDate(d)} ${_two(d.hour)}:${_two(d.minute)}';
