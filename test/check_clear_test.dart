import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/line_check.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/site_check.dart';
import 'package:skipit/state/app_state.dart';

/// «Очистить» у проверок раздела «Проверка»: прошлый результат убирается, а не висит до перезапуска.
void main() {
  test('«Очистить» убирает результат проверки и отметки UDP у серверов', () {
    final state = AppState();
    final servers = LinkParser.parseText('trojan://pw@a.example:443#A\ntrojan://pw@b.example:443#B').servers;
    state.servers.addAll(servers);
    servers[0].udpMs = 40;
    servers[1].udpMs = -1;
    state.udpChecked = servers;
    state.udpStamp = (at: DateTime.now(), server: '');
    state.siteReports = [SiteReport('a.example')];
    state.lineReport = LineReport();

    state.clearCheck(CheckKind.udp);
    expect(state.udpChecked, isEmpty);
    expect(state.udpStamp, isNull);
    expect(servers.map((s) => s.udpMs), [null, null]);
    // Другие проверки не трогаются.
    expect(state.siteReports, hasLength(1));
    expect(state.lineReport, isNotNull);

    state.clearCheck(CheckKind.site);
    state.clearCheck(CheckKind.line);
    expect(state.siteReports, isEmpty);
    expect(state.lineReport, isNull);

    // Пока идёт проверка, её результат не стирается.
    state.lineReport = LineReport();
    state.checkingLine = true;
    state.clearCheck(CheckKind.line);
    expect(state.lineReport, isNotNull);
  });
}
