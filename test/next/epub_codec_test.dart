import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ark_novel/next/epub_codec.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _samplePng() => Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

Uint8List _sampleJpeg() => Uint8List.fromList([
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01,
  0x00, 0x01, 0x00, 0x00, 0xFF, 0xD9,
]);

void main() {
  group('EpubBuilder', () {
    test('生成的 EPUB 首项为未压缩 mimetype，且完整包含元数据/封面/两级目录/正文与插图', () {
      final cover = _samplePng();
      final illus1 = _sampleJpeg();
      final illus2 = _samplePng();

      final epubBytes = EpubBuilder.build(
        title: '星与海的彼端 <特别版> & "测试"',
        author: '森见测试',
        description: '第一行简介。\n包含 <XML> & 特殊符号。',
        coverBytes: cover,
        volumes: [
          EpubVolumeData(
            title: '第一卷 启程',
            chapters: [
              EpubChapterData(
                title: '第一章 黎明',
                text: '　　清晨的风吹过海面。\n　　少年拾起了<贝壳> & 地图。',
                images: [(name: 'pic1.jpg', bytes: illus1)],
              ),
              const EpubChapterData(
                title: '第二章 港口',
                text: '远处的汽笛拉响。\n旅途正式开始。',
              ),
            ],
          ),
          EpubVolumeData(
            title: '第二卷 远航',
            chapters: [
              EpubChapterData(
                title: '第三章 风暴',
                text: '雨点砸在甲板上。',
                images: [(name: 'pic2.png', bytes: illus2)],
              ),
            ],
          ),
        ],
      );

      // 1. 原始 ZIP 本地头校验：首项必须是未压缩的 mimetype
      expect(epubBytes[0], 0x50); // 'P'
      expect(epubBytes[1], 0x4B); // 'K'
      expect(epubBytes[2], 0x03);
      expect(epubBytes[3], 0x04);
      final compressionMethod = epubBytes[8] | (epubBytes[9] << 8);
      expect(compressionMethod, 0, reason: 'mimetype 压缩方法必须为 0 (STORE)');
      final nameLen = epubBytes[26] | (epubBytes[27] << 8);
      final extraLen = epubBytes[28] | (epubBytes[29] << 8);
      final firstName = ascii.decode(epubBytes.sublist(30, 30 + nameLen));
      expect(firstName, 'mimetype');
      final mimePayload = ascii.decode(epubBytes.sublist(30 + nameLen + extraLen, 30 + nameLen + extraLen + 20));
      expect(mimePayload, 'application/epub+zip');

      // 2. Archive 内容与 XML 转义校验
      final archive = ZipDecoder().decodeBytes(epubBytes);
      expect(archive.files.first.name, 'mimetype');
      expect(archive.files.first.compression, CompressionType.none);
      final byName = {for (final f in archive.files) f.name: f};
      expect(
        byName.keys,
        containsAll([
          'mimetype',
          'META-INF/container.xml',
          'OEBPS/content.opf',
          'OEBPS/toc.ncx',
          'OEBPS/nav.xhtml',
          'OEBPS/style.css',
          'OEBPS/cover.xhtml',
          'OEBPS/images/cover.png',
          'OEBPS/ch_0001.xhtml',
          'OEBPS/ch_0002.xhtml',
          'OEBPS/ch_0003.xhtml',
          'OEBPS/images/img_0001_001.jpg',
          'OEBPS/images/img_0003_001.png',
        ]),
      );

      String textOf(String path) => utf8.decode(byName[path]!.content as List<int>);
      final opf = textOf('OEBPS/content.opf');
      expect(opf, contains('星与海的彼端 &lt;特别版&gt; &amp; &quot;测试&quot;'));
      expect(opf, contains('<dc:creator>森见测试</dc:creator>'));
      expect(opf, contains('包含 &lt;XML&gt; &amp; 特殊符号。'));
      expect(opf, contains('properties="cover-image"'));

      final nav = textOf('OEBPS/nav.xhtml');
      expect(nav, contains('第一卷 启程'));
      expect(nav, contains('第一章 黎明'));
      expect(nav, contains('第二卷 远航'));

      final ch1 = textOf('OEBPS/ch_0001.xhtml');
      expect(ch1, contains('<p>清晨的风吹过海面。</p>'));
      expect(ch1, contains('<p>少年拾起了&lt;贝壳&gt; &amp; 地图。</p>'));
      expect(ch1, contains('images/img_0001_001.jpg'));

      expect(Uint8List.fromList(byName['OEBPS/images/cover.png']!.content as List<int>), equals(cover));
      expect(Uint8List.fromList(byName['OEBPS/images/img_0001_001.jpg']!.content as List<int>), equals(illus1));
      expect(Uint8List.fromList(byName['OEBPS/images/img_0003_001.png']!.content as List<int>), equals(illus2));
    });
  });

  group('TxtBuilder', () {
    test('生成排版规范的 UTF-8 文本，保留标题/作者/简介/卷章结构与全角缩进', () {
      final bytes = TxtBuilder.build(
        title: '双语测试录',
        author: '作者B',
        description: '这是简介内容',
        volumes: const [
          EpubVolumeData(
            title: '第一卷 起始',
            chapters: [
              EpubChapterData(title: '第一章 黎明', text: '　　第一段话。\n第二段话。'),
            ],
          ),
        ],
      );
      final text = utf8.decode(bytes);
      expect(text, contains('双语测试录'));
      expect(text, contains('作者：作者B'));
      expect(text, contains('简介：\n这是简介内容'));
      expect(text, contains('第一卷 起始'));
      expect(text, contains('第一章 黎明'));
      expect(text, contains('　　第一段话。\n　　第二段话。'));
    });
  });

  group('detectImageFormat', () {
    test('按魔数识别 JPEG / PNG / GIF / WebP，未知字节回退扩展名', () {
      expect(detectImageFormat(_samplePng()).ext, '.png');
      expect(detectImageFormat(_sampleJpeg()).ext, '.jpg');
      expect(detectImageFormat(Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])).ext, '.gif');
      expect(detectImageFormat(Uint8List.fromList([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])).ext, '.webp');
      expect(detectImageFormat(Uint8List.fromList([1, 2, 3]), 'a.webp').ext, '.webp');
    });
  });
}
