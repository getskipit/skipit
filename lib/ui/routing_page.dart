import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/dns_check.dart';
import '../core/log_store.dart';
import '../core/site_check.dart';
import '../core/xray_config.dart';
import '../models/routing.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import 'app_menu.dart';
import 'flag_text.dart';
import 'shell.dart';
import 'smooth_scroll.dart';
import 'theme.dart';
import 'widgets.dart';

class RoutingPage extends StatelessWidget {
  const RoutingPage({super.key, this.tabs});

  /// Вкладки раздела «Маршрутизация» (показываются под заголовком).
  final Widget? tabs;

  Future<void> _edit(BuildContext context, AppState state, RoutingProfile? profile) async {
    final result = await showDialog<RoutingProfile>(
      context: context,
      builder: (_) => _RoutingEditor(profile: profile ?? RoutingProfile(name: 'Новый профиль')),
    );
    if (result == null) return;
    final idx = state.routingProfiles.indexWhere((r) => r.id == result.id);
    if (idx >= 0) {
      state.routingProfiles[idx] = result;
    } else {
      state.routingProfiles.add(result);
    }
    state.changed();
    if (state.isConnected && state.settings.selectedRoutingId == result.id) {
      await state.reconnect();
    }
  }

  /// Меню «Создать»: пустой профиль или один из шаблонов.
  Future<void> _createMenu(BuildContext btnContext, AppState state) async {
    final templates = RoutingProfile.templates();
    final choice = await showAppMenu<int>(btnContext, items: [
      const AppMenuItem(-1, 'Пустой профиль', icon: Icons.note_add_outlined),
      const AppMenuItem.divider(),
      for (var i = 0; i < templates.length; i++)
        AppMenuItem(i, 'Шаблон: ${templates[i].name}', icon: Icons.auto_awesome_outlined),
    ]);
    if (choice == null || !btnContext.mounted) return;
    if (choice == -1) {
      await _edit(btnContext, state, null);
      return;
    }
    final p = templates[choice];
    state.routingProfiles.add(p);
    state.setRouting(p.id);
    state.toast('Добавлен профиль «${p.name}»');
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final server = state.selectedServer;
    final provider = server == null ? null : XrayConfig.providerConfig(server);
    final own = state.routingProfiles.where((r) => r.id != RoutingProfile.globalPresetId).toList();
    return Column(children: [
      PageHeader('Маршрутизация', below: tabs, actions: [
        GhostButton(
          label: 'Обновить geo-базы',
          icon: Icons.public_rounded,
          busy: state.updatingGeo,
          onPressed: () async {
            try {
              await state.updateGeoFiles();
              state.toast('geoip.dat и geosite.dat обновлены');
            } catch (e) {
              state.toast('Ошибка загрузки: $e');
            }
          },
        ),
        GhostButton(label: 'Из буфера', icon: Icons.content_paste_rounded, onPressed: () => importFromClipboard(context)),
        Builder(
          builder: (btnContext) => GradientButton(
            label: 'Создать',
            icon: Icons.add_rounded,
            onPressed: () => _createMenu(btnContext, state),
          ),
        ),
      ]),
      Expanded(
        child: ListView(
      primary: true,
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
          children: [
            if (provider != null)
              _ProviderRulesCard(serverName: server!.name, config: provider)
            else if (state.selectedRouting.id == RoutingProfile.globalPresetId)
              Panel(
                child: Row(children: [
                  Icon(Icons.shield_rounded, color: C.cyan),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Особых правил нет — весь трафик идёт через VPN. '
                      'Чтобы пустить часть сайтов напрямую, создайте профиль или добавьте его от провайдера.',
                      style: TextStyle(color: C.muted, fontSize: 13),
                    ),
                  ),
                ]),
              ),
            const SizedBox(height: 14),
            _DnsCard(state: state, fromProvider: provider != null),
            const SizedBox(height: 14),
            _SiteCard(state: state),
            const SizedBox(height: 14),
            if (own.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Text(
                  provider != null ? 'СВОИ ПРОФИЛИ — РАБОТАЮТ ВМЕСТЕ С ПРАВИЛАМИ ПРОВАЙДЕРА' : 'СВОИ ПРОФИЛИ',
                  style: const TextStyle(color: C.orange, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4),
                ),
              ),
              for (final r in own)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _ProfileTile(profile: r, onEdit: () => _edit(context, state, r)),
                ),
            ],
            const SizedBox(height: 8),
            Text(
              'Профиль — это набор правил: какие сайты и IP идут через VPN, какие напрямую, какие блокируются. '
              'Клик по профилю включает его, повторный клик — выключает. С правилами провайдера профиль работает '
              'вместе: из него берутся три списка сайтов и IP, и они решают за то, о чём у провайдера правила нет. '
              'Если сайт есть и там, и там — действует правило провайдера. Профиль от провайдера добавляется '
              'кнопкой «Из буфера» или приходит вместе с подпиской.',
              style: TextStyle(color: C.muted, fontSize: 12),
            ),
          ],
        ),
      ),
    ]);
  }
}

/// Правила из JSON-конфига провайдера — действуют для выбранного сервера вместе с выбранным профилем.
class _ProviderRulesCard extends StatelessWidget {
  const _ProviderRulesCard({required this.serverName, required this.config});
  final String serverName;
  final Map<String, dynamic> config;

  @override
  Widget build(BuildContext context) {
    final s = XrayConfig.summarize(config);
    final balancers = ((config['routing'] as Map?)?['balancers'] as List?)?.length ?? 0;
    final proxies = (config['outbounds'] as List? ?? const [])
        .where((o) => o is Map && !const ['freedom', 'blackhole', 'dns'].contains(o['protocol']))
        .length;

    Widget line(IconData icon, Color color, String title, String text) => Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            SizedBox(width: 120, child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
            Expanded(child: Text(text, style: TextStyle(color: C.muted, fontSize: 13))),
          ]),
        );

    return Panel(
      glow: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.verified_rounded, color: C.cyan),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Правила провайдера', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              const SizedBox(height: 2),
              Row(children: [
                Text('Из JSON-конфига сервера ', style: TextStyle(color: C.muted, fontSize: 12)),
                Flexible(child: FlagText(serverName, maxLines: 1, style: TextStyle(color: C.muted, fontSize: 12))),
              ]),
            ]),
          ),
          Tag('JSON', color: C.cyan),
        ]),
        line(Icons.alt_route_rounded, C.green, 'Напрямую',
            s.direct == 0 ? '—' : '${s.directExamples.join(', ')}${s.direct > s.directExamples.length ? ' и ещё ${s.direct - s.directExamples.length}' : ''}'),
        line(Icons.shield_rounded, C.orange, 'Через VPN',
            'всё остальное${s.proxy > 0 ? ' + отдельные правила: ${s.proxy}' : ''}'
                '${proxies > 1 ? ' · серверов в конфиге: $proxies' : ''}${balancers > 0 ? ', автовыбор' : ''}'),
        if (s.block > 0 || s.blockNotes.isNotEmpty)
          line(Icons.block_rounded, C.red, 'Блокируется', s.blockNotes.isEmpty ? 'правил: ${s.block}' : s.blockNotes.join(', ')),
      ]),
    );
  }
}

/// Чей DNS работает: провайдера (у обычных серверов — из профиля) или свой, с двумя адресами.
class _DnsCard extends StatefulWidget {
  const _DnsCard({required this.state, required this.fromProvider});
  final AppState state;

  /// Выбран сервер с конфигом провайдера: без «Мой DNS» работает DNS из этого конфига.
  final bool fromProvider;

  @override
  State<_DnsCard> createState() => _DnsCardState();
}

class _DnsCardState extends State<_DnsCard> {
  late final _remote = TextEditingController(text: widget.state.settings.ownDnsRemote);
  late final _domestic = TextEditingController(text: widget.state.settings.ownDnsDomestic);

  @override
  void dispose() {
    _remote.dispose();
    _domestic.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final own = state.settings.ownDns;
    final other = widget.fromProvider ? 'из конфига провайдера' : 'из выбранного профиля';
    void apply() => state.setOwnDnsServers(_remote.text, _domestic.text);
    final all = [
      RoutingProfile.splitDns(state.settings.ownDnsRemote),
      RoutingProfile.splitDns(state.settings.ownDnsDomestic),
    ];
    // Чего ядро, которое сейчас отвечает за DNS, из введённого не возьмёт.
    final skipped = all.any((list) => list.any((a) => a.startsWith('tls://')))
        ? 'DoT (tls://) ядро Xray не умеет и такие адреса пропускает — работать будут остальные из списка.'
        : null;

    // Адрес применяется, когда его закончили вводить: по Enter или уходу из поля, а не на каждую букву —
    // подключённый VPN при смене DNS переподключается.
    Widget field(TextEditingController controller, String label, String hint) => Expanded(
          child: Focus(
            onFocusChange: (focused) {
              if (!focused) apply();
            },
            child: TextField(
              controller: controller,
              onSubmitted: (_) => apply(),
              decoration: InputDecoration(
                labelText: label,
                hintText: hint,
                // Значок «i»: подсказка показывается и по наведению, и по клику.
                suffixIcon: Tooltip(
                  message: 'Какие адреса можно вводить:\n'
                      '1.1.1.1 или udp://1.1.1.1 — обычный DNS\n'
                      'tcp://1.1.1.1 — DNS по TCP\n'
                      'https://dns.google/dns-query — DoH\n'
                      'tls://1.1.1.1 — DoT',
                  triggerMode: TooltipTriggerMode.tap,
                  child: const Icon(Icons.info_rounded, size: 18, color: C.orange),
                ),
              ),
            ),
          ),
        );

    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.dns_rounded, color: own ? C.orange : C.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('DNS', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              const SizedBox(height: 2),
              Text(own ? 'Работают свои серверы — вместо DNS $other' : 'Работает DNS $other',
                  style: TextStyle(color: C.muted, fontSize: 12)),
            ]),
          ),
          const SizedBox(width: 12),
          Segmented<bool>(
            value: own,
            items: {false: widget.fromProvider ? 'Провайдера' : 'Из профиля', true: 'Мой DNS'},
            onChanged: state.setOwnDns,
          ),
        ]),
        if (own) ...[
          const SizedBox(height: 14),
          Row(children: [
            field(_remote, 'Удалённые DNS (через VPN)', 'https://1.1.1.1/dns-query, 8.8.8.8'),
            const SizedBox(width: 12),
            field(_domestic, 'Локальные DNS (напрямую)', '77.88.8.8, 77.88.8.1'),
          ]),
          const SizedBox(height: 8),
          Text(
            'Можно указать несколько адресов через запятую: если первый не ответил, спросим следующий. '
            'Например: https://dns.google/dns-query, 8.8.8.8\n'
            'Удалённые — для сайтов через VPN, локальные — для сайтов напрямую. Сохраняется по Enter или когда '
            'вы уходите из поля.',
            style: TextStyle(color: C.muted, fontSize: 12),
          ),
          if (skipped != null) ...[
            const SizedBox(height: 6),
            Text(skipped, style: const TextStyle(color: C.orange, fontSize: 12)),
          ],
        ],
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
                  ? 'Спросим каждый DNS-сервер подключения: за сколько он отвечает, каким путём идёт запрос '
                      'и далеко ли адреса, которые он называет'
                  : 'Чтобы проверить DNS, сначала подключитесь к VPN',
              style: TextStyle(color: C.muted, fontSize: 12),
            ),
          ),
        ]),
        for (final probe in state.dnsProbes) _probe(probe),
      ]),
    );
  }

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
}

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

  /// Плитка с одним замером: подпись, значение и, если есть, адрес под ним.
  Widget _metric(String name, String value, {String? address, Color? color}) => Container(
        constraints: const BoxConstraints(minWidth: 128),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: C.surface2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: C.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(name, style: TextStyle(color: C.muted, fontSize: 11)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: color)),
          if (address != null)
            Text(address, style: TextStyle(color: C.muted, fontSize: 11, fontFamily: 'Consolas')),
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
                _metric('Соединение', 'не открылось', color: C.red)
              else ...[
                _metric('Первое соединение', ms(r.firstMs)),
                _metric('Повторное', ms(r.warmMs)),
                _metric('Ответ сайта', ms(r.replyMs)),
              ],
              if (r.vpnBaseMs != null) _metric('Проверочный адрес через VPN', ms(r.vpnBaseMs)),
              if (r.address != null) _metric('Адрес от DNS ядра, мимо VPN', ms(r.addressMs), address: r.address),
              if (r.otherAddress != null)
                _metric('Адрес от независимого DNS, мимо VPN', ms(r.otherMs), address: r.otherAddress),
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

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({required this.profile, required this.onEdit});
  final RoutingProfile profile;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final selected = state.selectedRouting.id == profile.id;
    final preset = profile.id.startsWith('preset-');
    return Panel(
      glow: selected,
      // Повторный клик по включённому профилю выключает его.
      onTap: () => state.setRouting(selected ? RoutingProfile.globalPresetId : profile.id),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: [
          Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
              color: selected ? C.orange : C.muted),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(profile.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                if (preset) ...[const SizedBox(width: 8), const Tag('по умолчанию')],
                if (profile.subscriptionId != null) ...[const SizedBox(width: 8), Tag('от провайдера', color: C.cyan)],
              ]),
              const SizedBox(height: 3),
              Text(profile.summary, style: TextStyle(color: C.muted, fontSize: 12)),
            ]),
          ),
          IconButton(
            tooltip: 'Поделиться профилем (скопировать ссылку)',
            icon: const Icon(Icons.link_rounded, size: 20),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: profile.toDeeplink()));
              state.toast('Ссылка на профиль скопирована');
            },
          ),
          if (!preset)
            IconButton(tooltip: 'Изменить', icon: const Icon(Icons.edit_rounded, size: 20), onPressed: onEdit),
          if (!preset)
            IconButton(
              tooltip: 'Удалить',
              icon: Icon(Icons.delete_outline_rounded, size: 20, color: C.red),
              onPressed: () async {
                if (!await confirm(context, 'Удалить профиль?', profile.name)) return;
                state.routingProfiles.remove(profile);
                if (state.settings.selectedRoutingId == profile.id) {
                  state.setRouting(RoutingProfile.globalPresetId);
                } else {
                  state.changed();
                }
              },
            ),
      ]),
    );
  }
}

class _RoutingEditor extends StatefulWidget {
  const _RoutingEditor({required this.profile});
  final RoutingProfile profile;

  @override
  State<_RoutingEditor> createState() => _RoutingEditorState();
}

class _RoutingEditorState extends State<_RoutingEditor> {
  final _scroll = SmoothScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  late final p = RoutingProfile.fromJson(widget.profile.toJson());
  late final _name = TextEditingController(text: p.name);
  late final _remoteDns = TextEditingController(text: p.remoteDnsAddress);
  late final _domesticDns = TextEditingController(text: p.domesticDnsAddress);
  late final _lists = {
    'proxySites': TextEditingController(text: p.proxySites.join('\n')),
    'proxyIp': TextEditingController(text: p.proxyIp.join('\n')),
    'directSites': TextEditingController(text: p.directSites.join('\n')),
    'directIp': TextEditingController(text: p.directIp.join('\n')),
    'blockSites': TextEditingController(text: p.blockSites.join('\n')),
    'blockIp': TextEditingController(text: p.blockIp.join('\n')),
  };
  late final _hosts =
      TextEditingController(text: p.dnsHosts.entries.map((e) => '${e.key} = ${e.value}').join('\n'));

  List<String> _lines(String key) =>
      _lists[key]!.text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  void _save() {
    p.name = _name.text.trim().isEmpty ? 'Профиль' : _name.text.trim();
    p.setDns(remote: _remoteDns.text, domestic: _domesticDns.text);
    p.proxySites = _lines('proxySites');
    p.proxyIp = _lines('proxyIp');
    p.directSites = _lines('directSites');
    p.directIp = _lines('directIp');
    p.blockSites = _lines('blockSites');
    p.blockIp = _lines('blockIp');
    p.dnsHosts = {
      for (final line in _hosts.text.split('\n'))
        if (line.contains('=')) line.split('=').first.trim(): line.split('=').sublist(1).join('=').trim(),
    };
    Navigator.pop(context, p);
  }

  Widget _area(String key, String label, String hint) => Expanded(
        child: TextField(
          controller: _lists[key],
          maxLines: 6,
          minLines: 6,
          style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
          // Примеры видны в пустом поле сразу, а не только когда в него щёлкнули.
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            alignLabelWithHint: true,
            floatingLabelBehavior: FloatingLabelBehavior.always,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Профиль маршрутизации'),
        content: SizedBox(
          width: 760,
          child: SingleChildScrollView(
            controller: _scroll,
            // Сверху — место для подписи первого поля (она стоит на его рамке и иначе срезается краем
            // прокрутки), справа — для полосы прокрутки, чтобы она не ложилась на поля.
            padding: const EdgeInsets.only(top: 8, right: 16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: _name, decoration: const InputDecoration(labelText: 'Название')),
              const SizedBox(height: 12),
              Row(children: [
                const Text('Всё остальное:'),
                const SizedBox(width: 12),
                Segmented<bool>(
                  value: p.globalProxy,
                  items: const {true: 'через VPN', false: 'напрямую'},
                  onChanged: (v) => setState(() => p.globalProxy = v),
                ),
                const Spacer(),
                AppDropdown<String>(
                  value: p.domainStrategy,
                  items: {for (final s in RoutingProfile.domainStrategies) s: s},
                  onChanged: (v) => setState(() => p.domainStrategy = v),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _remoteDns,
                    decoration: const InputDecoration(labelText: 'Удалённый DNS (через VPN)', hintText: 'https://1.1.1.1/dns-query'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _domesticDns,
                    decoration: const InputDecoration(labelText: 'Локальный DNS (напрямую)', hintText: '77.88.8.8'),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'В списках — по одной записи в строке.\n'
                  'Сайты: example.com — сайт со всеми поддоменами; full:example.com — только этот адрес; '
                  'geosite:youtube — готовый список сайтов.\n'
                  'IP: 1.2.3.4 — один адрес; 10.0.0.0/8 — диапазон адресов; geoip:ru — готовый список адресов.',
                  style: TextStyle(color: C.muted, fontSize: 12, height: 1.4),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                _area('proxySites', 'Через VPN — сайты', 'instagram.com\nfull:api.example.com\ngeosite:youtube'),
                const SizedBox(width: 12),
                _area('proxyIp', 'Через VPN — IP', '149.154.167.99\n149.154.160.0/20\ngeoip:ru-blocked'),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                _area('directSites', 'Напрямую — сайты', 'gosuslugi.ru\nfull:lk.example.ru\ngeosite:category-ru'),
                const SizedBox(width: 12),
                _area('directIp', 'Напрямую — IP', '77.88.8.8\n192.168.0.0/16\ngeoip:ru'),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                _area('blockSites', 'Блокировать — сайты', 'ads.example.com\nfull:track.example.com\ngeosite:category-ads-all'),
                const SizedBox(width: 12),
                _area('blockIp', 'Блокировать — IP', '203.0.113.5\n198.51.100.0/24'),
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: _hosts,
                maxLines: 3,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'DNS hosts (домен = IP)',
                  hintText: 'router.home = 192.168.1.1',
                  alignLabelWithHint: true,
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                ),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          GradientButton(label: 'Сохранить', onPressed: _save),
        ],
      );
}
