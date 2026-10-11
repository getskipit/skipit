import 'package:flutter/material.dart';

import '../core/dns_check.dart';
import '../core/log_store.dart';
import '../core/site_check.dart';
import '../core/util.dart';
import '../core/windows.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Раздел «Проверка»: всё, чем разбираются, когда что-то работает не так, — почему тормозит сайт, как
/// отвечают DNS-серверы подключения и отчёт для разбора одним файлом.
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

/// «Почему тормозит сайт?»: проверка одного сайта — каким путём он идёт и на что уходит время.
class _SiteCard extends StatefulWidget {
  const _SiteCard({required this.state});
  final AppState state;

  @override
  State<_SiteCard> createState() => _SiteCardState();
}

class _SiteCardState extends State<_SiteCard> {
  final _site = TextEditingController();
  bool _wrong = false;

  @override
  void dispose() {
    _site.dispose();
    super.dispose();
  }

  void _check() {
    final host = SiteCheck.hostOf(_site.text);
    setState(() => _wrong = host == null);
    if (host != null) widget.state.checkSite(host);
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
          Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: color)),
          Text(note,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: C.muted, fontSize: 11, fontFamily: mono ? 'Consolas' : null)),
        ]),
      );

  Widget _note(SiteNote note) {
    final (icon, color) = switch (note.kind) {
      SiteNoteKind.ok => (Icons.check_circle_rounded, C.green),
      SiteNoteKind.info => (Icons.info_rounded, C.orange),
      SiteNoteKind.warn => (Icons.error_rounded, C.orange),
      SiteNoteKind.bad => (Icons.error_rounded, C.red),
    };
    // Вывод — плашкой своего цвета: зелёная «всё в порядке», оранжевая «причина», красная «не открылся».
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

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final r = state.siteReport;
    String ms(int? value) => value == null ? '—' : '$value мс';
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.troubleshoot_rounded, color: C.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Почему тормозит сайт?', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              const SizedBox(height: 2),
              Text('Проверим сайт так, как к нему ходит браузер: каким путём он идёт и на что уходит время',
                  style: TextStyle(color: C.muted, fontSize: 12)),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _site,
              onSubmitted: (_) => _check(),
              decoration: const InputDecoration(labelText: 'Адрес сайта', hintText: 'example.com'),
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
          Text(_wrong ? 'Впишите адрес сайта, например example.com' : 'Чтобы проверить сайт, сначала подключитесь к VPN',
              style: TextStyle(color: _wrong ? C.orange : C.muted, fontSize: 12)),
        ],
        if (r != null) ...[
          const SizedBox(height: 14),
          Row(children: [
            Flexible(
              child: Text(r.host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 13.5, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 10),
            if (r.done)
              Tag(r.path,
                  color: switch (r.route) {
                    ConnRoute.proxy => C.orange,
                    ConnRoute.direct => C.green,
                    ConnRoute.block => C.red,
                    _ => null,
                  })
            else ...[
              const Spinner(size: 14),
              const SizedBox(width: 8),
              Text('проверяется…', style: TextStyle(color: C.muted, fontSize: 12)),
            ],
          ]),
          if (r.done) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (r.firstMs == null)
                _metric('Соединение', 'не открылось', 'этим путём', color: C.red)
              else ...[
                _metric('Первое соединение', ms(r.firstMs), 'вместе с поиском адреса'),
                _metric('Повторное', ms(r.warmMs), 'лучшее из трёх'),
                _metric('Ответ сайта', ms(r.replyMs), 'после соединения'),
              ],
              if (r.vpnBaseMs != null) _metric('Проверочный адрес', ms(r.vpnBaseMs), 'тем же путём через VPN'),
              if (r.address != null) _metric('Адрес от DNS ядра', ms(r.addressMs), r.address!, mono: true),
              if (r.otherAddress != null)
                _metric('Адрес от независимого DNS', ms(r.otherMs), r.otherAddress!, mono: true),
            ]),
            for (final note in r.notes) _note(note),
          ],
        ],
        const SizedBox(height: 10),
        Text(
          'Правила по приложениям на проверку не действуют. Мимо VPN программа обращается только к сайту, '
          'который и так идёт напрямую: открывает соединение с его адресом и спрашивает адрес у Google.',
          style: TextStyle(color: C.muted, fontSize: 12),
        ),
      ]),
    );
  }
}

/// Проверка DNS-серверов подключения: за сколько отвечает каждый, каким путём идёт запрос и далеко ли
/// адреса, которые он называет. Сами серверы выбираются на странице «Маршрутизация».
class _DnsCheckCard extends StatelessWidget {
  const _DnsCheckCard({required this.state});
  final AppState state;

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
                  p.service
                      ? 'служебный: узнаёт адреса VPN- и DNS-серверов'
                      : (p.domains == 0 ? 'общий' : 'для сайтов из списка (${p.domains})'),
                  if (p.done) ...[p.path, p.result] else 'проверяется…',
                ].join(' · '),
                style: TextStyle(color: C.muted, fontSize: 12),
              ),
              if (p.done && p.reachMs != null)
                Text('До адресов, которые он называет, мимо VPN — ${p.reachMs} мс',
                    style: TextStyle(color: C.muted, fontSize: 12)),
              if (p.done && p.far)
                Text(
                    'Это заметно дальше, чем у ${p.nearerLabel} (${p.nearerMs} мс): сайтам и программам, '
                    'которые идут мимо VPN, с такими адресами дольше ждать ответа',
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
