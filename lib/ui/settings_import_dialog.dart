import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/settings.dart';
import '../state/settings_import.dart';
import 'screen_privacy.dart';
import 'theme.dart';
import 'widgets.dart';

Future<Set<SettingsImportSection>?> showSettingsImportDialog(BuildContext context, SettingsImport data) {
  final selected = data.sections;
  final profiles = data.profiles;
  final mode = data.settings.mode.label;

  String names(Iterable<String> values) {
    final named = values.where((name) => name.trim().isNotEmpty);
    final first = named.take(3).map((name) => screenTextOf(context, name)).join(' · ');
    return named.length > 3 ? '$first …' : first;
  }

  final summaries = {
    SettingsImportSection.subscriptions: (
      title: tr('Подписки и серверы'),
      detail: tr('Подписок: {0} · Серверов: {1}', [data.subscriptions.length, data.servers.length]),
      names: names(data.subscriptions.map((sub) => sub.name)),
    ),
    SettingsImportSection.routing: (
      title: tr('Профили маршрутизации'),
      detail: profiles == null ? tr('В файле нет этого раздела') : tr('Профилей: {0}', [profiles.length]),
      names: names(profiles?.map((profile) => profile.name) ?? const []),
    ),
    SettingsImportSection.settings: (
      title: tr('Настройки программы'),
      detail: tr('Режим: {0} · Подключение и внешний вид', [mode]),
      names: data.appRules == null ? '' : tr('Правил по программам: {0}', [data.appRules!.entries.length]),
    ),
  };
  return showDialog<Set<SettingsImportSection>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        scrollable: true,
        title: Text(tr('Предпросмотр импорта')),
        content: SizedBox(
          width: 500,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Выберите разделы. Отмеченные разделы заменят текущие данные.'),
                style: TextStyle(color: C.muted, height: 1.4)),
            const SizedBox(height: 12),
            for (final section in SettingsImportSection.values)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(summaries[section]!.title),
                subtitle: Text(
                  [
                    summaries[section]!.detail,
                    if (summaries[section]!.names.isNotEmpty) summaries[section]!.names,
                  ].join('\n'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                value: selected.contains(section),
                onChanged: section == SettingsImportSection.routing && profiles == null ? null : (checked) {
                  setState(() {
                    if (checked == true) {
                      selected.add(section);
                    } else {
                      selected.remove(section);
                    }
                  });
                },
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Отмена'))),
          GradientButton(label: tr('Импортировать'), onPressed: selected.isEmpty ? null : () => Navigator.pop(ctx, selected)),
        ],
      ),
    ),
  );
}
