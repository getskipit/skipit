import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/windows.dart';

/// Свой порт в системном прокси не запоминается как «прежний», а мёртвый локальный прокси выключается.
void main() {
  test('порт локального системного прокси', () {
    expect(WinSys.localProxyPort(SystemProxyState(enabled: true, server: '127.0.0.1:10809')), 10809);
    expect(WinSys.localProxyPort(SystemProxyState(enabled: true, server: 'http=localhost:8080')), 8080);
    expect(WinSys.localProxyPort(SystemProxyState(enabled: false, server: '127.0.0.1:10809')), isNull);
    expect(WinSys.localProxyPort(SystemProxyState(enabled: true, server: 'proxy.example:3128')), isNull);
  });
}
