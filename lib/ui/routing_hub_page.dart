import 'package:flutter/material.dart';

import 'apps_page.dart';
import 'routing_page.dart';
import 'smooth_scroll.dart';
import 'widgets.dart';
import '../l10n/l10n.dart';

/// Раздел «Маршрутизация»: правила по сайтам и IP и правила по приложениям на двух вкладках.
class RoutingHubPage extends StatefulWidget {
  const RoutingHubPage({super.key});

  @override
  State<RoutingHubPage> createState() => _RoutingHubPageState();
}

class _RoutingHubPageState extends State<RoutingHubPage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = Segmented<int>(
      value: _tab,
      items: {0: tr('Сайты и IP'), 1: tr('Приложения')},
      onChanged: (t) => setState(() => _tab = t),
    );
    // У каждой вкладки свой контроллер прокрутки: списки не должны делить один на двоих.
    return IndexedStack(index: _tab, children: [
      SmoothPage(child: RoutingPage(tabs: tabs)),
      SmoothPage(child: AppsPage(tabs: tabs)),
    ]);
  }
}
