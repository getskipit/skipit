import 'dart:convert';
import 'dart:io';

import 'paths.dart';

/// Иконки программ: извлекаются из .exe (System.Drawing) и кешируются PNG-файлами.
class IconCache {
  static Directory get _dir => Directory('${AppPaths.dataDir.path}\\icons');

  /// FNV-1a: стабильное имя файла для пути (String.hashCode между запусками не гарантирован).
  static String _hash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.toLowerCase().codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  static String fileFor(String exePath) => '${_dir.path}\\${_hash(exePath.replaceAll('/', '\\'))}.png';

  static bool has(String exePath) => File(fileFor(exePath)).existsSync();

  /// Файл программы внутри её папки: в самой папке или в самой свежей папке версии (`app-1.2.3`).
  /// Нужен программам, которые обновляются сами: после обновления exe лежит уже в другой папке версии.
  /// Возвращает путь с прямыми слэшами или null, если такого файла нет.
  static Future<String?> findExe(String folder, String fileName) async {
    try {
      final dir = Directory(folder.replaceAll('/', '\\').replaceFirst(RegExp(r'\\+$'), ''));
      if (!await dir.exists()) return null;
      final versions = [
        await for (final e in dir.list())
          if (e is Directory && RegExp(r'^app-\d', caseSensitive: false).hasMatch(e.path.split('\\').last)) e.path,
      ]..sort();
      for (final where in [...versions.reversed, dir.path]) {
        final file = File('$where\\$fileName');
        if (await file.exists()) return file.path.replaceAll('\\', '/');
      }
    } catch (_) {
      // Нет доступа к папке — значок останется запасным.
    }
    return null;
  }

  /// Извлекает недостающие иконки одним вызовом PowerShell.
  static Future<void> ensure(Iterable<String> exePaths) async {
    final missing = <Map<String, String>>[];
    for (final p in exePaths.toSet()) {
      final win = p.replaceAll('/', '\\');
      if (!win.toLowerCase().endsWith('.exe') || has(win)) continue;
      missing.add({'path': win, 'out': fileFor(win)});
    }
    if (missing.isEmpty) return;
    await _dir.create(recursive: true);
    final list = File('${_dir.path}\\request.json');
    await list.writeAsString(jsonEncode(missing));
    final script = 'Add-Type -AssemblyName System.Drawing; '
        "\$items = Get-Content -Raw -Encoding UTF8 '${list.path.replaceAll("'", "''")}' | ConvertFrom-Json; "
        'foreach (\$i in \$items) { try { '
        '\$ico = [System.Drawing.Icon]::ExtractAssociatedIcon(\$i.path); '
        '\$ico.ToBitmap().Save(\$i.out, [System.Drawing.Imaging.ImageFormat]::Png) } catch {} }';
    await Process.run(AppPaths.powershell, ['-NoProfile', '-NonInteractive', '-Command', script]);
  }
}
