import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ark_novel/next/rules.dart';
import 'package:hive_ce/hive.dart';

void main() {
  test('按顺序套用规则，支持分组引用', () {
    final rules = [
      const ReplaceRule(pattern: r'(\d+)话', replacement: r'第$1话'),
      const ReplaceRule(pattern: '广告', replacement: ''),
    ];
    expect(ReplaceRules.apply('12话 广告正文', rules), '第12话 正文');
  });

  test('替换串里的分组引用超出捕获组数量时不报错并保留原字符串', () {
    final rules = [
      const ReplaceRule(pattern: r'(\d+)话', replacement: r'第$1话-$2'),
    ];
    expect(ReplaceRules.apply('12话', rules), r'第12话-$2');
  });

  test('停用的和写错的规则被跳过', () {
    final rules = [const ReplaceRule(pattern: 'a', replacement: 'b', enabled: false), const ReplaceRule(pattern: '(', replacement: 'x')];
    expect(ReplaceRules.apply('aaa(', rules), 'aaa(');
    expect(ReplaceRule.validate('('), isNotNull);
    expect(ReplaceRule.validate('a+'), isNull);
  });

  test('高亮规则：先写的优先，重叠的让位，结果按位置排序', () {
    final rules = [
      const ReplaceRule(pattern: '林云', replacement: '', kind: RuleKind.highlight, id: 'a'),
      const ReplaceRule(pattern: '云海|林', replacement: '', kind: RuleKind.highlight, id: 'b'),
      const ReplaceRule(pattern: '广告', replacement: '', id: 'c'),
    ];
    final marks = ReplaceRules.marks('林云看见云海，广告', rules);
    expect([for (final m in marks) (m.start, m.end, m.rule.id)], [(0, 2, 'a'), (4, 6, 'b')]);
  });

  test('高亮规则不参与文字替换', () {
    final rules = [const ReplaceRule(pattern: '林云', replacement: 'X', kind: RuleKind.highlight, id: 'a')];
    expect(ReplaceRules.apply('林云', rules), '林云');
  });

  test('变色规则参与着色但不是高亮；单本书的规则只在那本书生效', () {
    final rules = [
      const ReplaceRule(pattern: '林云', replacement: '', kind: RuleKind.color, id: 'a'),
      const ReplaceRule(pattern: '云海', replacement: '', kind: RuleKind.highlight, id: 'b', aid: '1'),
    ];
    expect([for (final m in ReplaceRules.marks('林云云海', rules, '1')) (m.rule.id, m.rule.kind)], [('a', RuleKind.color), ('b', RuleKind.highlight)]);
    expect([for (final m in ReplaceRules.marks('林云云海', rules, '2')) m.rule.id], ['a']);
    expect(ReplaceRules.apply('林云', rules), '林云');
  });

  test('ReplaceRules.allView 缓存同一引用并在 save / notifyChanged 时刷新与通知', () async {
    final dir = Directory.systemTemp.createTempSync('ark_rules_cache_test');
    Hive.init(dir.path);
    await Hive.openBox('session');
    addTearDown(() async {
      await Hive.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final beforeVer = ReplaceRules.changes.value;
    await ReplaceRules.save(const [ReplaceRule(pattern: '旧词', replacement: '新词', id: 'r1')]);
    expect(ReplaceRules.changes.value, beforeVer + 1);

    final v1 = ReplaceRules.allView();
    final v2 = ReplaceRules.allView();
    expect(identical(v1, v2), isTrue);
    expect(v1.single.pattern, '旧词');

    // all() 返回独立可变副本，修改不影响缓存
    final copy = ReplaceRules.all()..clear();
    expect(copy, isEmpty);
    expect(ReplaceRules.allView().length, 1);

    // 外部直接写入新列表也能自动失效缓存
    await Hive.box('session').put('rules', [
      {'p': '同步词', 'r': '替换', 'e': true, 'k': 0, 'c': 0xFFE53935, 'n': '', 'a': '', 'id': 'r2', 'ts': 1},
    ]);
    ReplaceRules.notifyChanged();
    expect(ReplaceRules.changes.value, beforeVer + 2);
    expect(ReplaceRules.allView().single.pattern, '同步词');

    // 删除 rules 键（变为 null）后 notifyChanged 必须返回空列表，不能命中旧缓存
    await Hive.box('session').delete('rules');
    ReplaceRules.notifyChanged();
    expect(ReplaceRules.allView(), isEmpty);
  });
}
