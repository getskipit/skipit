import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/screen_privacy.dart';

void main() {
  test('hides URLs and IPv4 and IPv6 without changing normal labels', () {
    final text = 'EU node 203.0.113.7:443 https://panel.example/sub/key [2001:db8::1]';
    final result = hideScreenAddresses(text);
    expect(result, 'EU node […]:443 […] […]');
    final editable = hideScreenAddresses(text, preserveLength: true);
    expect(editable.length, text.length);
    expect(editable, contains('EU node '));
    expect(editable, isNot(contains('203.0.113.7')));
    expect(editable, isNot(contains('panel.example')));
    expect(editable, isNot(contains('2001:db8::1')));
    expect(hideScreenAddresses('IP 203.0.113.7. next'), 'IP […]. next');
    expect(hideScreenAddresses('Version 1.1.8, VPN active'), 'Version 1.1.8, VPN active');
    for (final address in ['203.0.113.1', '2001:db8::5', '::1', 'fe80::12%4', '::ffff:203.0.113.9']) {
      for (final wrapper in ['($address)', '[$address]:443', 'ip=$address,']) {
        expect(hideScreenAddresses(wrapper), isNot(contains(address)), reason: wrapper);
      }
    }
    for (final url in ['vless://key@example.com:443', 'https://example.com/token?q=secret', 'ss://abc']) {
      expect(hideScreenAddresses('Link: $url'), isNot(contains(url)));
    }
  });
}
