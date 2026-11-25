import 'package:hive_ce_flutter/hive_flutter.dart';

/// 可再生元数据缓存（Bangumi 系列/条目/角色缓存、封面主色缓存），独立存放于 `meta_cache` Box，
/// 避免把数百 KB～数 MB 的缓存塞进核心 `session` Box 拖慢冷启动。
///
/// 在只打开了 `session` Box 的单测或旧场景里，优雅回退到 `session`，保证测试和旧代码零破坏。
class MetaCache {
  MetaCache._();

  static const boxName = 'meta_cache';

  /// 属于可再生元数据缓存的键名（与 `Backup._isCache` 保持唯一真相来源）。
  static bool isCacheKey(String k) => k == 'ccolor' || k.startsWith('bgm:') || k.startsWith('bgm_');

  static bool get isOpen => Hive.isBoxOpen(boxName) || Hive.isBoxOpen('session');

  static Box get box => Hive.isBoxOpen(boxName) ? Hive.box(boxName) : Hive.box('session');

  /// 打开独立缓存 Box，并一次性将历史 `session` Box 中残留的缓存键静默迁出。
  static Future<Box> open() async {
    final cache = await Hive.openBox(boxName);
    await migrateFromSession();
    return cache;
  }

  /// 将 `session` 中残留的 `bgm:*`、`bgm_*`、`ccolor` 迁入 `meta_cache` 并从 `session` 删除。
  /// 旧版备份恢复后重启也会自动走此逻辑，无需特殊迁移脚本。
  static Future<int> migrateFromSession() async {
    if (!Hive.isBoxOpen(boxName) || !Hive.isBoxOpen('session')) return 0;
    final session = Hive.box('session');
    final cache = Hive.box(boxName);
    final keys = session.keys.whereType<String>().where(isCacheKey).toList();
    if (keys.isEmpty) return 0;
    final toPut = <String, Object?>{};
    for (final k in keys) {
      if (!cache.containsKey(k)) toPut[k] = session.get(k);
    }
    if (toPut.isNotEmpty) await cache.putAll(toPut);
    await session.deleteAll(keys);
    return keys.length;
  }

  /// 清空所有可再生元数据缓存。
  static Future<void> clear() async {
    if (Hive.isBoxOpen(boxName)) {
      await Hive.box(boxName).clear();
    }
    if (Hive.isBoxOpen('session')) {
      final session = Hive.box('session');
      final legacy = session.keys.whereType<String>().where(isCacheKey).toList();
      if (legacy.isNotEmpty) await session.deleteAll(legacy);
    }
  }
}
