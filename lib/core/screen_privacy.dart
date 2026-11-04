import 'dart:io';

final _screenUrl = RegExp(r'\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s<>"\x27]+');
final _screenIpv4 = RegExp(r'(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?!\d)');
final _screenIpv6 = RegExp(r'(?<![\w:])\[?[0-9a-fA-F:]*:[0-9a-fA-F:.]+\]?(?![\w:])');

/// Скрывает ссылки и IP в произвольной строке, не изменяя исходные данные.
String hideScreenAddresses(String text, {bool preserveLength = false}) {
  String mask(String value) => preserveLength ? '•' * value.length : '[…]';
  text = text.replaceAllMapped(_screenUrl, (m) => mask(m[0]!));
  text = text.replaceAllMapped(RegExp(r'\[([0-9a-fA-F:.%]+)\]'), (m) {
    final candidate = m[1]!.split('%').first;
    return InternetAddress.tryParse(candidate)?.type == InternetAddressType.IPv6 ? mask(m[0]!) : m[0]!;
  });
  text = text.replaceAllMapped(_screenIpv4, (m) =>
      InternetAddress.tryParse(m[0]!)?.type == InternetAddressType.IPv4 ? mask(m[0]!) : m[0]!);
  return text.replaceAllMapped(_screenIpv6, (m) {
    final raw = m[0]!;
    final candidate = raw.startsWith('[') && raw.endsWith(']') ? raw.substring(1, raw.length - 1) : raw;
    return InternetAddress.tryParse(candidate)?.type == InternetAddressType.IPv6 ? mask(raw) : raw;
  });
}
