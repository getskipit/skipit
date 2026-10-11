import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/dns_check.dart';
import '../core/line_check.dart';
import '../core/log_store.dart';
import '../core/site_check.dart';
import '../core/speed_test.dart';
import '../core/util.dart';
import '../core/windows.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Раздел «Проверка»: всё, чем разбираются, когда что-то работает не так, — почему тормозит сайт,
/// ровная ли связь, какая скорость, как отвечают DNS-серверы подключения и отчёт для разбора одним файлом.
class CheckPage extends StatelessWidget {
  const CheckPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Column(children: [
      const PageHeader('Проверка', subtitle: 'Если что-то работает не так: где теряется время и что показать тому, кто поможет'),
      Expanded(
        child: ListView(
          primary: true,
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
          children: [
            _SiteCard(state: state),
            const SizedBox(height: 14),
            _LineCard(state: state),
            const SizedBox(height: 14),
            _SpeedCard(state: state),
            const SizedBox(height: 14),
            _DnsCheckCard(state: state),
            const SizedBox(height: 14),
            _ReportCard(state: state),
          ],
        ),
      ),
    ]);
  }
}

/// Шапка карточки: значок, название и пояснение под ним.
Widget _cardTitle(IconData icon, String title, String subtitle) => Row(children: [
      Icon(icon, color: C.muted),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(color: C.muted, fontSize: 12)),
        ]),
      ),
    ]);

String _ms(int? value) => value == null ? '—' : '$value мс';

/// Значок и цвет вывода: зелёный «всё в порядке», оранжевый «причина» или «к сведению», красный «не вышло».
(IconData, Color) _look(SiteNoteKind kind) => switch (kind) {
      SiteNoteKind.ok => (Icons.check_circle_rounded, C.green),
      SiteNoteKind.info => (Icons.info_rounded, C.orange),
      SiteNoteKind.warn => (Icons.error_rounded, C.orange),
      SiteNoteKind.bad => (Icons.error_rounded, C.red),
    };

/// Вывод проверки — плашкой своего цвета.
Widget _note(SiteNote note) {
  final (icon, color) = _look(note.kind);
  return Container(
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(
      color: color.withValues(alpha: note.kind == SiteNoteKind.info ? 0.06 : 0.10),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 16, color: color)),
      const SizedBox(width: 10),
      Expanded(child: Text(note.text, style: const TextStyle(fontSize: 12.5))),
    ]),
  );
}

/// Плитка с одним замером: подпись, значение и пояснение под ним ([mono] — это адрес). Плитки одного
/// размера: три строки в каждой.
Widget _metric(String name, String value, String note, {bool mono = false, Color? color}) => Container(
      width: 172,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: C.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: C.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: C.muted, fontSize: 11)),
        const SizedBox(height: 2),
        Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: color)),
        Text(note,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: C.muted, fontSize: 11, fontFamily: mono ? 'Consolas' : null)),
      ]),
    );

/// Кнопка «Скопировать результат»: текст проверки — в буфер, чтобы отправить тому, кто помогает.
Widget _copy(AppState state, String Function() text) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: GhostButton(
          label: 'Скопировать результат',
          icon: Icons.copy_rounded,
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text()));
            state.toast('Результат скопирован', kind: ToastKind.success);
          },
        ),
      ),
    );

Color? _pathColor(ConnRoute? route) => switch (route) {
      ConnRoute.proxy => C.orange,
      ConnRoute.direct => C.green,
      ConnRoute.block => C.red,
      _ => null,
    };

/// «Почему тормозит сайт?»: проверка сайта — каким путём он идёт и на что уходит время. Один сайт —
/// подробно, несколько — по строке на каждый.
class _SiteCard extends StatefulWidget {
  const _SiteCard({required this.state});
  final AppState state;

  @override
  State<_SiteCard> createState() => _SiteCardState();
}

class _SiteCardState extends State<_SiteCard> {
  final _site = TextEditingController();
  bool _wrong = false;

  /// Какие сайты из нескольких развёрнуты до подробного вида.
  final _open = <String>{};

  @override
  void dispose() {
    _site.dispose();
    super.dispose();
  }

  void _check() {
    final hosts = SiteCheck.hostsOf(_site.text);
    setState(() {
      _wrong = hosts == null;
      _open.clear();
    });
    if (hosts != null) widget.state.checkSites(hosts);
  }

  Widget _name(SiteReport r, double size) => Row(children: [
        Flexible(
          child: Text(r.host,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: 'Consolas', fontSize: size, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 10),
        if (r.done)
          Tag(r.path, color: _pathColor(r.route))
        else ...[
          const Spinner(size: 14),
          const SizedBox(width: 8),
          Text('проверяется…', style: TextStyle(color: C.muted, fontSize: 12)),
        ],
      ]);

  /// Один сайт — подробно: плитки замеров и все строки вывода.
  List<Widget> _full(SiteReport r) => [
        const SizedBox(height: 14),
        _name(r, 13.5),
        if (r.done) ...[const SizedBox(height: 10), ..._details(r)],
      ];

  /// Подробности проверенного сайта: плитки замеров и все строки вывода.
  List<Widget> _details(SiteReport r) => [
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (r.firstMs == null)
              _metric('Соединение', 'не открылось', 'этим путём', color: C.red)
            else ...[
              _metric('Первое соединение', _ms(r.firstMs), 'вместе с поиском адреса'),
              _metric('Повторное', _ms(r.warmMs), 'лучшее из трёх'),
              _metric('Ответ сайта', _ms(r.replyMs), 'после соединения'),
            ],
            if (r.vpnBaseMs != null) _metric('Проверочный адрес', _ms(r.vpnBaseMs), 'тем же путём через VPN'),
            if (r.address != null) _metric('Адрес от DNS ядра', _ms(r.addressMs), r.address!, mono: true),
            if (r.otherAddress != null)
              _metric('Адрес от другого DNS', _ms(r.otherMs), r.otherAddress!, mono: true),
          ]),
          for (final note in r.notes) _note(note),
      ];

  /// Строка одного сайта, когда их несколько: путь, времена и главный вывод. По клику разворачивается
  /// до того же подробного вида, что у одного сайта.
  Widget _compact(SiteReport r) {
    final note = r.done ? r.mainNote : null;
    final (icon, color) = note == null ? (Icons.circle, C.muted) : _look(note.kind);
    final open = r.done && _open.contains(r.host);
    return Hover(
      enabled: r.done,
      builder: (context, hovered) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: !r.done ? null : () => setState(() => open ? _open.remove(r.host) : _open.add(r.host)),
        child: Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.fromLTRB(12, 9, 8, 10),
          decoration: BoxDecoration(
            color: hovered || open ? C.surface2 : null,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: C.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (note != null) ...[
                Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 16, color: color)),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _name(r, 12.5),
                  if (!open && r.done && r.firstMs != null) ...[
                    const SizedBox(height: 2),
                    Text(
                        'первое соединение ${_ms(r.firstMs)} · повторное ${_ms(r.warmMs)} · '
                        'ответ сайта ${_ms(r.replyMs)}',
                        style: TextStyle(color: C.muted, fontSize: 12)),
                  ],
                  if (!open && note != null && (note.kind != SiteNoteKind.ok || r.firstMs == null))
                    Text(note.text, style: TextStyle(color: color, fontSize: 12)),
                ]),
              ),
              if (r.done)
                Tooltip(
                  message: open ? 'Свернуть' : 'Развернуть: все замеры и выводы',
                  child: Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: C.muted),
                ),
            ]),
            if (open) ...[const SizedBox(height: 10), ..._details(r)],
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final reports = state.siteReports;
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _cardTitle(Icons.troubleshoot_rounded, 'Почему тормозит сайт?',
            'Проверим сайт так, как к нему ходит браузер: каким путём он идёт и на что уходит время'),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _site,
              onSubmitted: (_) => _check(),
              decoration: const InputDecoration(
                  labelText: 'Адрес сайта', hintText: 'example.com — или несколько через запятую'),
            ),
          ),
          const SizedBox(width: 12),
          GhostButton(
            label: 'Проверить',
            icon: Icons.speed_rounded,
            busy: state.checkingSite,
            onPressed: state.isConnected ? _check : null,
          ),
        ]),
        if (_wrong || !state.isConnected) ...[
          const SizedBox(height: 8),
          Text(
              _wrong
                  ? 'Впишите адрес сайта, например example.com; несколько — через запятую, не больше ${SiteCheck.maxHosts}'
                  : 'Чтобы проверить сайт, сначала подключитесь к VPN',
              style: TextStyle(color: _wrong ? C.orange : C.muted, fontSize: 12)),
        ],
        if (reports.length == 1) ..._full(reports.single),
        if (reports.length > 1) ...[
          const SizedBox(height: 6),
          for (final r in reports) _compact(r),
        ],
        if (reports.isNotEmpty && reports.every((r) => r.done))
          _copy(state, () => [for (final r in reports) r.copyText].join('\n')),
        const SizedBox(height: 10),
        Text(
          'Правила по приложениям на проверку не действуют. В обход VPN программа обращается только к сайту, '
          'который и так идёт напрямую: открывает соединение с его адресом и спрашивает адрес у Google.',
          style: TextStyle(color: C.muted, fontSize: 12),
        ),
      ]),
    );
  }
}

/// Стабильность связи: потери и всплески задержки через VPN и напрямую.
class _LineCard extends StatelessWidget {
  const _LineCard({required this.state});
  final AppState state;

  /// Плитка одного пути: обычный ответ крупно, под ним полоса замера (столбик — худший ответ за
  /// отрезок, красный — потеря) и строка с потерями, худшим ответом и всплесками.
  Widget _gauge(String name, LineReport r, LinePath p, List<int?> rtt, String? skipped) {
    final off = skipped != null || (r.done && !p.measured);
    final active = !r.done && !off;
    final value = off
        ? 'не измерялось'
        : p.silent && r.done
            ? 'ответов нет'
            : _ms(p.usual);
    final detail = off
        ? (skipped ?? '—')
        : !p.measured
            ? 'идёт замер…'
            : p.silent
                ? 'из ${p.sent} пакетов'
                : 'потери ${p.lossText()} · худший ${_ms(p.worst)} · всплесков ${p.spikes}';
    return Container(
      width: 266,
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
      decoration: BoxDecoration(
        color: C.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: active ? C.orange.withValues(alpha: 0.6) : C.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(name, style: TextStyle(color: C.muted, fontSize: 11)),
        const SizedBox(height: 2),
        Text(value,
            maxLines: 1,
            style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: off ? C.muted : (p.silent && r.done ? C.orange : null),
                fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(height: 8),
        SizedBox(
          height: 34,
          width: double.infinity,
          child: CustomPaint(painter: _LineBars(off ? const [] : rtt, r.sent, r.done, p.usual)),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: off ? 0 : r.progress),
            duration: const Duration(milliseconds: 250),
            builder: (context, shown, _) => LinearProgressIndicator(
                value: shown, minHeight: 3, backgroundColor: C.border, color: active ? C.orange : C.muted),
          ),
        ),
        const SizedBox(height: 6),
        Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: C.muted, fontSize: 11)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = state.lineReport;
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _cardTitle(Icons.show_chart_rounded, 'Стабильность связи',
            '${LineCheck.seconds} секунд шлём маленькие пробные пакеты через VPN и напрямую: видно, ровная ли связь и где она портится'),
        const SizedBox(height: 14),
        Row(children: [
          GhostButton(
            label: 'Замерить',
            icon: Icons.speed_rounded,
            busy: state.checkingLine,
            onPressed: state.isConnected ? state.checkLine : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              !state.isConnected
                  ? 'Чтобы замерить связь, сначала подключитесь к VPN'
                  : state.checkingLine
                      ? 'Идёт замер, осталось ${r?.left ?? LineCheck.seconds} с'
                      : state.killSwitchOn
                          ? 'Включён Kill Switch: замер пойдёт только через VPN — напрямую программа ничего не отправляет'
                          : 'Пакеты идут к ${LineCheck.host} — через VPN и напрямую',
              style: TextStyle(color: C.muted, fontSize: 12),
            ),
          ),
        ]),
        if (r != null && r.error == null) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _gauge('Через VPN', r, r.vpn, r.vpnRtt, r.vpnSkipped),
            _gauge('Напрямую', r, r.direct, r.directRtt, r.directSkipped),
          ]),
          if (r.done)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                  'Столбик — худший ответ за отрезок времени: яркий — всплеск (дольше обычного на '
                  '${LineCheck.spikeOver} мс), красный — пакет потерян',
                  style: TextStyle(color: C.muted, fontSize: 11.5)),
            ),
        ],
        if (r != null && r.done) ...[
          for (final note in r.notes) _note(note),
          _copy(state, () => r.copyText),
        ],
      ]),
    );
  }
}

/// Полоса замера стабильности: время делится на равные отрезки, столбик — худший ответ за отрезок.
/// Ровная связь — низкий ровный ряд; всплески торчат яркими столбиками, потери — красными.
class _LineBars extends CustomPainter {
  _LineBars(this.rtt, this.sent, this.done, this.usual);

  /// Время ответа на каждый пакет (null — ответа нет) и сколько пакетов уже ушло.
  final List<int?> rtt;
  final int sent;
  final bool done;
  final int? usual;

  static const _slots = 50;

  @override
  void paint(Canvas canvas, Size size) {
    final step = size.width / _slots, width = step - 1.5;
    final per = rtt.isEmpty ? 1 : (rtt.length / _slots).ceil();
    // Пакет считается потерянным, когда ответа нет уже секунду: до того он может быть ещё в пути.
    final settled = done ? sent : sent - 1000 ~/ LineCheck.interval.inMilliseconds;
    final base = usual ?? 0;
    var peak = base * 2 > 100 ? base * 2 : 100;
    for (var i = 0; i < sent && i < rtt.length; i++) {
      if ((rtt[i] ?? 0) > peak) peak = rtt[i]!;
    }
    void bar(int slot, double height, Color color) => canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(slot * step, size.height - height, width, height), const Radius.circular(1.5)),
        Paint()..color = color);
    for (var slot = 0; slot < _slots; slot++) {
      final from = slot * per;
      int? worst;
      var lost = false;
      for (var i = from; i < from + per && i < rtt.length && i < sent; i++) {
        final ms = rtt[i];
        if (ms == null) {
          lost = lost || i < settled;
        } else if (worst == null || ms > worst) {
          worst = ms;
        }
      }
      if (lost) {
        bar(slot, size.height, C.red.withValues(alpha: 0.9));
      } else if (worst == null) {
        // Замер сюда ещё не дошёл.
        bar(slot, 2, C.border);
      } else {
        final spike = worst > base + LineCheck.spikeOver;
        bar(slot, (worst / peak * size.height).clamp(2.0, size.height), C.orange.withValues(alpha: spike ? 1 : 0.4));
      }
    }
  }

  // Список пополняется на месте — сравнить его с прежним нельзя.
  @override
  bool shouldRepaint(_LineBars old) => true;
}

/// Замер скорости скачивания через VPN и напрямую.
class _SpeedCard extends StatelessWidget {
  const _SpeedCard({required this.state});
  final AppState state;

  /// Плитка одного пути: пока он меряется — живая скорость, столбики и полоска времени; после —
  /// итог над теми же столбиками. [index] — номер пути в замере (см. SpeedReport.running).
  Widget _gauge(String name, SpeedReport r, int index, double? result, List<double> samples, String? error) {
    final active = r.running == index;
    final waiting = !r.done && !active && result == null && error == null && samples.isEmpty;
    final failed = !active && !waiting && result == null;
    final value = active
        ? SpeedReport.show(samples.lastOrNull)
        : waiting
            ? '—'
            : (result != null ? SpeedReport.show(result) : (index == 0 ? 'не удалось' : 'не измерялось'));
    return Container(
      width: 266,
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
      decoration: BoxDecoration(
        color: C.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: active ? C.orange.withValues(alpha: 0.6) : C.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(name, style: TextStyle(color: C.muted, fontSize: 11)),
        const SizedBox(height: 2),
        Text(value,
            maxLines: 1,
            style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: failed && index == 0 ? C.red : (waiting ? C.muted : null),
                fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(height: 8),
        SizedBox(
          height: 34,
          width: double.infinity,
          // Файл может скачаться раньше срока: тогда столбики готового замера растягиваются на всю ширину.
          child: CustomPaint(
              painter: _SpeedBars(samples, active ? C.orange : C.orange.withValues(alpha: 0.45),
                  active || samples.isEmpty ? SpeedTest.ticks : samples.length)),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: active ? r.progress : (samples.isEmpty ? 0 : 1)),
            duration: SpeedTest.tick,
            builder: (context, shown, _) => LinearProgressIndicator(
                value: shown, minHeight: 3, backgroundColor: C.border, color: active ? C.orange : C.muted),
          ),
        ),
        const SizedBox(height: 6),
        Text(
            active
                ? 'идёт замер…'
                : waiting
                    ? 'ждёт очереди'
                    : (result != null ? 'скачивание' : (error ?? '—')),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: C.muted, fontSize: 11)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = state.speedReport;
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _cardTitle(Icons.downloading_rounded, 'Скорость',
            'Несколько секунд качаем проверочный файл через VPN и напрямую — видно, режет ли VPN скорость'),
        const SizedBox(height: 14),
        Row(children: [
          GhostButton(
            label: 'Замерить',
            icon: Icons.speed_rounded,
            busy: state.checkingSpeed,
            onPressed: state.isConnected ? state.checkSpeed : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              !state.isConnected
                  ? 'Чтобы замерить скорость, сначала подключитесь к VPN'
                  : state.checkingSpeed
                      ? 'Идёт замер ${r?.stage ?? ''}'
                      : 'Замер тратит трафик подписки: до 100 МБ за раз. Файл берётся с ${SpeedTest.host} и не сохраняется'
                          '${state.killSwitchOn ? '. Включён Kill Switch: замер пойдёт только через VPN' : ''}',
              style: TextStyle(color: C.muted, fontSize: 12),
            ),
          ),
        ]),
        if (r != null) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _gauge('Через VPN', r, 0, r.vpnMbit, r.vpnSamples, r.vpnError),
            _gauge('Напрямую', r, 1, r.directMbit, r.directSamples, r.directError),
          ]),
          if (r.done) ...[
            for (final note in r.notes) _note(note),
            _copy(state, () => r.copyText),
          ],
        ],
      ]),
    );
  }
}

/// Столбики скорости по ходу замера: по одному на каждое сообщение замера, высота — от наибольшего.
class _SpeedBars extends CustomPainter {
  _SpeedBars(this.samples, this.color, this.slots);
  final List<double> samples;
  final Color color;

  /// На сколько столбиков делится ширина.
  final int slots;

  @override
  void paint(Canvas canvas, Size size) {
    final step = size.width / slots, width = step - 2;
    final peak = samples.fold(1.0, (a, b) => a > b ? a : b);
    final paint = Paint()..color = color.withValues(alpha: 0.85);
    final rest = Paint()..color = C.border;
    for (var i = 0; i < slots; i++) {
      final has = i < samples.length;
      // Пустые места — короткими чёрточками: видно, сколько замера ещё впереди.
      final height = has ? (samples[i] / peak * size.height).clamp(2.0, size.height) : 2.0;
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(i * step, size.height - height, width, height), const Radius.circular(1.5)),
          has ? paint : rest);
    }
  }

  // Список пополняется на месте — сравнить его с прежним нельзя.
  @override
  bool shouldRepaint(_SpeedBars old) => true;
}

/// Проверка DNS-серверов подключения: за сколько отвечает каждый, каким путём идёт запрос и далеко ли
/// адреса, которые он называет. Сами серверы выбираются на странице «Маршрутизация».
class _DnsCheckCard extends StatelessWidget {
  const _DnsCheckCard({required this.state});
  final AppState state;

  static String _kind(DnsProbe p) => p.service
      ? 'служебный: узнаёт адреса VPN- и DNS-серверов'
      : (p.domains == 0 ? 'общий' : 'для сайтов из списка (${p.domains})');

  static String _text(DnsProbe p) => [
        '${p.label} — ${_kind(p)}, ${p.path}, ${p.result}'
            '${p.reachMs == null ? '' : ', до названных адресов напрямую ${p.reachMs} мс'}',
        if (p.far) '  • адреса заметно дальше, чем у ${p.nearerLabel} (${p.nearerMs} мс)',
        if (p.slow) '  • дольше, чем ядро ждёт этот сервер (${p.limitMs} мс)',
      ].join('\n');

  Widget _probe(DnsProbe p) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: !p.done
                ? const Spinner(size: 16)
                : Icon(p.ok ? Icons.check_circle_rounded : Icons.error_rounded,
                    size: 16, color: !p.ok ? C.red : (p.slow || p.far ? C.orange : C.green)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.label, style: const TextStyle(fontFamily: 'Consolas', fontSize: 12.5)),
              Text(
                [
                  _kind(p),
                  if (p.done) ...[p.path, p.result] else 'проверяется…',
                ].join(' · '),
                style: TextStyle(color: C.muted, fontSize: 12),
              ),
              if (p.done && p.reachMs != null)
                Text('До адресов, которые он называет, напрямую — ${p.reachMs} мс',
                    style: TextStyle(color: C.muted, fontSize: 12)),
              if (p.done && p.far)
                Text(
                    'Это заметно дальше, чем у ${p.nearerLabel} (${p.nearerMs} мс): сайтам и программам, '
                    'которые идут напрямую, с такими адресами дольше ждать ответа',
                    style: const TextStyle(color: C.orange, fontSize: 12)),
              if (p.done && p.slow)
                Text('Дольше, чем ядро ждёт этот сервер (${p.limitMs} мс): оно успевает уйти к следующему DNS',
                    style: const TextStyle(color: C.orange, fontSize: 12)),
            ]),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) => Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _cardTitle(Icons.dns_rounded, 'Как отвечают DNS-серверы',
              'Спросим каждый DNS-сервер подключения: за сколько он отвечает, каким путём идёт запрос и далеко ли адреса, которые он называет'),
          const SizedBox(height: 14),
          Row(children: [
            GhostButton(
              label: 'Проверить DNS',
              icon: Icons.speed_rounded,
              busy: state.checkingDns,
              onPressed: state.isConnected ? state.checkDns : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                state.isConnected
                    ? 'Какие серверы спрашивать, выбирается в разделе «Маршрутизация», блок «DNS»'
                    : 'Чтобы проверить DNS, сначала подключитесь к VPN',
                style: TextStyle(color: C.muted, fontSize: 12),
              ),
            ),
          ]),
          for (final probe in state.dnsProbes) _probe(probe),
          if (state.dnsProbes.isNotEmpty && !state.checkingDns)
            _copy(state, () => [for (final p in state.dnsProbes) _text(p)].join('\n')),
        ]),
      );
}

/// Отчёт для разбора: версия, настройки и журнал последнего подключения одним файлом.
class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.state});
  final AppState state;

  Future<void> _make(BuildContext context) async {
    final ok = await confirm(
        context,
        'Собрать отчёт?',
        'В журнале есть адреса сайтов, которые открывались при этом подключении '
            '(на уровнях логов info и debug — все). Ключи, ссылки подписок и адреса VPN-серверов '
            'в отчёт не попадают. Пока VPN подключён, записываются адреса DNS-серверов, к которым '
            'ходит программа: по ним можно примерно понять, из какой вы страны. '
            'Отправляйте файл только тому, кому доверяете.',
        ok: 'Собрать');
    if (!ok) return;
    final dir = await WinSys.pickFolder();
    if (dir == null) return;
    try {
      final path = await state.makeReport(dir);
      state.toast('Отчёт сохранён', kind: ToastKind.success, detail: path.split(r'\').last);
    } catch (e) {
      state.toast('Не удалось сохранить отчёт: ${describeNetError(e)}');
    }
  }

  @override
  Widget build(BuildContext context) => Panel(
        child: Row(children: [
          Expanded(
            child: _cardTitle(
                Icons.summarize_rounded,
                'Отчёт для разбора',
                'Версия, настройки и журнал последнего подключения одним файлом — без ключей, ссылок подписок '
                    'и адресов VPN-серверов. Его можно отправить тому, кто помогает разобраться'),
          ),
          const SizedBox(width: 12),
          GhostButton(label: 'Собрать', icon: Icons.summarize_rounded, onPressed: () => _make(context)),
        ]),
      );
}
