import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'paths.dart';

/// Связь со службой SkipIt (windows\service\service.cpp) по именованному каналу.
///
/// Служба работает с правами системы, поэтому перед отправкой команды проверяем, что на том конце
/// канала именно её процесс: номер процесса службы сообщает диспетчер служб Windows, а номер
/// процесса-владельца канала — сам канал. Иначе другая программа могла бы занять имя канала раньше
/// службы и получать то, что программа ей отправляет.
class ServiceClient {
  /// Имя службы и её канала; у тестовой сборки — своя служба.
  static String get name => AppPaths.isDev ? 'SkipItDev' : 'SkipIt';

  /// Версия протокола службы («skipit-service 1») или null, если служба не установлена, не запущена
  /// или не отвечает.
  static Future<String?> hello({String? serviceName}) {
    final target = serviceName ?? name;
    return Isolate.run(() => _request(target, 'hello'));
  }

  /// Одна команда — один ответ. null — ответа нет (службы нет, она чужая или отказала).
  static String? _request(String serviceName, String command) {
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
    final writeFile = k32.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>('WriteFile');
    final readFile = k32.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>('ReadFile');
    final closeHandle = k32.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('CloseHandle');

    const genericReadWrite = 0xC0000000;
    const openExisting = 3;
    const pipeReadModeMessage = 2;
    const bufSize = 64 * 1024;
    final heap = _Heap(k32);
    final path = heap.wide('${r'\\.\pipe\'}$serviceName');
    final word = heap.alloc(4).cast<Uint32>();
    final buf = heap.alloc(bufSize).cast<Uint8>();
    try {
      final pipe = createFile(path, genericReadWrite, 0, nullptr, openExisting, 0, nullptr);
      if (pipe.address == -1) return null;
      try {
        word.value = pipeReadModeMessage;
        if (setState(pipe, word, nullptr, nullptr) == 0) return null;
        if (serverPid(pipe, word) == 0 || word.value != pid) return null;
        final bytes = Uint8List.fromList(command.codeUnits);
        if (bytes.length > bufSize) return null;
        buf.asTypedList(bytes.length).setAll(0, bytes);
        if (writeFile(pipe, buf, bytes.length, word, nullptr) == 0) return null;
        if (readFile(pipe, buf, bufSize, word, nullptr) == 0) return null;
        return String.fromCharCodes(buf.asTypedList(word.value));
      } finally {
        closeHandle(pipe);
      }
    } finally {
      heap.freeAll();
    }
  }

  /// Номер процесса запущенной службы по данным диспетчера служб; null — службы нет или она стоит.
  static int? _servicePid(String serviceName) {
    final adv = DynamicLibrary.open('advapi32.dll');
    final openScm = adv.lookupFunction<Pointer<Void> Function(Pointer<Uint16>, Pointer<Uint16>, Uint32),
        Pointer<Void> Function(Pointer<Uint16>, Pointer<Uint16>, int)>('OpenSCManagerW');
    final openService = adv.lookupFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Uint16>, Uint32),
        Pointer<Void> Function(Pointer<Void>, Pointer<Uint16>, int)>('OpenServiceW');
    final queryStatus = adv.lookupFunction<Int32 Function(Pointer<Void>, Int32, Pointer<Uint8>, Uint32, Pointer<Uint32>),
        int Function(Pointer<Void>, int, Pointer<Uint8>, int, Pointer<Uint32>)>('QueryServiceStatusEx');
    final closeService = adv.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('CloseServiceHandle');

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

/// Память в куче процесса на время одного запроса: всё выделенное освобождается разом.
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
