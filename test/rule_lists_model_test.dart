import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/models/routing.dart';

void main() {
  group('RuleListSource в профиле маршрутизации', () {
    RoutingProfile profileWithLists() => RoutingProfile(
          name: 'Тест',
          ruleLists: [
            RuleListSource(
              url: 'https://rules.example/list.txt',
              action: 'proxy',
              count: 42,
              updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
            ),
            RuleListSource(url: 'https://rules.example/block.txt', action: 'block'),
          ],
        );

    test('round-trip toJson/fromJson сохраняет адрес, действие, число записей и дату', () {
      final restored = RoutingProfile.fromJson(profileWithLists().toJson());
      expect(restored.ruleLists, hasLength(2));
      expect(restored.ruleLists[0].url, 'https://rules.example/list.txt');
      expect(restored.ruleLists[0].action, 'proxy');
      expect(restored.ruleLists[0].count, 42);
      expect(restored.ruleLists[0].updatedAt, DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect(restored.ruleLists[1].action, 'block');
      expect(restored.ruleLists[1].count, 0);
      expect(restored.ruleLists[1].updatedAt, isNull);
    });

    test('toHapp несёт RuleLists; fromHapp без него даёт пустой список', () {
      final happ = profileWithLists().toHapp();
      expect(happ['RuleLists'], isA<List>());
      expect((happ['RuleLists'] as List).length, 2);

      final plain = RoutingProfile.fromHapp(const {'Name': 'Чужой', 'Unexpected': 'ключ'});
      expect(plain.ruleLists, isEmpty);
    });

    test('updatedAt в JSON — миллисекунды epoch', () {
      final s = RuleListSource(
        url: 'https://rules.example/list.txt',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000123),
      );
      final j = s.toJson();
      expect(j['updatedAt'], 1700000000123);
      expect(RuleListSource.fromJson(j).updatedAt, DateTime.fromMillisecondsSinceEpoch(1700000000123));
      expect(RuleListSource.fromJson(const {'url': 'https://rules.example/x.txt'}).updatedAt, isNull);
    });
  });
}
