import 'package:flutter/material.dart';

import '../core/util.dart';
import '../l10n/l10n.dart';
import '../models/routing.dart';
import '../state/app_scope.dart';
import 'smooth_scroll.dart';
import 'theme.dart';
import 'widgets.dart';

/// Различия сохранённых значений профилей; записи из скачанных списков не раскрываются.
class RoutingDifference {
  const RoutingDifference(this.title, this.left, this.right);
  final String title;
  final List<String> left;
  final List<String> right;
}

List<RoutingDifference> compareRoutingProfiles(RoutingProfile a, RoutingProfile b) {
  final result = <RoutingDifference>[];
  void values(String title, Iterable<String> left, Iterable<String> right, {bool hideUrls = false}) {
    final l = left.toSet();
    final r = right.toSet();
    final onlyLeft = l.difference(r).toList()..sort();
    final onlyRight = r.difference(l).toList()..sort();
    if (onlyLeft.isEmpty && onlyRight.isEmpty) return;
    result.add(RoutingDifference(title,
        hideUrls ? onlyLeft.map(scrubUrls).toList() : onlyLeft,
        hideUrls ? onlyRight.map(scrubUrls).toList() : onlyRight));
  }
  values(tr('Всё остальное'), [a.globalProxy ? tr('через VPN') : tr('напрямую')],
      [b.globalProxy ? tr('через VPN') : tr('напрямую')]);
  values(tr('Стратегия доменов'), [a.domainStrategy], [b.domainStrategy]);
  values(tr('Удалённый DNS'), [a.remoteDnsAddress], [b.remoteDnsAddress], hideUrls: true);
  values(tr('Локальный DNS'), [a.domesticDnsAddress], [b.domesticDnsAddress], hideUrls: true);
  values(tr('Через VPN — сайты'), a.proxySites, b.proxySites);
  values(tr('Через VPN — IP'), a.proxyIp, b.proxyIp);
  values(tr('Напрямую — сайты'), a.directSites, b.directSites);
  values(tr('Напрямую — IP'), a.directIp, b.directIp);
  values(tr('Блокировать — сайты'), a.blockSites, b.blockSites);
  values(tr('Блокировать — IP'), a.blockIp, b.blockIp);
  values(tr('DNS hosts'), a.dnsHosts.entries.map((e) => '${e.key} = ${e.value}'),
      b.dnsHosts.entries.map((e) => '${e.key} = ${e.value}'));
  for (final (action, title) in [
    ('proxy', tr('Списки по ссылке — через VPN')),
    ('direct', tr('Списки по ссылке — напрямую')),
    ('block', tr('Списки по ссылке — блокировать')),
  ]) {
    values(title, a.ruleLists.where((s) => s.action == action).map((s) => s.url),
        b.ruleLists.where((s) => s.action == action).map((s) => s.url), hideUrls: true);
  }
  values(tr('Адрес geoip.dat'), [a.geoipUrl], [b.geoipUrl], hideUrls: true);
  values(tr('Адрес geosite.dat'), [a.geositeUrl], [b.geositeUrl], hideUrls: true);
  return result;
}

class RoutingCompareDialog extends StatefulWidget {
  const RoutingCompareDialog({super.key, required this.profiles});
  final List<RoutingProfile> profiles;
  @override
  State<RoutingCompareDialog> createState() => _RoutingCompareDialogState();
}

class _RoutingCompareDialogState extends State<RoutingCompareDialog> {
  late String leftId = widget.profiles[0].id;
  late String rightId = widget.profiles[1].id;
  final scroll = SmoothScrollController();
  @override
  void dispose() { scroll.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final left = widget.profiles.firstWhere((p) => p.id == leftId);
    final right = widget.profiles.firstWhere((p) => p.id == rightId);
    final differences = compareRoutingProfiles(left, right);
    final state = AppScope.of(context);
    final options = {for (final p in widget.profiles) p.id: state.screenText(p.name)};
    Widget column(List<String> entries) {
      final shown = entries.take(50).map(scrubUrls).map(state.screenText).join('\n');
      return Expanded(child: SelectableText(entries.isEmpty ? '—' : '$shown${entries.length > 50 ? '\n${tr('и ещё {0}', [entries.length - 50])}' : ''}',
          style: TextStyle(color: entries.isEmpty ? C.muted : C.text, fontSize: 13)));
    }
    return AlertDialog(
      title: Text(tr('Сравнение профилей')),
      content: SizedBox(width: 720, height: 430, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: AppDropdown<String>(value: leftId, items: options, expand: true, onChanged: (v) => setState(() => leftId = v))),
          const SizedBox(width: 12),
          Expanded(child: AppDropdown<String>(value: rightId, items: options, expand: true, onChanged: (v) => setState(() => rightId = v))),
        ]),
        const SizedBox(height: 10),
        Text(tr('Показаны различия сохранённых настроек и ссылок, без содержимого скачанных списков. Правила провайдера имеют приоритет.'),
            style: TextStyle(color: C.muted, fontSize: 12)),
        const SizedBox(height: 10),
        Expanded(child: differences.isEmpty
            ? Center(child: Text(tr('Различий нет'), style: TextStyle(color: C.muted)))
            : ListView.builder(controller: scroll, itemCount: differences.length, itemBuilder: (_, i) {
                final d = differences[i];
                return Padding(padding: const EdgeInsets.only(bottom: 14), child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(d.title, style: TextStyle(color: C.orange, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 5),
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [column(d.left), const SizedBox(width: 12), column(d.right)]),
                  ],
                ));
              })),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Закрыть')))],
    );
  }
}
