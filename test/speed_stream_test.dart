import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/speed_test.dart';

class TestSocket extends Fake implements RawSocket, RawSecureSocket {
  final events = StreamController<RawSocketEvent>();
  var reads = 0;
  var closed = false;

  @override
  Uint8List? read([int? len]) {
    reads++;
    if (reads == 1) {
      return Uint8List.fromList(ascii.encode('HTTP/1.1 200 OK\r\nContent-Length: 65536\r\n\r\n'));
    }
    return reads <= 500 ? Uint8List(8192) : null;
  }

  @override
  int write(List<int> buffer, [int offset = 0, int? count]) {
    Timer.run(() { if (!closed) events.add(RawSocketEvent.read); });
    return count ?? buffer.length - offset;
  }

  @override
  StreamSubscription<RawSocketEvent> listen(void Function(RawSocketEvent)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      events.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  Future<TestSocket> close() async {
    if (!closed) { closed = true; await events.close(); }
    return this;
  }
}

void main() {
  const server = (host: 'speed.example', path: '/sample');
  test('busy download yields after a bounded number of reads', () async {
    final sockets = <TestSocket>[];
    final result = await SpeedTest.measureForTest(server, () async {
      final socket = TestSocket();
      sockets.add(socket);
      return (raw: socket, tls: socket);
    });
    expect(result.error, isNull);
    expect(result.mbit, isNotNull);
    expect(sockets, hasLength(SpeedTest.streams));
    expect(sockets.every((s) => s.reads <= 16), isTrue);
    expect(sockets.every((s) => s.closed), isTrue);
  });

  test('one stalled connection does not delay the other streams indefinitely', () async {
    final lateLink = Completer<({RawSocket raw, RawSecureSocket tls})>();
    var opening = 0;
    final result = await SpeedTest.measureForTest(server, () async {
      if (opening++ == 0) return lateLink.future;
      final socket = TestSocket();
      return (raw: socket, tls: socket);
    }, openTimeout: const Duration(milliseconds: 30));
    expect(result.error, isNull);
    final socket = TestSocket();
    lateLink.complete((raw: socket, tls: socket));
    await Future<void>.delayed(Duration.zero);
    expect(socket.closed, isTrue);
  });

  test('cancelled measurement does not open connections or try another server', () async {
    var opens = 0;
    final result = await SpeedTest.measureForTest(server, () async {
      opens++;
      final socket = TestSocket();
      return (raw: socket, tls: socket);
    }, keepGoing: () => false);
    expect(opens, 0);
    expect(result.unreachable, isFalse);
    expect(result.error, isNotNull);
  });
}
