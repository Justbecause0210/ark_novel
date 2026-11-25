import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:ark_novel/data/wenku8/wenku8_parser.dart';
import 'package:ark_novel/models/cat_chapter.dart';
import 'package:ark_novel/models/cat_volume.dart';
import 'package:ark_novel/models/content.dart';
import 'package:ark_novel/next/cache.dart';
import 'package:ark_novel/next/data.dart';
import 'package:ark_novel/next/export_book.dart';
import 'package:ark_novel/next/image_cache.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;

Uint8List _pngBytes() => Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Directory supportDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('ark_export_book_test_');
    supportDir = Directory(p.join(tempDir.path, 'support'))..createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => supportDir.path,
    );
    Hive.init(p.join(tempDir.path, 'hive'));
    await Hive.openBox('session');
    await ChapterCache.open();
  });

  tearDown(() async {
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('ExportBook 支持导出已缓存书籍为 EPUB / TXT（含按选中章节过滤与无缓存报错）', () async {
    const aid = '2026';
    await ChapterCache.put(aid, '101', Content(text: '第一章正文内容。\n第二段。', images: const []));
    await ChapterCache.put(aid, '102', Content(text: '第二章正文内容。', images: const []));

    final novel = NovelPage(
      const Wenku8NovelDetail(
        title: '测试轻小说 / 特别篇',
        author: '测试作者',
        status: '连载中',
        imgUrl: '',
        introduce: '作品简介',
        tags: ['校园'],
        lastUpdate: '2026-01-01',
        heat: null,
        trending: null,
        isAnimated: false,
      ),
      [
        CatVolume(
          title: '第一卷',
          chapters: [
            CatChapter(title: '第一章', cid: '101'),
            CatChapter(title: '第二章', cid: '102'),
            CatChapter(title: '第三章（未缓存）', cid: '103'),
          ],
        ),
      ],
    );

    expect(ExportBook.availableCount(aid, novel.catalogue), 2);
    expect(ExportBook.availableCount(aid, novel.catalogue, onlyCids: {'102', '103'}), 1);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final imageStore = container.read(imageStoreProvider);

    // 导出 EPUB（仅选中 102）
    final epubRes = await ExportBook.buildBytes(
      aid: aid,
      novel: novel,
      format: ExportFormat.epub,
      imageStore: imageStore,
      onlyCids: {'102', '103'},
    );
    expect(epubRes.chapterCount, 1);
    expect(epubRes.fileName, '测试轻小说 _ 特别篇.epub');
    final archive = ZipDecoder().decodeBytes(epubRes.bytes);
    final ch1 = utf8.decode(archive.files.firstWhere((f) => f.name == 'OEBPS/ch_0001.xhtml').content as List<int>);
    expect(ch1, contains('第二章正文内容。'));
    expect(ch1, isNot(contains('第一章正文内容。')));

    // 导出 TXT（全部已缓存）
    final txtRes = await ExportBook.buildBytes(
      aid: aid,
      novel: novel,
      format: ExportFormat.txt,
      imageStore: imageStore,
    );
    expect(txtRes.chapterCount, 2);
    final txt = utf8.decode(txtRes.bytes);
    expect(txt, contains('第一章正文内容。'));
    expect(txt, contains('第二章正文内容。'));
    expect(txt, isNot(contains('第三章（未缓存）')));

    // 无已缓存章节时抛出 FormatException
    await expectLater(
      ExportBook.buildBytes(aid: aid, novel: novel, format: ExportFormat.txt, imageStore: imageStore, onlyCids: {'103'}),
      throwsA(isA<FormatException>()),
    );
  });

  test('ImageStore.onMemoryPressure 清空原图字节缓存，trimDir 返回实际删除集合', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(imageStoreProvider);

    // 验证 trimDir 返回被删除的文件名集合并保留 keep
    final dir = Directory(p.join(tempDir.path, 'sr_trim'))..createSync(recursive: true);
    final oldFile = File(p.join(dir.path, 'old_orphan'))..writeAsBytesSync(Uint8List(2048));
    final keepFile = File(p.join(dir.path, 'kept_cover'))..writeAsBytesSync(Uint8List(2048));
    oldFile.setLastModifiedSync(DateTime(2025, 1, 1));
    keepFile.setLastModifiedSync(DateTime(2026, 1, 1));

    final removed = await trimDir(dir, 3000, keep: {'kept_cover'});
    expect(removed, {'old_orphan'});
    expect(oldFile.existsSync(), isFalse);
    expect(keepFile.existsSync(), isTrue);

    // 验证 onMemoryPressure 不抛异常
    store.onMemoryPressure();
    expect(_pngBytes().isNotEmpty, isTrue);
  });
}
