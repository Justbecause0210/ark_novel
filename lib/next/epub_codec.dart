import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// 单章导出数据（供 EPUB / TXT 生成共用）。
class EpubChapterData {
  const EpubChapterData({required this.title, required this.text, this.images = const []});

  final String title;
  final String text;
  final List<({String name, Uint8List bytes})> images;
}

/// 单卷导出数据（卷标题 + 章节列表）。
class EpubVolumeData {
  const EpubVolumeData({required this.title, required this.chapters});

  final String title;
  final List<EpubChapterData> chapters;
}

/// 根据图片魔数（或文件名后缀兜底）判断 MIME 类型和扩展名。
({String mime, String ext}) detectImageFormat(Uint8List bytes, [String? name]) {
  if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return (mime: 'image/jpeg', ext: '.jpg');
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A) {
    return (mime: 'image/png', ext: '.png');
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38 &&
      (bytes[4] == 0x37 || bytes[4] == 0x39) &&
      bytes[5] == 0x61) {
    return (mime: 'image/gif', ext: '.gif');
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return (mime: 'image/webp', ext: '.webp');
  }
  if (bytes.length >= 4 && bytes[0] == 0x3C) {
    final head = latin1.decode(bytes.take(256).toList(), allowInvalid: true).toLowerCase();
    if (head.contains('<svg')) return (mime: 'image/svg+xml', ext: '.svg');
  }
  final ext = name == null ? '' : p.posix.extension(name).toLowerCase();
  return switch (ext) {
    '.png' => (mime: 'image/png', ext: '.png'),
    '.gif' => (mime: 'image/gif', ext: '.gif'),
    '.webp' => (mime: 'image/webp', ext: '.webp'),
    '.svg' => (mime: 'image/svg+xml', ext: '.svg'),
    _ => (mime: 'image/jpeg', ext: '.jpg'),
  };
}

final _leadingSpaceRe = RegExp(r'^[\s\u3000]+');
final _xmlIllegalControlRe = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]');

/// 剥离 XML 1.0 非法控制字符并转义特殊实体。
String _xmlEscape(String input) {
  final cleaned = input.replaceAll(_xmlIllegalControlRe, '');
  return cleaned
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

String _isoUtcNow() {
  final now = DateTime.now().toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${now.year.toString().padLeft(4, '0')}-${two(now.month)}-${two(now.day)}T${two(now.hour)}:${two(now.minute)}:${two(now.second)}Z';
}

/// 标准 EPUB 3（向下兼容 EPUB 2 NCX）生成器。
class EpubBuilder {
  EpubBuilder._();

  static const _styleCss = '''
body {
  margin: 1em;
  line-height: 1.8;
  font-family: "Noto Serif SC", "Songti SC", "STSong", serif;
}
h1, h2 {
  text-align: center;
  font-weight: bold;
  margin: 1.2em 0 1em;
  line-height: 1.4;
}
p {
  text-indent: 2em;
  margin: 0.45em 0;
}
.illus {
  text-align: center;
  text-indent: 0;
  margin: 1em 0;
}
img {
  max-width: 100%;
  height: auto;
  display: block;
  margin: 0.5em auto;
}
.cover {
  text-align: center;
  margin: 0;
  padding: 0;
}
.cover img {
  max-width: 100%;
  max-height: 100%;
}
''';

  static const _containerXml = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

  static Uint8List build({
    required String title,
    String author = '',
    String description = '',
    Uint8List? coverBytes,
    required List<EpubVolumeData> volumes,
    String language = 'zh-CN',
    String? identifier,
    void Function(int done, int total)? onProgress,
  }) {
    final safeTitle = title.trim().isEmpty ? '未命名书籍' : title.trim();
    final safeAuthor = author.trim();
    final safeDesc = description.trim();
    final bookId = identifier ?? 'urn:uuid:ark-novel-${DateTime.now().millisecondsSinceEpoch}';

    final archive = Archive();

    // 1. mimetype 必须放在 zip 第一个条目且绝不压缩（EPUB OCF 规范要求）
    final mimetypeBytes = ascii.encode('application/epub+zip');
    archive.addFile(ArchiveFile.noCompress('mimetype', mimetypeBytes.length, mimetypeBytes));

    // 2. META-INF/container.xml
    archive.addFile(ArchiveFile.string('META-INF/container.xml', _containerXml));

    // 3. OEBPS/style.css
    archive.addFile(ArchiveFile.string('OEBPS/style.css', _styleCss));

    final manifestItems = <String>[
      '    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
      '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
      '    <item id="style" href="style.css" media-type="text/css"/>',
    ];
    final spineItems = <String>[];

    // 4. 封面（若有）
    final hasCover = coverBytes != null && coverBytes.isNotEmpty;
    String? coverHref;
    if (hasCover) {
      final fmt = detectImageFormat(coverBytes);
      coverHref = 'images/cover${fmt.ext}';
      archive.addFile(ArchiveFile.bytes('OEBPS/$coverHref', coverBytes));
      manifestItems.add('    <item id="cover-image" href="$coverHref" media-type="${fmt.mime}" properties="cover-image"/>');
      manifestItems.add('    <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>');
      spineItems.add('    <itemref idref="cover"/>');
      final coverXhtml = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="${_xmlEscape(language)}">
<head>
  <meta charset="UTF-8"/>
  <title>${_xmlEscape(safeTitle)}</title>
  <link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body class="cover">
  <div class="cover"><img src="$coverHref" alt="${_xmlEscape(safeTitle)}"/></div>
</body>
</html>
''';
      archive.addFile(ArchiveFile.string('OEBPS/cover.xhtml', coverXhtml));
    }

    // 5. 章节 XHTML 与插图
    final nonEmptyVols = [
      for (final v in volumes)
        if (v.chapters.isNotEmpty) v,
    ];
    final totalChapters = nonEmptyVols.fold<int>(0, (s, v) => s + v.chapters.length);
    final tocVolumes = <({String title, List<({String title, String href})> chapters})>[];

    var chIndex = 0;
    for (final vol in nonEmptyVols) {
      final volTitle = vol.title.trim().isEmpty ? '正文' : vol.title.trim();
      final volChapters = <({String title, String href})>[];
      for (final ch in vol.chapters) {
        chIndex++;
        final chNum = chIndex.toString().padLeft(4, '0');
        final chId = 'ch_$chNum';
        final chHref = '$chId.xhtml';
        final chTitle = ch.title.trim().isEmpty ? '第 $chIndex 章' : ch.title.trim();

        final bodyBuf = StringBuffer()..writeln('  <h2>${_xmlEscape(chTitle)}</h2>');
        for (final rawLine in ch.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
          final line = rawLine.replaceFirst(_leadingSpaceRe, '').trimRight();
          if (line.isEmpty) continue;
          bodyBuf.writeln('  <p>${_xmlEscape(line)}</p>');
        }

        var imgIndex = 0;
        for (final img in ch.images) {
          if (img.bytes.isEmpty) continue;
          imgIndex++;
          final fmt = detectImageFormat(img.bytes, img.name);
          final imgId = 'img_${chNum}_${imgIndex.toString().padLeft(3, '0')}';
          final imgHref = 'images/$imgId${fmt.ext}';
          archive.addFile(ArchiveFile.bytes('OEBPS/$imgHref', img.bytes));
          manifestItems.add('    <item id="$imgId" href="$imgHref" media-type="${fmt.mime}"/>');
          bodyBuf.writeln('  <div class="illus"><img src="$imgHref" alt=""/></div>');
        }

        final chXhtml = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="${_xmlEscape(language)}">
<head>
  <meta charset="UTF-8"/>
  <title>${_xmlEscape(chTitle)}</title>
  <link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body>
${bodyBuf.toString()}</body>
</html>
''';
        archive.addFile(ArchiveFile.string('OEBPS/$chHref', chXhtml));
        manifestItems.add('    <item id="$chId" href="$chHref" media-type="application/xhtml+xml"/>');
        spineItems.add('    <itemref idref="$chId"/>');
        volChapters.add((title: chTitle, href: chHref));
        onProgress?.call(chIndex, totalChapters);
      }
      tocVolumes.add((title: volTitle, chapters: volChapters));
    }

    // 6. OEBPS/nav.xhtml（EPUB 3 两级目录：卷 → 章）
    final navBuf = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<!DOCTYPE html>')
      ..writeln('<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="${_xmlEscape(language)}">')
      ..writeln('<head>')
      ..writeln('  <meta charset="UTF-8"/>')
      ..writeln('  <title>目录</title>')
      ..writeln('  <link rel="stylesheet" type="text/css" href="style.css"/>')
      ..writeln('</head>')
      ..writeln('<body>')
      ..writeln('  <nav epub:type="toc" id="toc">')
      ..writeln('    <h1>目录</h1>')
      ..writeln('    <ol>');
    for (final v in tocVolumes) {
      final firstHref = v.chapters.first.href;
      navBuf.writeln('      <li>');
      navBuf.writeln('        <a href="$firstHref">${_xmlEscape(v.title)}</a>');
      navBuf.writeln('        <ol>');
      for (final c in v.chapters) {
        navBuf.writeln('          <li><a href="${c.href}">${_xmlEscape(c.title)}</a></li>');
      }
      navBuf.writeln('        </ol>');
      navBuf.writeln('      </li>');
    }
    navBuf
      ..writeln('    </ol>')
      ..writeln('  </nav>')
      ..writeln('</body>')
      ..writeln('</html>');
    archive.addFile(ArchiveFile.string('OEBPS/nav.xhtml', navBuf.toString()));

    // 7. OEBPS/toc.ncx（EPUB 2 兼容两级目录）
    final ncxBuf = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">')
      ..writeln('  <head>')
      ..writeln('    <meta name="dtb:uid" content="${_xmlEscape(bookId)}"/>')
      ..writeln('    <meta name="dtb:depth" content="2"/>')
      ..writeln('    <meta name="dtb:totalPageCount" content="0"/>')
      ..writeln('    <meta name="dtb:maxPageNumber" content="0"/>')
      ..writeln('  </head>')
      ..writeln('  <docTitle><text>${_xmlEscape(safeTitle)}</text></docTitle>')
      ..writeln('  <navMap>');
    var playOrder = 0;
    for (var vi = 0; vi < tocVolumes.length; vi++) {
      final v = tocVolumes[vi];
      playOrder++;
      ncxBuf
        ..writeln('    <navPoint id="vol_${vi + 1}" playOrder="$playOrder">')
        ..writeln('      <navLabel><text>${_xmlEscape(v.title)}</text></navLabel>')
        ..writeln('      <content src="${v.chapters.first.href}"/>');
      for (var ci = 0; ci < v.chapters.length; ci++) {
        final c = v.chapters[ci];
        playOrder++;
        ncxBuf
          ..writeln('      <navPoint id="ch_${vi + 1}_${ci + 1}" playOrder="$playOrder">')
          ..writeln('        <navLabel><text>${_xmlEscape(c.title)}</text></navLabel>')
          ..writeln('        <content src="${c.href}"/>')
          ..writeln('      </navPoint>');
      }
      ncxBuf.writeln('    </navPoint>');
    }
    ncxBuf
      ..writeln('  </navMap>')
      ..writeln('</ncx>');
    archive.addFile(ArchiveFile.string('OEBPS/toc.ncx', ncxBuf.toString()));

    // 8. OEBPS/content.opf
    final opfBuf = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">')
      ..writeln('  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">')
      ..writeln('    <dc:identifier id="bookid">${_xmlEscape(bookId)}</dc:identifier>')
      ..writeln('    <dc:title>${_xmlEscape(safeTitle)}</dc:title>');
    if (safeAuthor.isNotEmpty) {
      opfBuf.writeln('    <dc:creator>${_xmlEscape(safeAuthor)}</dc:creator>');
    }
    opfBuf.writeln('    <dc:language>${_xmlEscape(language)}</dc:language>');
    if (safeDesc.isNotEmpty) {
      opfBuf.writeln('    <dc:description>${_xmlEscape(safeDesc)}</dc:description>');
    }
    opfBuf.writeln('    <meta property="dcterms:modified">${_isoUtcNow()}</meta>');
    if (hasCover) {
      opfBuf.writeln('    <meta name="cover" content="cover-image"/>');
    }
    opfBuf
      ..writeln('  </metadata>')
      ..writeln('  <manifest>');
    for (final item in manifestItems) {
      opfBuf.writeln(item);
    }
    opfBuf
      ..writeln('  </manifest>')
      ..writeln('  <spine toc="ncx">');
    for (final item in spineItems) {
      opfBuf.writeln(item);
    }
    opfBuf.writeln('  </spine>');
    if (hasCover) {
      opfBuf
        ..writeln('  <guide>')
        ..writeln('    <reference type="cover" title="封面" href="cover.xhtml"/>')
        ..writeln('  </guide>');
    }
    opfBuf.writeln('</package>');
    archive.addFile(ArchiveFile.string('OEBPS/content.opf', opfBuf.toString()));

    return ZipEncoder().encodeBytes(archive);
  }
}

/// 排版干净的 UTF-8 TXT 生成器。
class TxtBuilder {
  TxtBuilder._();

  static Uint8List build({
    required String title,
    String author = '',
    String description = '',
    required List<EpubVolumeData> volumes,
    void Function(int done, int total)? onProgress,
  }) {
    final safeTitle = title.trim().isEmpty ? '未命名书籍' : title.trim();
    final safeAuthor = author.trim();
    final safeDesc = description.trim();
    final buf = StringBuffer()..writeln(safeTitle);
    if (safeAuthor.isNotEmpty) buf.writeln('作者：$safeAuthor');
    if (safeDesc.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('简介：')
        ..writeln(safeDesc);
    }

    final nonEmptyVols = [
      for (final v in volumes)
        if (v.chapters.isNotEmpty) v,
    ];
    final totalChapters = nonEmptyVols.fold<int>(0, (s, v) => s + v.chapters.length);
    var done = 0;

    for (final vol in nonEmptyVols) {
      final volTitle = vol.title.trim();
      if (volTitle.isNotEmpty && (nonEmptyVols.length > 1 || volTitle != '正文')) {
        buf
          ..writeln()
          ..writeln(volTitle);
      }
      for (final ch in vol.chapters) {
        done++;
        final chTitle = ch.title.trim();
        buf
          ..writeln()
          ..writeln(chTitle.isEmpty ? '第 $done 章' : chTitle)
          ..writeln();
        for (final rawLine in ch.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
          final line = rawLine.replaceFirst(_leadingSpaceRe, '').trimRight();
          if (line.isEmpty) continue;
          buf.writeln('　　$line');
        }
        onProgress?.call(done, totalChapters);
      }
    }
    return Uint8List.fromList(utf8.encode(buf.toString()));
  }
}
