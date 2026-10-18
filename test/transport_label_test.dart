import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';

/// Подпись транспорта под сервером: TCP тоже называется (раньше пропускался как «обычный»).
void main() {
  test('подпись транспорта: tcp · reality, ws · tls', () {
    String label(String link) => LinkParser.parseText(link).servers.single.transportLabel;
    const uuid = '3b5a3c2e-8f6b-4c7e-9d1a-2f4e6a8c0b1d';
    expect(label('vless://$uuid@example.com:443?type=tcp&security=reality&pbk=x&sni=a.com#a'), 'tcp · reality');
    expect(label('vless://$uuid@example.com:443?type=ws&security=tls&sni=a.com&path=%2Fws#a'), 'ws · tls');
    expect(label('trojan://pw@example.com:443?security=tls&sni=a.com#a'), 'tcp · tls');
  });
}
