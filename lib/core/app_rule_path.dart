import 'dart:io';

import '../models/app_rules.dart';

/// Проверяет только путь правила. Имя процесса и ошибки доступа не считаются отсутствующим файлом.
Future<bool?> appRulePathExists(AppEntry entry) async {
  if (!entry.isPath) return null;
  try {
    final type = await FileSystemEntity.type(entry.match);
    return entry.isFolder ? type == FileSystemEntityType.directory : type == FileSystemEntityType.file;
  } on FileSystemException {
    return null;
  }
}
