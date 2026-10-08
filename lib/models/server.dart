import '../core/util.dart';

class ServerProfile {
  ServerProfile({
    String? id,
    required this.name,
    required this.protocol,
    required this.address,
    required this.port,
    required this.link,
    required this.outbound,
    this.subscriptionId,
    this.delayMs,
    this.warning,
    this.hidden = false,
  }) : id = id ?? newId();

  final String id;
  String name;

  /// Имя протокола Xray: vless, vmess, trojan, shadowsocks, socks, hysteria.
  final String protocol;
  final String address;
  final int port;

  /// Исходная ссылка (или JSON-конфиг) — для копирования и сравнения при обновлении подписки.
  final String link;

  /// Outbound Xray без поля tag.
  final Map<String, dynamic> outbound;

  /// null — сервер добавлен вручную.
  String? subscriptionId;

  /// null — не проверялся, -1 — недоступен.
  int? delayMs;

  /// Предупреждение парсера (например, неподдерживаемый параметр).
  String? warning;

  /// Скрыт с главной и из меню значка в трее; в разделе «Серверы» остаётся.
  bool hidden;

  String get protocolLabel => switch (protocol) {
        'vless' => 'VLESS',
        'vmess' => 'VMess',
        'trojan' => 'Trojan',
        'shadowsocks' => 'Shadowsocks',
        'socks' => 'SOCKS',
        'hysteria' => 'Hysteria2',
        _ => protocol.toUpperCase(),
      };

  String get transportLabel {
    final stream = outbound['streamSettings'];
    if (stream is! Map) return '';
    final parts = <String>[];
    final network = stream['network'];
    if (network is String && network.isNotEmpty && network != 'raw' && network != 'tcp') {
      parts.add(network);
    }
    final security = stream['security'];
    if (security is String && security.isNotEmpty && security != 'none') {
      parts.add(security);
    }
    return parts.join(' · ');
  }

  bool get isUdpOnly => protocol == 'hysteria';

  /// Сервер импортирован из JSON-конфига Xray, а не из ссылки.
  bool get isJson {
    final l = link.trimLeft();
    return l.startsWith('{') || l.startsWith('[');
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'protocol': protocol,
        'address': address,
        'port': port,
        'link': link,
        'outbound': outbound,
        'subscriptionId': subscriptionId,
        'delayMs': delayMs,
        'warning': warning,
        'hidden': hidden,
      };

  factory ServerProfile.fromJson(Map<String, dynamic> j) => ServerProfile(
        id: j['id'] as String?,
        name: j['name'] as String? ?? '',
        protocol: j['protocol'] as String? ?? '',
        address: j['address'] as String? ?? '',
        port: asInt(j['port']) ?? 0,
        link: j['link'] as String? ?? '',
        outbound: Map<String, dynamic>.from(j['outbound'] as Map? ?? const {}),
        subscriptionId: j['subscriptionId'] as String?,
        delayMs: asInt(j['delayMs']),
        warning: j['warning'] as String?,
        hidden: parseBool(j['hidden']),
      );
}
