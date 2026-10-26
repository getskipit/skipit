import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'paths.dart';

/// Связь со службой SkipIt (windows\service\service.cpp) по именованному каналу.
///
/// Служба работает с правами системы, поэтому перед отправкой команды проверяем, что на том конце
/// канала именно её процесс: номер процесса службы сообщает диспетчер служб Windows, а номер
/// процесса-владельца канала — сам канал. Иначе другая программа могла бы занять имя канала раньше
/// службы и получать то, что программа ей отправляет (в том числе конфиг с ключами серверов).
class ServiceClient {
  /// Имя службы и её канала; у тестовой сборки — своя служба.
  static String get name => AppPaths.isDev ? 'SkipItDev' : 'SkipIt';

  /// Версия протокола, с которой умеет работать программа.
  static const protocol = 'skipit-service 4';

  /// Версия протокола службы («skipit-service 4») или null, если служба не установлена, не запущена
  /// или не отвечает.
  static Future<String?> hello({String? serviceName}) {
    final target = serviceName ?? name;
    return Isolate.run(() => _request(target, 'hello'));
  }

  /// Остановить ядро, которое запустила служба.
  static Future<void> stop(int pid) => command('stop $pid');

  /// Служба копирует скачанный установщик [path] в папку программы (туда без прав не записать) и сверяет
  /// копию с контрольной суммой [sha256]. Возвращает путь к копии; ошибка — с причиной от службы.
  static Future<String> stageUpdate(String path, String sha256) async {
    final reply = await command('update stage\n$path\n$sha256').timeout(const Duration(minutes: 2));
    if (reply != null && reply.startsWith('ok ')) return reply.substring(3);
    throw Exception(reply != null && reply.startsWith('error ')
        ? 'Служба SkipIt не приняла установщик: ${reply.substring(6)}'
        : 'Служба SkipIt не ответила');
  }

  /// Одна команда службе — её ответ или null.
  static Future<String?> command(String request) {
    final target = name;
    return Isolate.run(() => _request(target, request));
  }

  /// Команда, после которой служба держит подключение (Kill Switch): первый ответ приходит сразу,
  /// а подключение остаётся открытым в фоновом потоке, пока служба его не отпустит или программа не
  /// закроется. null — службы нет или она не ответила.
  static Future<String?> hold(String request) async {
    final port = ReceivePort();
    final first = Completer<String?>();
    port.listen((m) {
      if (!first.isCompleted) {
        first.complete(m as String?);
        if (m != 'ok') port.close();
      } else {
        port.close();
      }
    });
    await Isolate.spawn(_hold, [port.sendPort, name, request]);
    return first.future;
  }

  static void _hold(List args) {
    final out = args[0] as SendPort;
    final pipe = _Pipe.connect(args[1] as String);
    if (pipe == null) {
      out.send(null);
      return;
    }
    try {
      if (!pipe.write(utf8.encode(args[2] as String))) {
        out.send(null);
        return;
      }
      final reply = pipe.read();
      out.send(reply == null ? null : utf8.decode(reply, allowMalformed: true));
      // Ждём, пока служба не отпустит подключение («released») или оно не оборвётся.
      if (reply != null) pipe.read();
      out.send('end');
    } finally {
      pipe.close();
    }
  }

  /// Одна команда — один ответ. null — ответа нет (службы нет, она чужая или отказала).
  static String? _request(String serviceName, String command) {
    final pipe = _Pipe.connect(serviceName);
    if (pipe == null) return null;
    try {
      if (!pipe.write(utf8.encode(command))) return null;
      final reply = pipe.read();
      return reply == null ? null : utf8.decode(reply, allowMalformed: true);
    } finally {
      pipe.close();
    }
  }
}

/// Ядро, запущенное службой: режимы с адаптером без прав администратора у самой программы.
/// Подключение к службе держится, пока живёт ядро; закрылось оно (программа упала) — служба
/// останавливает ядро сама.
class ServiceCore {
  ServiceCore._(this.pid);

  final int pid;

  /// Запускает ядро [core] («xray» или «sing-box») с конфигом [config] (идёт на стандартный вход
  /// ядра; [assets] — папка гео-баз для Xray). [onOutput] — куски вывода ядра, [onExit] — код выхода.
  /// Отказ службы — исключение [ServiceException] с её текстом.
  static Future<ServiceCore> start({
    required String core,
    required String assets,
    required String config,
    required void Function(List<int> chunk) onOutput,
    required void Function(int code) onExit,
  }) async {
    final port = ReceivePort();
    final started = Completer<int>();
    var exited = false;
    void finish(int code) {
      if (exited) return;
      exited = true;
      port.close();
      onExit(code);
    }

    port.listen((m) {
      final msg = m as List;
      switch (msg[0]) {
        case 'started':
          started.complete(msg[1] as int);
        case 'error':
          if (!started.isCompleted) started.completeError(ServiceException(msg[1] as String));
          port.close();
        case 'o':
          onOutput(msg[1] as Uint8List);
        case 'x':
          finish(msg[1] as int);
        case 'gone':
          if (!started.isCompleted) {
            started.completeError(ServiceException('служба SkipIt не отвечает'));
            port.close();
          } else {
            finish(-1);
          }
      }
    });
    final request = BytesBuilder(copy: false)
      ..add(utf8.encode('start\n$core\n$assets\n'))
      ..add(utf8.encode(config));
    await Isolate.spawn(_stream, [port.sendPort, ServiceClient.name, request.takeBytes()]);
    return ServiceCore._(await started.future);
  }

  /// Остановить ядро; [onExit] придёт, когда служба сообщит код выхода.
  Future<void> stop() => ServiceClient.stop(pid);

  /// Фоновый поток: держит подключение к службе и пересылает вывод ядра.
  static void _stream(List args) {
    final out = args[0] as SendPort;
    final pipe = _Pipe.connect(args[1] as String);
    if (pipe == null) {
      out.send(['gone']);
      return;
    }
    try {
      if (!pipe.write(args[2] as Uint8List)) {
        out.send(['gone']);
        return;
      }
      final first = pipe.read();
      if (first == null) {
        out.send(['gone']);
        return;
      }
      final reply = utf8.decode(first, allowMalformed: true);
      if (!reply.startsWith('started ')) {
        out.send(['error', reply.startsWith('error ') ? reply.substring(6) : reply]);
        return;
      }
      out.send(['started', int.parse(reply.substring(8))]);
      while (true) {
        final m = pipe.read();
        if (m == null || m.isEmpty) {
          out.send(['gone']);
          return;
        }
        if (m[0] == 0x6F) {
          // «o…» — кусок вывода ядра.
          out.send(['o', Uint8List.sublistView(m, 1)]);
        } else if (m[0] == 0x78) {
          // «x<код>» — ядро завершилось.
          out.send(['x', int.tryParse(utf8.decode(m.sublist(1))) ?? -1]);
          return;
        }
      }
    } finally {
      pipe.close();
    }
  }
}

class ServiceException implements Exception {
  ServiceException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Подключение к каналу службы (только в фоновом потоке: чтение ждёт ответа).
class _Pipe {
  _Pipe._(this._h, this._k32, this._heap);

  final Pointer<Void> _h;
  final DynamicLibrary _k32;
  final _Heap _heap;

  /// Подключение к каналу службы [serviceName] с проверкой, что владелец канала — её процесс.
  static _Pipe? connect(String serviceName) {
    final pid = _servicePid(serviceName);
    if (pid == null) return null;
    final k32 = DynamicLibrary.open('kernel32.dll');
    final createFile = k32.lookupFunction<
        Pointer<Void> Function(Pointer<Uint16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, Pointer<Void>),
        Pointer<Void> Function(Pointer<Uint16>, int, int, Pointer<Void>, int, int, Pointer<Void>)>('CreateFileW');
    final setState = k32.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Uint32>, Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Uint32>, Pointer<Void>, Pointer<Void>)>('SetNamedPipeHandleState');
    final serverPid = k32.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Uint32>),
        int Function(Pointer<Void>, Pointer<Uint32>)>('GetNamedPipeServerProcessId');

    // Чтение, запись данных и смена режима канала — ровно то, что служба разрешает пользователям.
    const access = 0x12018B;
    const openExisting = 3;
    const pipeReadModeMessage = 2;
    final heap = _Heap(k32);
    final path = heap.wide('${r'\\.\pipe\'}$serviceName');
    final word = heap.alloc(4).cast<Uint32>();
    final h = createFile(path, access, 0, nullptr, openExisting, 0, nullptr);
    if (h.address == -1) {
      heap.freeAll();
      return null;
    }
    final pipe = _Pipe._(h, k32, heap);
    word.value = pipeReadModeMessage;
    if (setState(h, word, nullptr, nullptr) == 0 || serverPid(h, word) == 0 || word.value != pid) {
      pipe.close();
      return null;
    }
    return pipe;
  }

  bool write(Uint8List data) {
    final writeFile = _k32.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>('WriteFile');
    final buf = _heap.alloc(data.isEmpty ? 1 : data.length).cast<Uint8>();
    final n = _heap.alloc(4).cast<Uint32>();
    buf.asTypedList(data.length).setAll(0, data);
    final ok = writeFile(_h, buf, data.length, n, nullptr) != 0 && n.value == data.length;
    _heap.free(buf.cast());
    _heap.free(n.cast());
    return ok;
  }

  /// Одно сообщение целиком; null — канал закрыт.
  Uint8List? read() {
    final readFile = _k32.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>('ReadFile');
    const bufSize = 64 * 1024;
    final buf = _heap.alloc(bufSize).cast<Uint8>();
    final n = _heap.alloc(4).cast<Uint32>();
    final result = BytesBuilder();
    try {
      while (true) {
        final ok = readFile(_h, buf, bufSize, n, nullptr) != 0;
        result.add(Uint8List.fromList(buf.asTypedList(n.value)));
        if (ok) return result.takeBytes();
        // Сообщение длиннее буфера (ERROR_MORE_DATA): прочитана его часть, дочитываем. Ноль байт с
        // ошибкой — канал закрыт. (Код ошибки через FFI ненадёжен: среда Dart может его затереть.)
        if (n.value == 0) return null;
      }
    } finally {
      _heap.free(buf.cast());
      _heap.free(n.cast());
    }
  }

  void close() {
    _k32.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('CloseHandle')(_h);
    _heap.freeAll();
  }

  /// Номер процесса запущенной службы по данным диспетчера служб; null — службы нет или она стоит.
  static int? _servicePid(String serviceName) {
    final adv = DynamicLibrary.open('advapi32.dll');
    final openScm = adv.lookupFunction<Pointer<Void> Function(Pointer<Uint16>, Pointer<Uint16>, Uint32),
        Pointer<Void> Function(Pointer<Uint16>, Pointer<Uint16>, int)>('OpenSCManagerW');
    final openService = adv.lookupFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Uint16>, Uint32),
        Pointer<Void> Function(Pointer<Void>, Pointer<Uint16>, int)>('OpenServiceW');
    final queryStatus = adv.lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Pointer<Uint8>, Uint32, Pointer<Uint32>),
        int Function(Pointer<Void>, int, Pointer<Uint8>, int, Pointer<Uint32>)>('QueryServiceStatusEx');
    final closeService =
        adv.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('CloseServiceHandle');

    const scManagerConnect = 0x1;
    const serviceQueryStatus = 0x4;
    const scStatusProcessInfo = 0;
    const serviceRunning = 4;
    final heap = _Heap(DynamicLibrary.open('kernel32.dll'));
    final status = heap.alloc(36).cast<Uint8>(); // SERVICE_STATUS_PROCESS
    final needed = heap.alloc(4).cast<Uint32>();
    final serviceNameW = heap.wide(serviceName);
    try {
      final scm = openScm(nullptr, nullptr, scManagerConnect);
      if (scm.address == 0) return null;
      try {
        final service = openService(scm, serviceNameW, serviceQueryStatus);
        if (service.address == 0) return null;
        try {
          if (queryStatus(service, scStatusProcessInfo, status, 36, needed) == 0) return null;
          final data = ByteData.sublistView(status.asTypedList(36));
          if (data.getUint32(4, Endian.little) != serviceRunning) return null;
          final pid = data.getUint32(28, Endian.little);
          return pid == 0 ? null : pid;
        } finally {
          closeService(service);
        }
      } finally {
        closeService(scm);
      }
    } finally {
      heap.freeAll();
    }
  }
}

/// Память в куче процесса: выделенное освобождается по одному или разом.
class _Heap {
  _Heap(DynamicLibrary k32)
      : _heap = k32.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('GetProcessHeap')(),
        _alloc = k32.lookupFunction<Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
            Pointer<Void> Function(Pointer<Void>, int, int)>('HeapAlloc'),
        _free = k32.lookupFunction<Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
            int Function(Pointer<Void>, int, Pointer<Void>)>('HeapFree');

  final Pointer<Void> _heap;
  final Pointer<Void> Function(Pointer<Void>, int, int) _alloc;
  final int Function(Pointer<Void>, int, Pointer<Void>) _free;
  final _blocks = <Pointer<Void>>[];

  Pointer<Void> alloc(int bytes) {
    const heapZeroMemory = 0x8;
    final p = _alloc(_heap, heapZeroMemory, bytes);
    if (p.address == 0) throw StateError('HeapAlloc');
    _blocks.add(p);
    return p;
  }

  void free(Pointer<Void> p) {
    if (_blocks.remove(p)) _free(_heap, 0, p);
  }

  /// Строка UTF-16 с нулём в конце.
  Pointer<Uint16> wide(String s) {
    final p = alloc((s.length + 1) * 2).cast<Uint16>();
    p.asTypedList(s.length + 1).setAll(0, [...s.codeUnits, 0]);
    return p;
  }

  void freeAll() {
    for (final p in _blocks) {
      _free(_heap, 0, p);
    }
    _blocks.clear();
  }
}
