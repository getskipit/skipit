import 'dart:convert';
import 'dart:io';

import 'paths.dart';

/// Релиз SkipIt на GitHub. Все адреса строятся из тега — обращаться к API GitHub не нужно.
class Release {
  Release(this.tag, this.repo);
  final String tag;
  final String repo;

  String get version => tag.startsWith('v') ? tag.substring(1) : tag;
  String get pageUrl => 'https://github.com/$repo/releases/tag/$tag';

  /// Установщик, который сборка на GitHub прикрепляет к релизу.
  String get installerName => 'SkipIt-Setup-Windows-$version.exe';
  String get installerUrl => 'https://github.com/$repo/releases/download/$tag/$installerName';

  /// Файл с SHA-256 установщика (сборка кладёт его рядом).
  String get checksumUrl => '$installerUrl.sha256';
}

/// Вложенное ядро: показываем его версию в настройках. Обновляются ядра только вместе с программой.
class CoreSpec {
  const CoreSpec(this.name, this.exe, this.versionPattern);
  final String name;

  /// Имя у нас (уникальное, чтобы другие VPN-клиенты не закрывали чужие xray.exe).
  final String exe;
  final String versionPattern;

  String get path => '${AppPaths.coreDir.path}\\$exe';

  static const xray = CoreSpec('Xray-core', 'skipit-xray.exe', r'Xray ([\d.]+)');
  static const singbox = CoreSpec('sing-box', 'skipit-sing-box.exe', r'sing-box version ([\d.]+)');
  static const all = [xray, singbox];
}

/// GitHub временно ограничил запросы с этого адреса — не ошибка программы, нужно просто подождать.
class UpdateLimitedException implements Exception {
  const UpdateLimitedException();
  @override
  String toString() => 'GitHub временно ограничил проверки с вашего адреса — попробуйте позже';
}

class Updates {
  static HttpClient _client(int? proxyPort) {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    if (proxyPort != null) c.findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
    return c;
  }

  /// Запрос к обычной странице github.com (не к API: у API лимит 60 запросов в час на IP-адрес,
  /// а адрес VPN-сервера общий для многих пользователей).
  static Future<({int status, String? location, String body})> _get(
    String url,
    int? proxyPort, {
    String method = 'GET',
    bool followRedirects = true,
  }) async {
    final client = _client(proxyPort);
    try {
      final req = await client.openUrl(method, Uri.parse(url));
      req.followRedirects = followRedirects;
      req.headers.set(HttpHeaders.userAgentHeader, 'SkipIt-updater');
      final res = await req.close().timeout(const Duration(seconds: 20));
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
      if (res.statusCode == 429 || res.statusCode == 403) throw const UpdateLimitedException();
      return (status: res.statusCode, location: res.headers.value(HttpHeaders.locationHeader), body: body);
    } finally {
      client.close(force: true);
    }
  }

  /// Запрос без автоматических переходов, но с переходами внутри github.com: если репозиторий
  /// переименуют или перенесут в организацию, GitHub сначала перенаправляет на новый адрес.
  /// Возвращает первый ответ, который не является таким «переездом».
  static Future<({int status, String? location, String body})> _getOnGithub(
    String url,
    int? proxyPort, {
    String method = 'GET',
    bool Function(String location)? stopAt,
  }) async {
    var current = Uri.parse(url);
    for (var hop = 0;; hop++) {
      final r = await _get('$current', proxyPort, method: method, followRedirects: false);
      final location = r.location;
      final redirect = r.status >= 300 && r.status < 400 && location != null;
      if (!redirect || hop >= 5 || (stopAt != null && stopAt(location))) return r;
      final next = current.resolve(location);
      // Переход на другой сервер (хранилище файлов релиза) — уже не переезд репозитория.
      if (next.host != 'github.com') return r;
      current = next;
    }
  }

  static final _tagInUrl = RegExp(r'/releases/tag/([^/"<>?#\s]+)');

  /// Последний релиз. Стабильный канал — то, что GitHub считает «Latest» (пре-релизы не в счёт).
  /// [prerelease] — канал «Бета»: самая новая версия среди всех опубликованных, включая пре-релизы.
  static Future<Release> latest(String repo, {int? proxyPort, bool prerelease = false}) async {
    if (!prerelease) {
      // Страница /releases/latest перенаправляет на релиз с тегом — его и читаем из адреса.
      final r = await _getOnGithub('https://github.com/$repo/releases/latest', proxyPort, stopAt: _tagInUrl.hasMatch);
      final tag = _tagInUrl.firstMatch(r.location ?? '')?.group(1);
      if (tag != null) return Release(Uri.decodeComponent(tag), repo);
      if (r.status >= 500) throw HttpException('GitHub ответил ${r.status}');
      // Стабильных релизов ещё нет (выходили только пре-релизы) — «Стабильный» канал берёт их,
      // чтобы пользователи с настройками по умолчанию не остались без обновлений.
    }
    final feed = await _get('https://github.com/$repo/releases.atom', proxyPort);
    if (feed.status == 404) throw const HttpException('релизов пока нет');
    if (feed.status != 200) throw HttpException('GitHub ответил ${feed.status}');
    final tags = {for (final m in _tagInUrl.allMatches(feed.body)) Uri.decodeComponent(m.group(1)!)}.toList();
    if (tags.isEmpty) throw const HttpException('релизов пока нет');
    tags.sort((a, b) => compare(b, a));
    return Release(tags.first, repo);
  }

  /// Прикреплён ли к релизу установщик. Пока GitHub собирает релиз, его ещё нет.
  static Future<bool> hasInstaller(Release release, {int? proxyPort}) async {
    // Существующий файл GitHub отдаёт переходом в хранилище, отсутствующий — ответом 404.
    final r = await _getOnGithub(release.installerUrl, proxyPort, method: 'HEAD');
    return r.status == 200 || (r.status >= 300 && r.status < 400);
  }

  /// Почему Windows не запустила скачанный установщик — простыми словами.
  /// Обойти такой запрет программа не может и не должна: решение за пользователем.
  static String launchFailure(Object e) {
    final code = e is ProcessException ? e.errorCode : 0;
    // 4551 — политика целостности кода (Интеллектуальный контроль приложений), 1260 — запрет политикой,
    // 225 — файл остановлен антивирусом.
    return switch (code) {
      4551 || 1260 => 'Установщик не подписан сертификатом издателя, а на этом компьютере Windows запускает '
          'только подписанные программы (Интеллектуальный контроль приложений или политика безопасности). '
          'Файл скачан и сверен с контрольной суммой, но запустить его программа не может.',
      225 => 'Антивирус остановил запуск установщика. Файл скачан и сверен с контрольной суммой — '
          'проверьте журнал антивируса.',
      _ => 'Файл скачан и сверен с контрольной суммой, но Windows не дала его запустить'
          '${e is ProcessException && e.message.isNotEmpty ? ': ${e.message.trim()}' : ''}'
          '${code != 0 ? ' (код $code)' : ''}.',
    };
  }

  /// SHA-256 файла средствами Windows (certutil) — без сторонних пакетов.
  static Future<String> sha256Of(String path) async {
    final r = await Process.run(AppPaths.system('certutil'), ['-hashfile', path, 'SHA256']);
    final m = RegExp(r'^[0-9a-fA-F ]{64,}$', multiLine: true).firstMatch(r.stdout as String);
    if (r.exitCode != 0 || m == null) throw Exception('Не удалось посчитать контрольную сумму');
    return m.group(0)!.replaceAll(' ', '').toLowerCase();
  }

  /// Контрольная сумма установщика из релиза. null — получить файл с суммой не удалось.
  static Future<String?> expectedSha256(Release release, {int? proxyPort}) async {
    final r = await _get(release.checksumUrl, proxyPort);
    if (r.status != 200) return null;
    return RegExp(r'\b[0-9a-fA-F]{64}\b').firstMatch(r.body)?.group(0)?.toLowerCase();
  }

  /// Сверяет скачанный файл с контрольной суммой из релиза. Не совпало — файл удаляется.
  /// Без суммы ([expected] == null) файл тоже удаляется: несверенный установщик не запускается.
  static Future<void> verify(String path, String? expected) async {
    if (expected != null && await sha256Of(path) == expected.toLowerCase()) return;
    try {
      await File(path).delete();
    } catch (_) {}
    throw Exception(expected == null
        ? 'Не удалось получить контрольную сумму установщика — без сверки он не запускается. Попробуйте ещё раз'
        : 'Файл повреждён или подменён: контрольная сумма не совпала');
  }

  /// Версия установленного ядра (`xray version` / `sing-box version`).
  static Future<String?> installedVersion(CoreSpec core) async {
    if (!File(core.path).existsSync()) return null;
    try {
      final r = await Process.run(core.path, ['version'], stdoutEncoding: utf8);
      return RegExp(core.versionPattern).firstMatch(r.stdout as String)?.group(1);
    } catch (_) {
      return null;
    }
  }

  /// Сравнение версий вида 1.2.3, 1.2.3a, v26.3.27: сначала числа, потом буквенный суффикс.
  static int compare(String a, String b) {
    List<int> nums(String v) =>
        RegExp(r'\d+').allMatches(v.split(RegExp(r'[-+]')).first).map((m) => int.parse(m.group(0)!)).toList();
    final x = nums(a), y = nums(b);
    for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d.sign;
    }
    String suffix(String v) => RegExp(r'[a-z]+', caseSensitive: false).firstMatch(v.replaceAll(RegExp(r'^v'), ''))?.group(0) ?? '';
    final sa = suffix(a), sb = suffix(b);
    // «1.2.3» новее, чем «1.2.3a» (буква — предварительная версия).
    if (sa.isEmpty && sb.isNotEmpty) return 1;
    if (sa.isNotEmpty && sb.isEmpty) return -1;
    return sa.compareTo(sb).sign;
  }
}
