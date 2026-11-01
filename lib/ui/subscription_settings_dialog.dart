import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../models/subscription.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

class SubscriptionSettingsDialog extends StatefulWidget {
  const SubscriptionSettingsDialog({super.key, required this.state});
  final AppState state;

  @override
  State<SubscriptionSettingsDialog> createState() => _SubscriptionSettingsDialogState();
}

class _SubscriptionSettingsDialogState extends State<SubscriptionSettingsDialog> {
  late final List<Subscription> _subscriptions = List.of(widget.state.subscriptions);
  late final _selected = _subscriptions.map((s) => s.id).toSet();
  late final _hours = TextEditingController(text: _initialHours);
  final _scroll = ScrollController();
  bool _provider = false;
  bool _invalid = false;

  String get _initialHours {
    final values = _subscriptions.map((s) => s.effectiveUpdateIntervalHours).toSet();
    return values.length == 1 ? '${values.single}' : '';
  }

  @override
  void dispose() {
    _hours.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _apply() {
    final hours = int.tryParse(_hours.text.trim());
    if (!_provider && (hours == null || hours < 0)) {
      setState(() => _invalid = true);
      return;
    }
    var count = 0;
    for (final sub in widget.state.subscriptions) {
      if (!_selected.contains(sub.id)) continue;
      sub.updateIntervalOverrideHours = _provider ? null : hours;
      count++;
    }
    widget.state.changed();
    widget.state.toast(tr('Настройки применены к подпискам: {0}', [count]));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true,
        title: Text(tr('Настройки подписок')),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Выберите подписки и задайте общий интервал обновления.'),
                style: TextStyle(color: C.muted, fontSize: 13)),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              tristate: true,
              title: Text(tr('Все подписки')),
              value: _selected.isEmpty ? false : _selected.length == _subscriptions.length ? true : null,
              onChanged: (_) => setState(() {
                final all = _selected.length == _subscriptions.length;
                _selected.clear();
                if (!all) _selected.addAll(_subscriptions.map((s) => s.id));
              }),
            ),
            SizedBox(
              height: math.min(180, math.min(_subscriptions.length * 48.0, MediaQuery.sizeOf(context).height * 0.28)),
              child: Scrollbar(controller: _scroll, thumbVisibility: true,
                child: ListView(controller: _scroll, children: [
                for (final sub in _subscriptions)
                  CheckboxListTile(
                    key: ValueKey('subscription-${sub.id}'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    title: Text(sub.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
                    value: _selected.contains(sub.id),
                    onChanged: (checked) => setState(() {
                      if (checked == true) { _selected.add(sub.id); } else { _selected.remove(sub.id); }
                    }),
                  ),
              ]),
              ),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              title: Text(tr('Интервал провайдера')),
              value: _provider,
              onChanged: (value) => setState(() { _provider = value!; _invalid = false; }),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('subscription-interval'),
              controller: _hours,
              enabled: !_provider,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: tr('Автообновление, часов (0 — выключено)'),
                errorText: _invalid ? tr('Укажите целое число часов: 0 — выключить') : null,
              ),
            ),
            const SizedBox(height: 10),
            Text(tr('Свой интервал сохранится после обновления подписки.'),
                style: TextStyle(color: C.muted, fontSize: 12)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Отмена'))),
          GradientButton(label: tr('Применить'), onPressed: _selected.isEmpty ? null : _apply),
        ],
      );
}
