import 'dart:convert';
import 'dart:io';

import 'package:ark_novel/next/backup.dart';
import 'package:ark_novel/next/cover_color.dart';
import 'package:ark_novel/next/meta_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ark_meta_cache_test_');
    Hive.init(dir.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('MetaCache.open migrates bgm and ccolor keys out of session while keeping synced keys', () async {
    final session = await Hive.openBox('session');
    await session.putAll({
      'bgm:100': {'id': 1, 'name': 'Test', 'vols': const [], 'x': const [], 't': 123},
      'bgm_info:100': {'id': 1, 't': 123},
      'bgm_chars:100': {'t': 123, 'list': const []},
      'ccolor': {'https://example.com/a.jpg': 0xFF112233},
      'vcover2:100': {'第一卷': 'https://example.com/v1.jpg'},
      'lib:books': {'100': {'title': '测试'}},
    });

    final cache = await MetaCache.open();
    expect(cache.get('bgm:100'), isA<Map>());
    expect(cache.get('bgm_info:100'), isA<Map>());
    expect(cache.get('bgm_chars:100'), isA<Map>());
    expect(cache.get('ccolor'), isA<Map>());

    // 已从核心 session Box 迁出，但需要同步的 vcover2 与书架数据留在 session 中
    expect(session.containsKey('bgm:100'), isFalse);
    expect(session.containsKey('bgm_info:100'), isFalse);
    expect(session.containsKey('bgm_chars:100'), isFalse);
    expect(session.containsKey('ccolor'), isFalse);
    expect(session.containsKey('vcover2:100'), isTrue);
    expect(session.containsKey('lib:books'), isTrue);

    expect(savedCoverColor('https://example.com/a.jpg')?.toARGB32(), 0xFF112233);
  });

  test('MetaCache falls back to session box when meta_cache is not opened', () async {
    final session = await Hive.openBox('session');
    await session.put('ccolor', {'https://example.com/b.jpg': 0xFF445566});
    expect(MetaCache.isOpen, isTrue);
    expect(savedCoverColor('https://example.com/b.jpg')?.toARGB32(), 0xFF445566);
  });

  test('Backup.make excludes cache and local keys while keeping user data', () async {
    final session = await Hive.openBox('session');
    await session.putAll({
      'cookie': 'secret=1',
      'bgm:1': {'id': 1},
      'ccolor': {'a': 1},
      'bookmarks': [
        {'aid': '1', 'cid': '2', 'offset': 0, 'time': 100},
      ],
      'highlights': [
        {'id': 'hl_1', 'aid': '1', 'cid': '2', 'chapter': 'c', 'start': 0, 'end': 3, 'quote': 'abc', 'note': '', 'color': 0, 'at': 100},
      ],
    });
    final raw = jsonDecode(Backup.make()) as Map<String, dynamic>;
    final box = raw['box'] as Map<String, dynamic>;
    expect(box.containsKey('cookie'), isFalse);
    expect(box.containsKey('bgm:1'), isFalse);
    expect(box.containsKey('ccolor'), isFalse);
    expect(box.containsKey('bookmarks'), isTrue);
    expect(box.containsKey('highlights'), isTrue);
  });
}
