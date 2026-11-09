import 'dart:convert';
import 'dart:io';

import '../core/windows.dart';
import '../l10n/l10n.dart';
import '../models/app_rules.dart';
import '../models/routing.dart';
import '../models/server.dart';
import '../models/settings.dart';
import '../models/subscription.dart';

enum SettingsImportSection { subscriptions, routing, settings }

/// Проверенный снимок файла. После предпросмотра импортируется именно он.
class SettingsImport {
  SettingsImport._(this.settings, this.subscriptions, this.servers, this.profiles, this.appRules);

  final AppSettings settings;
  final List<Subscription> subscriptions;
  final List<ServerProfile> servers;
  final List<RoutingProfile>? profiles;
  final AppRules? appRules;

  Set<SettingsImportSection> get sections => {
        SettingsImportSection.subscriptions,
        if (profiles != null) SettingsImportSection.routing,
        SettingsImportSection.settings,
      };

  static Future<({SettingsImport? data, String? error})> read(String path) async {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return (data: null, error: tr('Это не файл настроек SkipIt'));
    }
    if (json['settings'] is! Map || (json['subscriptions'] is! List && json['protected'] is! String)) {
      return (data: null, error: tr('Это не файл настроек SkipIt'));
    }
    try {
      var secret = json;
      final protected = json['protected'];
      if (protected is String) {
        final plain = WinSys.unprotect(base64Decode(protected));
        if (plain == null) {
          return (data: null, error: tr('Файл зашифрован для другой учётной записи Windows. Нужен файл, сохранённый кнопкой «Экспорт»'));
        }
        secret = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      }
      final subscriptions = _items(secret['subscriptions'], Subscription.fromJson);
      final servers = _items(secret['servers'], ServerProfile.fromJson);
      final subscriptionIds = subscriptions.map((sub) => sub.id).toSet();
      for (final server in servers) {
        if (!subscriptionIds.contains(server.subscriptionId)) server.subscriptionId = null;
      }
      final profiles = json['routing'] == null ? null : _items(json['routing'], RoutingProfile.fromJson)
          .where((p) => !RoutingProfile.legacyPresetIds.contains(p.id)).toList();
      final apps = json['apps'] as Map<String, dynamic>?;
      final data = SettingsImport._(AppSettings.fromJson(json['settings'] as Map<String, dynamic>),
          subscriptions, servers, profiles, apps == null ? null : AppRules.fromJson(apps));
      return (data: data, error: null);
    } catch (_) {
      return (data: null, error: tr('Файл настроек повреждён'));
    }
  }

  static List<T> _items<T>(Object? value, T Function(Map<String, dynamic>) parse) =>
      ((value as List?) ?? const []).cast<Map<String, dynamic>>().map(parse).toList();
}
