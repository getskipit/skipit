import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/dns_check.dart';
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
              'вместе: из него берутся три списка сайтов и IP, всё остальное идёт по правилам провайдера; если сайт '
              'есть и там, и там — решает ваш профиль. Профиль от провайдера добавляется '
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
          child: Tooltip(
            message: 'Виды адресов: 1.1.1.1 или udp://… — обычный DNS, tcp://… — по TCP, '
                'https://… — DoH, tls://… — DoT',
            waitDuration: const Duration(milliseconds: 500),
            child: Focus(
              onFocusChange: (focused) {
                if (!focused) apply();
              },
              child: TextField(
                controller: controller,
                onSubmitted: (_) => apply(),
                decoration: InputDecoration(labelText: label, hintText: hint),
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
                  ? 'Спросим каждый DNS-сервер подключения: за сколько он отвечает и каким путём идёт запрос'
                  : 'Проверка работает, пока VPN подключён',
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
                    size: 16, color: !p.ok ? C.red : (p.slow ? C.orange : C.green)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.label, style: const TextStyle(fontFamily: 'Consolas', fontSize: 12.5)),
              Text(
                [
                  p.domains == 0 ? 'общий' : 'для сайтов из списка (${p.domains})',
                  if (p.done) ...[p.path, p.result] else 'проверяется…',
                ].join(' · '),
                style: TextStyle(color: C.muted, fontSize: 12),
              ),
              if (p.done && p.slow)
                Text('Дольше, чем ядро ждёт этот сервер (${p.limitMs} мс): оно успевает уйти к следующему DNS',
                    style: const TextStyle(color: C.orange, fontSize: 12)),
            ]),
          ),
        ]),
      );
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
          decoration: InputDecoration(labelText: label, hintText: hint, alignLabelWithHint: true),
        ),
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Профиль маршрутизации'),
        content: SizedBox(
          width: 760,
          child: SingleChildScrollView(
            controller: _scroll,
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
              Row(children: [
                _area('proxySites', 'Через VPN — сайты', 'geosite:youtube\ninstagram.com'),
                const SizedBox(width: 12),
                _area('proxyIp', 'Через VPN — IP', 'geoip:ru-blocked\n149.154.160.0/20'),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                _area('directSites', 'Напрямую — сайты', 'geosite:category-ru\ndomain:ru'),
                const SizedBox(width: 12),
                _area('directIp', 'Напрямую — IP', 'geoip:ru\ngeoip:private'),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                _area('blockSites', 'Блокировать — сайты', 'geosite:category-ads-all'),
                const SizedBox(width: 12),
                _area('blockIp', 'Блокировать — IP', ''),
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: _hosts,
                maxLines: 3,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                decoration: const InputDecoration(labelText: 'DNS hosts (домен = IP)', alignLabelWithHint: true),
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
