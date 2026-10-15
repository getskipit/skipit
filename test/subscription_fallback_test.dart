import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/models/subscription.dart';
import 'package:skipit/state/app_state.dart';

/// Запасной адрес подписки (`fallback-url` от провайдера): запоминается из заголовка или из строки
/// `#fallback-url:` в теле и выручает, когда основной адрес отвечает ошибкой.
void main() {
  test('основной адрес отвечает ошибкой — подписка обновляется с запасного', () async {
    await AppPaths.init();
    final tmp = await Directory.systemTemp.createTemp('skipit-fallback');
    AppPaths.dataDir = tmp;

    final spare = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    spare.listen((r) => r.response
      ..write('trojan://pw@b.example:443#Spare')
      ..close());
    var mainDown = false;
    final main = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    main.listen((r) {
      if (mainDown) {
        r.response.statusCode = 503;
      } else {
        r.response
          ..headers.set('fallback-url', 'http://127.0.0.1:${spare.port}/sub')
          ..write('trojan://pw@a.example:443#Main');
      }
      r.response.close();
    });

    final state = AppState();
    final sub = Subscription(url: 'http://127.0.0.1:${main.port}/sub');
    state.subscriptions.add(sub);
    await state.updateSubscription(sub, silent: true);
    expect(sub.error, isNull);
    expect(sub.fallbackUrl, 'http://127.0.0.1:${spare.port}/sub');
    expect(state.serversOf(sub.id).single.name, 'Main');
    // Запасной адрес переживает перезапуск программы.
    expect(Subscription.fromJson(sub.toJson()).fallbackUrl, sub.fallbackUrl);

    mainDown = true;
    await state.updateSubscription(sub, silent: true);
    expect(sub.error, isNull);
    expect(state.serversOf(sub.id).single.name, 'Spare');
    // Основным адресом подписки остаётся прежний: запасной только выручает.
    expect(sub.url, 'http://127.0.0.1:${main.port}/sub');

    await main.close(force: true);
    await spare.close(force: true);
    await tmp.delete(recursive: true);
  });

  test('запасной адрес из тела подписки; принимаются только http и https', () {
    final sub = Subscription(url: 'https://a.example/sub');
    sub.applyMeta({'fallback-url': 'tg://resolve?domain=x'});
    expect(sub.fallbackUrl, isNull);
    sub.applyMeta({'fallback-url': ' https://b.example/sub '});
    expect(sub.fallbackUrl, 'https://b.example/sub');
    // Провайдер перестал присылать заголовок — запомненный адрес остаётся.
    sub.applyMeta(const {});
    expect(sub.fallbackUrl, 'https://b.example/sub');
  });
}
