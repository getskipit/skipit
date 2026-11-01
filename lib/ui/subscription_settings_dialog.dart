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

  void _toggle(String id) => setState(() {
        if (!_selected.add(id)) _selected.remove(id);
      });

  Widget _selectionCard(BuildContext context) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: C.bg, border: Border.all(color: C.border),
            borderRadius: BorderRadius.circular(C.r(14))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.only(left: 14, right: 6),
            child: Row(children: [
              Text(tr('Подписки'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(color: C.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(C.r(6))),
                child: Text('${_selected.length}/${_subscriptions.length}',
                    style: TextStyle(color: C.orange, fontSize: 11, fontWeight: FontWeight.w600)),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() {
                  final all = _selected.length == _subscriptions.length;
                  _selected.clear();
                  if (!all) _selected.addAll(_subscriptions.map((s) => s.id));
                }),
                child: Text(_selected.length == _subscriptions.length ? tr('Снять выбор') : tr('Выбрать все'),
                    style: const TextStyle(fontSize: 12)),
              ),
            ]),
          ),
          const Divider(height: 1),
          SizedBox(
            height: math.min(168, math.min(_subscriptions.length * 40.0, MediaQuery.sizeOf(context).height * 0.25)),
            child: Scrollbar(controller: _scroll, thumbVisibility: true,
              child: ListView.builder(
                controller: _scroll,
                padding: EdgeInsets.zero,
                itemCount: _subscriptions.length,
                itemExtent: 40,
                itemBuilder: (context, index) {
                  final sub = _subscriptions[index];
                  final selected = _selected.contains(sub.id);
                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      key: ValueKey('subscription-${sub.id}'),
                      onTap: () => _toggle(sub.id),
                      child: Row(children: [
                        const SizedBox(width: 4),
                        Checkbox(value: selected, onChanged: (_) => _toggle(sub.id),
                            visualDensity: VisualDensity.compact),
                        const SizedBox(width: 4),
                        Expanded(child: Text(sub.displayName, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500))),
                        const SizedBox(width: 14),
                      ]),
                    ),
                  );
                },
              ),
            ),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true,
        titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
        contentPadding: const EdgeInsets.symmetric(horizontal: 24),
        actionsPadding: const EdgeInsets.fromLTRB(24, 14, 24, 20),
        title: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: C.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(C.r(12))),
            child: Icon(Icons.sync_rounded, color: C.orange, size: 23),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Настройки подписок'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text(tr('Общее обновление для выбранных подписок'),
                style: TextStyle(color: C.muted, fontSize: 12, fontWeight: FontWeight.w400)),
          ])),
        ]),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _selectionCard(context),
            const SizedBox(height: 14),
            Row(children: [
              Icon(Icons.schedule_rounded, color: C.muted, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(tr('Автообновление'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
              const SizedBox(width: 8),
              Tooltip(
                message: tr('Свой интервал сохранится после обновления подписки.'),
                child: Segmented<bool>(
                value: _provider,
                items: {true: tr('Провайдера'), false: tr('Свой')},
                onChanged: (value) => setState(() { _provider = value; _invalid = false; }),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Container(
              key: const ValueKey('subscription-interval-panel'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: C.bg,
                  border: Border.all(color: _invalid ? C.red : C.border),
                  borderRadius: BorderRadius.circular(C.r(14))),
              child: AnimatedCrossFade(
                duration: const Duration(milliseconds: 240),
                sizeCurve: Curves.easeInOutCubic,
                firstCurve: Curves.easeInOut,
                secondCurve: Curves.easeInOut,
                alignment: Alignment.topLeft,
                crossFadeState: _provider ? CrossFadeState.showFirst : CrossFadeState.showSecond,
                firstChild: Text(tr('Каждый провайдер задаёт интервал своей подписки.'),
                      style: TextStyle(color: C.muted, fontSize: 13, height: 1.4)),
                secondChild: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Text(tr('Каждые'), style: const TextStyle(fontSize: 13)),
                        const SizedBox(width: 12),
                        SizedBox(width: 82, child: TextField(
                          key: const ValueKey('subscription-interval'),
                          controller: _hours,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 14),
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          onChanged: (_) { if (_invalid) setState(() => _invalid = false); },
                          decoration: InputDecoration(
                            hintText: '12',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          ),
                        )),
                        const SizedBox(width: 12),
                        Text(tr('часов'), style: TextStyle(color: C.muted, fontSize: 13)),
                      ]),
                      const SizedBox(height: 8),
                      Text(_invalid ? tr('Укажите целое число часов: 0 — выключить') : tr('0 — отключить автообновление'),
                          style: TextStyle(color: _invalid ? C.red : C.muted, fontSize: 12)),
                    ]),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Отмена'))),
          GradientButton(label: tr('Применить'), onPressed: _selected.isEmpty ? null : _apply),
        ],
      );
}
