import 'package:hive_ce_flutter/hive_flutter.dart';

/// 可再生元数据缓存（Bangumi 系列/条目/角色缓存、封面主色缓存），独立存放于 `meta_cache` LazyBox，
/// 按需从磁盘读取，避免冷启动把全书架数百本书的条目与角色长简介全部反序列化常驻 Dart 堆。
///
/// 在只打开了 `session` Box 的单测或旧场景里，优雅回退到 `session`，保证测试和旧代码零破坏。
class MetaCache {
  MetaCache._();

  static const boxName = 'meta_cache';
  static const int _hotLimit = 12;

  static BoxBase? _boundBox;
  static int _gen = 0;

  /// 封面颜色轻量内存缓存（最多 400 个 int，仅十余 KB），供界面同步秒读。
  static Map<String, int>? _ccolorCache;

  /// 刚读/刚写的 Bangumi 条目热点小缓存（最多保留 12 条 LRU）。
  static final _hotMaps = <String, Map>{};

  /// 属于可再生元数据缓存的键名（与 `Backup._isCache` 保持唯一真相来源）。
  static bool isCacheKey(String k) => k == 'ccolor' || k.startsWith('bgm:') || k.startsWith('bgm_');

  static bool get isOpen => Hive.isBoxOpen(boxName) || Hive.isBoxOpen('session');

  static LazyBox? _tryLazyBox() {
    if (!Hive.isBoxOpen(boxName)) return null;
    try {
      return Hive.lazyBox(boxName);
    } on HiveError {
      return null;
    }
  }

  static Box? _tryRegularBox() {
    if (!Hive.isBoxOpen(boxName)) return null;
    try {
      return Hive.box(boxName);
    } on HiveError {
      return null;
    }
  }

  static BoxBase? _activeBox() {
    if (Hive.isBoxOpen(boxName)) return _tryLazyBox() ?? _tryRegularBox();
    if (Hive.isBoxOpen('session')) return Hive.box('session');
    return null;
  }

  static void _syncLifecycle() {
    final cur = _activeBox();
    if (!identical(_boundBox, cur) || (cur != null && !cur.isOpen)) {
      _gen++;
      _hotMaps.clear();
      if (cur == null || cur.name != boxName) _ccolorCache = null;
      _boundBox = cur;
    }
  }

  static Map<String, int> _parseCoverColors(Object? raw) {
    if (raw is! Map) return <String, int>{};
    return <String, int>{
      for (final e in raw.entries)
        if (e.key is String && e.value is int) e.key as String: e.value as int,
    };
  }

  static void _rememberHot(String key, Map value) {
    _hotMaps.remove(key);
    _hotMaps[key] = value;
    while (_hotMaps.length > _hotLimit) {
      _hotMaps.remove(_hotMaps.keys.first);
    }
  }

  /// 打开独立缓存 `LazyBox`，一次性将历史 `session` Box 中残留的缓存键静默迁出，并预加载轻量封面色表。
  static Future<LazyBox> open() async {
    var cache = _tryLazyBox();
    if (cache == null) {
      final reg = _tryRegularBox();
      if (reg != null) await reg.close();
      cache = await Hive.openLazyBox(boxName);
    }
    _syncLifecycle();
    await migrateFromSession();
    final raw = await cache.get('ccolor');
    _ccolorCache = _parseCoverColors(raw);
    return cache;
  }

  /// 将 `session` 中残留的 `bgm:*`、`bgm_*`、`ccolor` 迁入 `meta_cache` 并从 `session` 删除。
  /// 旧版备份恢复后重启也会自动走此逻辑，无需特殊迁移脚本。
  static Future<int> migrateFromSession() async {
    if (!Hive.isBoxOpen(boxName) || !Hive.isBoxOpen('session')) return 0;
    _syncLifecycle();
    final session = Hive.box('session');
    final lazy = _tryLazyBox();
    final reg = lazy == null ? _tryRegularBox() : null;
    final BoxBase? cache = lazy ?? reg;
    if (cache == null) return 0;
    final keys = session.keys.whereType<String>().where(isCacheKey).toList();
    if (keys.isEmpty) return 0;
    for (final k in keys) {
      if (!cache.containsKey(k)) {
        final v = session.get(k);
        if (lazy != null) {
          await lazy.put(k, v);
        } else {
          await reg!.put(k, v);
        }
        if (k == 'ccolor' && v is Map) {
          _ccolorCache = {..._parseCoverColors(v), ...?_ccolorCache};
        }
      }
    }
    await session.deleteAll(keys);
    return keys.length;
  }

  /// 同步读取已缓存的封面主色 ARGB 值。
  static int? peekCoverColor(String url) {
    _syncLifecycle();
    if (Hive.isBoxOpen(boxName)) {
      if (_ccolorCache != null) return _ccolorCache![url];
      return (_tryRegularBox()?.get('ccolor') as Map?)?[url] as int?;
    }
    if (Hive.isBoxOpen('session')) {
      return (Hive.box('session').get('ccolor') as Map?)?[url] as int?;
    }
    return null;
  }

  /// 批量合并写入封面主色（超出 [maxEntries] 时按 LRU 淘汰最早条目），同步更新内存表并落盘。
  static Future<void> putCoverColors(Map<String, int> additions, {int maxEntries = 400}) async {
    if (additions.isEmpty || !isOpen) return;
    _syncLifecycle();
    final lazy = _tryLazyBox();
    final reg = lazy == null ? _tryRegularBox() : null;
    if (lazy != null || reg != null) {
      final base = _ccolorCache ?? _parseCoverColors(lazy != null ? await lazy.get('ccolor') : reg!.get('ccolor'));
      final next = Map<String, int>.of(base);
      for (final e in additions.entries) {
        next.remove(e.key);
        next[e.key] = e.value;
      }
      while (next.length > maxEntries) {
        next.remove(next.keys.first);
      }
      _ccolorCache = next;
      if (lazy != null) {
        await lazy.put('ccolor', next);
      } else {
        await reg!.put('ccolor', next);
      }
      return;
    }
    if (Hive.isBoxOpen('session')) {
      final session = Hive.box('session');
      final next = _parseCoverColors(session.get('ccolor'));
      for (final e in additions.entries) {
        next.remove(e.key);
        next[e.key] = e.value;
      }
      while (next.length > maxEntries) {
        next.remove(next.keys.first);
      }
      await session.put('ccolor', next);
    }
  }

  /// 同步试取热点 Map 缓存（单测只开 `session` 时回退读取 `session`）。
  static Map? peekMap(String key) {
    _syncLifecycle();
    final hot = _hotMaps.remove(key);
    if (hot != null) {
      _hotMaps[key] = hot;
      return hot;
    }
    if (Hive.isBoxOpen(boxName)) {
      final reg = _tryRegularBox();
      if (reg != null) {
        final v = reg.get(key);
        if (v is Map) {
          _rememberHot(key, v);
          return v;
        }
      }
      return null;
    }
    if (Hive.isBoxOpen('session')) {
      return Hive.box('session').get(key) as Map?;
    }
    return null;
  }

  /// 按需异步读取 Map 缓存（先查内存热点与回退 Box，未命中时从 `LazyBox` 磁盘加载并记入热点）。
  static Future<Map?> getMap(String key) async {
    final hit = peekMap(key);
    if (hit != null) return hit;
    if (Hive.isBoxOpen(boxName)) {
      final lazy = _tryLazyBox();
      if (lazy != null) {
        final gen = _gen;
        final v = await lazy.get(key);
        if (v is Map) {
          if (gen == _gen) _rememberHot(key, v);
          return v;
        }
      }
    }
    return null;
  }

  /// 写入条目缓存并同步更新热点 LRU。
  static Future<void> putMap(String key, Map value) async {
    _syncLifecycle();
    if (Hive.isBoxOpen(boxName)) {
      _rememberHot(key, value);
      final lazy = _tryLazyBox();
      if (lazy != null) {
        await lazy.put(key, value);
      } else {
        await _tryRegularBox()?.put(key, value);
      }
      return;
    }
    if (Hive.isBoxOpen('session')) {
      await Hive.box('session').put(key, value);
    }
  }

  /// 释放内存中的 Bangumi 大对象热点缓存（保留极小的封面颜色表 `_ccolorCache`）。
  static void evictMemory() {
    _hotMaps.clear();
  }

  /// 清空所有可再生元数据缓存。
  static Future<void> clear() async {
    _gen++;
    _hotMaps.clear();
    _ccolorCache = Hive.isBoxOpen(boxName) ? <String, int>{} : null;
    if (Hive.isBoxOpen(boxName)) {
      final lazy = _tryLazyBox();
      if (lazy != null) {
        await lazy.clear();
      } else {
        await _tryRegularBox()?.clear();
      }
    }
    if (Hive.isBoxOpen('session')) {
      final session = Hive.box('session');
      final legacy = session.keys.whereType<String>().where(isCacheKey).toList();
      if (legacy.isNotEmpty) await session.deleteAll(legacy);
    }
  }
}
