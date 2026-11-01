import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/rule_list.dart';

void main() {
  group('RuleList.parse', () {
    test('обычный текст: домены, *. в начале, IP и CIDR', () {
      final r = RuleList.parse('example.com\n# коммент\n*.test.example\n203.0.113.5\n198.51.100.0/24');
      expect(r.domains, ['domain:example.com', 'domain:test.example']);
      expect(r.ips, ['203.0.113.5', '198.51.100.0/24']);
      expect(r.skipped, 0);
      expect(r.overLimit, isFalse);
    });

    test('известные префиксы проходят как есть; geoip: — в IP', () {
      final r = RuleList.parse('full:api.example.com\ngeosite:category-ru\ngeoip:ru\n2001:db8::/32');
      expect(r.domains, ['full:api.example.com', 'geosite:category-ru']);
      expect(r.ips, ['geoip:ru', '2001:db8::/32']);
      expect(r.skipped, 0);
    });

    test('мусор отбрасывается со счётчиком', () {
      final r = RuleList.parse('ext:foo\nC:\\temp\\x\n..\\secret\nplain words with spaces');
      expect(r.domains, isEmpty);
      expect(r.ips, isEmpty);
      expect(r.skipped, 4);
    });

    test('mihomo YAML payload', () {
      final r = RuleList.parse('payload:\n'
          '  - DOMAIN-SUFFIX,example.com\n'
          '  - DOMAIN,api.example.com\n'
          '  - DOMAIN-KEYWORD,bad\n'
          '  - DOMAIN-REGEX,^x\n'
          '  - IP-CIDR,203.0.113.0/24\n'
          '  - GEOIP,ru\n'
          '  - GEOSITE,youtube\n'
          '  - SRC-IP-CIDR,10.0.0.0/8\n'
          '  - DST-PORT,25');
      expect(r.domains, [
        'domain:example.com',
        'full:api.example.com',
        'geosite:youtube',
      ]);
      expect(r.ips, ['203.0.113.0/24', 'geoip:ru']);
      expect(r.skipped, 4);
    });

    test('лимит строк: overLimit', () {
      final r = RuleList.parse(List.filled(RuleList.maxLines + 1, 'x.example.com').join('\n'));
      expect(r.overLimit, isTrue);
    });

    test('префикс с путём в значении отбрасывается: домены — доменные правила, geo — безопасные имена', () {
      final r = RuleList.parse('domain:C:/temp/x\n'
          'domain:/abs/path\n'
          'full:C:/temp/x\n'
          'geosite:C:/temp/x\n'
          'geosite:../secret\n'
          'geoip:..');
      expect(r.domains, isEmpty);
      expect(r.ips, isEmpty);
      expect(r.skipped, 6);
    });

    test('mihomo GEOSITE/GEOIP с путём отбрасываются', () {
      final r = RuleList.parse('payload:\n'
          '  - GEOSITE,../secret\n'
          '  - GEOSITE,C:/temp/x\n'
          '  - GEOIP,..\n'
          '  - GEOIP,C:\n'
          '  - GEOSITE,category-ads-all\n'
          '  - GEOIP,ru');
      expect(r.domains, ['geosite:category-ads-all']);
      expect(r.ips, ['geoip:ru']);
      expect(r.skipped, 4);
    });
  });
}
