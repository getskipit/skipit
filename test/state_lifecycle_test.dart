import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/rule_list.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';
import 'package:skipit/models/subscription.dart';

class DelayedSaveState extends AppState {
  final started = Completer<void>();
  final release = Completer<void>();
  var writes = 0;
  var active = 0;
  var maxActive = 0;
  bool failFirst = false;

  @override
  Future<void> writeStateFile(File file, String text) async {
    active++;
    if (active > maxActive) maxActive = active;
    final first = writes++ == 0;
    try {
      if (first) {
        started.complete();
        await release.future;
        if (failFirst) throw StateError('simulated write failure');
      }
      await super.writeStateFile(file, text);
    } finally {
      active--;
    }
  }
}

class PreparingState extends AppState {
  final preparing = Completer<void>();
  final releasePreparation = Completer<RuleListEntries>();

  @override
  Future<RuleListEntries> prepareConnectGeoAndLists(RoutingProfile routing, Map<String, dynamic>? provider) {
    preparing.complete();
    return releasePreparation.future;
  }
}

class RetryState extends AppState {
  var connectionAttempts = 0;

  @override
  Future<void> disconnect({bool keepError = false, bool hold = false, bool hung = false}) async {
    status = ConnStatus.disconnected;
  }

  @override
  Future<void> connect({bool ignoreOtherVpn = false}) async {
    connectionAttempts++;
  }
}

void main() {

  late Directory dir;
  setUp(() async {
    await AppPaths.init();
    dir = await Directory.systemTemp.createTemp('skipit-lifecycle');
    AppPaths.dataDir = dir;
  });
  tearDown(() async => dir.delete(recursive: true));

  test('overlapping saves preserve the latest settings and use one writer', () async {
    final state = DelayedSaveState()..protectState = (bytes) => bytes;
    addTearDown(state.dispose);
    state.settings.mtu = 1300;
    final first = state.saveNow();
    await state.started.future;
    state.settings.mtu = 1400;
    final second = state.saveNow();
    state.settings.mtu = 1500;
    final third = state.saveNow();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    state.release.complete();
    expect(await Future.wait([first, second, third]), everyElement(isNull));
    final data = jsonDecode(await File(AppPaths.stateFile).readAsString()) as Map;
    expect((data['settings'] as Map)['mtu'], 1500);
    expect(state.maxActive, 1);
    expect(File(AppPaths.stateFile + '.tmp').existsSync(), isFalse);
  });

  test('failed save does not block later saves', () async {
    final state = DelayedSaveState()..failFirst = true;
    state.protectState = (bytes) => bytes;
    addTearDown(state.dispose);
    final first = state.saveNow();
    final failure = expectLater(first, throwsStateError);
    await state.started.future;
    state.settings.mtu = 1400;
    final second = state.saveNow();
    state.release.complete();
    await failure;
    expect(await second, isNull);
    final data = jsonDecode(await File(AppPaths.stateFile).readAsString()) as Map;
    expect((data['settings'] as Map)['mtu'], 1400);
  });

  for (final fails in [false, true]) {
    test('old link response ignored after reusing proxy port: failure=$fails', () async {
      final state = AppState()..settings.notifications = false;
      addTearDown(state.dispose);
      final old = Completer<({String? country, String? ip})>();
      final current = Completer<({String? country, String? ip})>();
      var requests = 0;
      state.readExitInfo = (_, __) => requests++ == 0 ? old.future : current.future;
      state.startLinkCheckForTest(12345);
      final pending = state.checkLinkForTest();
      state.startLinkCheckForTest(12345);
      state.linkFailsForTest = 1;
      await state.checkLinkForTest();
      if (fails) { old.completeError(const SocketException('old connection')); }
      else { old.complete((country: 'aa', ip: '203.0.113.1')); }
      await pending;
      expect(state.exitIp, isNull);
      expect(state.linkDown, isFalse);
      expect(requests, 2);
      current.complete((country: 'bb', ip: '203.0.113.2'));
      await Future<void>.delayed(Duration.zero);
      expect(state.exitIp, '203.0.113.2');
      expect(state.linkDown, isFalse);
    });
  }

  test('disposed state cancels debounced save and ignores late link result', () async {
    final state = AppState()..protectState = (bytes) => bytes;
    final reply = Completer<({String? country, String? ip})>();
    state.readExitInfo = (_, __) => reply.future;
    state.startLinkCheckForTest(12345);
    final pending = state.checkLinkForTest();
    state.save();
    state.dispose();
    reply.complete((country: 'aa', ip: '203.0.113.1'));
    await pending;
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(state.exitIp, isNull);
    expect(File(AppPaths.stateFile).existsSync(), isFalse);
  });

  test('shutdown waits for queued saves and persists the final settings', () async {
    final state = DelayedSaveState()..protectState = (bytes) => bytes;
    addTearDown(state.dispose);
    state.settings.mtu = 1300;
    final saving = state.saveNow();
    await state.started.future;
    state.settings.mtu = 1500;
    var stopped = false;
    final closing = state.shutdown().then((_) => stopped = true);
    await Future<void>.delayed(Duration.zero);
    expect(stopped, isFalse);
    state.release.complete();
    await saving;
    await closing;
    final data = jsonDecode(await File(AppPaths.stateFile).readAsString()) as Map;
    expect((data['settings'] as Map)['mtu'], 1500);
    expect(state.maxActive, 1);
    final before = state.writes;
    state.save();
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(state.writes, before);
  });

  test('shutdown joins connection cancellation before returning', () async {
    final state = PreparingState()..protectState = (bytes) => bytes;
    addTearDown(state.dispose);
    state.settings.mode = ConnectionMode.proxyOnly;
    state.routingProfiles.add(RoutingProfile.global());
    final server = LinkParser.parseText('trojan://password@server.example:443#Example').servers.single;
    state.servers.add(server);
    state.settings.selectedServerId = server.id;
    final connecting = state.connect();
    await state.preparing.future.timeout(const Duration(seconds: 3));
    var stopped = false;
    final closing = state.shutdown().then((_) => stopped = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(stopped, isFalse);
    state.releasePreparation.complete(RuleListEntries());
    await connecting;
    await closing;
    expect(state.status, ConnStatus.disconnected);
    expect(state.settings.lastXrayPid, isNull);
    expect(state.settings.systemProxyActive, isFalse);
    final count = state.log.lines.length;
    await state.connect();
    await state.reconnect();
    state.requestConnect();
    expect(state.status, ConnStatus.disconnected);
    expect(state.connectRequested, isFalse);
    expect(state.log.lines.length, count);
  });

  for (final fails in [false, true]) {
    test('subscription reply after shutdown is discarded: failure=$fails', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final arrived = Completer<HttpRequest>();
      var requests = 0;
      server.listen((request) {
        requests++;
        if (!arrived.isCompleted) { arrived.complete(request); }
        else { request.response..statusCode = 503..close(); }
      });
      final state = AppState()..protectState = (bytes) => bytes;
      state.settings.preferJson = true;
      final sub = Subscription(url: 'http://127.0.0.1:${server.port}/sub');
      sub.fallbackUrl = 'http://127.0.0.1:${server.port}/spare';
      state.subscriptions.add(sub);
      try {
        final updating = state.updateSubscription(sub);
        final request = await arrived.future.timeout(const Duration(seconds: 3));
        await state.shutdown();
        final saved = await File(AppPaths.stateFile).readAsString();
        state.dispose();
        if (fails) {
          request.response.statusCode = 503;
        } else {
          request.response.write('trojan://password@server.example:443#Example');
        }
        await request.response.close();
        await updating;
        expect(requests, 1);
        expect(sub.lastUpdated, isNull);
        expect(sub.error, isNull);
        expect(state.servers, isEmpty);
        expect(state.updatingSubs, isEmpty);
        expect(await File(AppPaths.stateFile).readAsString(), saved);
      } finally {
        await server.close(force: true);
      }
    });
  }

  test('shutdown cancels delayed recovery after a core crash', () async {
    final state = RetryState()..protectState = (bytes) => bytes;
    addTearDown(state.dispose);
    state.settings.notifications = false;
    state.settings.autoReconnect = true;
    state.status = ConnStatus.connected;
    state.connectedAt = DateTime.now().subtract(const Duration(minutes: 1));
    state.coreCrashForTest(1);
    await Future<void>.delayed(Duration.zero);
    final firstClose = state.shutdown();
    expect(identical(firstClose, state.shutdown()), isTrue);
    await firstClose;
    await Future<void>.delayed(const Duration(milliseconds: 3100));
    expect(state.connectionAttempts, 0);
    expect(state.status, ConnStatus.disconnected);
  });
}