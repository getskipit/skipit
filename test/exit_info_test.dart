import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/net.dart';

/// Ответ cdn-cgi/trace: страна выхода и внешний IP для главной.
void main() {
  test('страна и внешний IP из ответа Cloudflare', () {
    const body = 'fl=1f1\nh=www.cloudflare.com\nip=203.0.113.7\nts=1.2\nvisit_scheme=https\nloc=DE\ntls=TLSv1.3\n';
    expect(Net.parseTrace(body), (country: 'de', ip: '203.0.113.7'));
    expect(Net.parseTrace('ip=2001:db8::5\r\nloc=FI\r\n'), (country: 'fi', ip: '2001:db8::5'));
    // Что не похоже на адрес — не показываем.
    expect(Net.parseTrace('ip=999.1.1.1\nloc=XX\n'), (country: 'xx', ip: null));
    expect(Net.parseTrace(''), (country: null, ip: null));
  });
}
