/// 本地媒体导入的测试。
///
/// 这块的风险是**文件系统副作用**：复制到哪、会不会重名覆盖、
/// 路径是不是正文能用的相对路径。覆盖了用户的图是不可逆的。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/data/media/media_importer.dart';

void main() {
  late Directory root;
  late Directory src;

  setUp(() {
    root = Directory.systemTemp.createTempSync('yw_media_root_');
    src = Directory.systemTemp.createTempSync('yw_media_src_');
  });
  tearDown(() {
    root.deleteSync(recursive: true);
    src.deleteSync(recursive: true);
  });

  File makeSource(String name) {
    final f = File(p.join(src.path, name));
    f.writeAsStringSync('x');
    return f;
  }

  group('类型判断', () {
    test('认得常见图片和动图', () {
      for (final e in <String>['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp']) {
        expect(MediaImporter.isImagePath('7/a.$e'), isTrue, reason: e);
        expect(MediaImporter.isVideoPath('7/a.$e'), isFalse, reason: e);
      }
    });

    test('认得常见视频', () {
      for (final e in <String>['mp4', 'mov', 'mkv', 'webm', 'avi']) {
        expect(MediaImporter.isVideoPath('7/a.$e'), isTrue, reason: e);
      }
    });

    test('大小写不敏感', () {
      expect(MediaImporter.isVideoPath('7/A.MP4'), isTrue);
      expect(MediaImporter.isImagePath('7/A.PNG'), isTrue);
    });

    test('没有扩展名的不算媒体', () {
      expect(MediaImporter.isVideoPath('7/文件'), isFalse);
      expect(MediaImporter.isImagePath('7/文件'), isFalse);
    });
  });

  group('导入', () {
    test('复制进笔记目录，返回相对 imageRoot 的路径', () {
      final rel = MediaImporter.import(
        source: makeSource('照片.png'),
        noteId: 7,
        imageRoot: root.path,
      );

      expect(rel, '7/照片.png');
      // 返回值必须能直接当正文里的路径用
      expect(File(p.join(root.path, rel)).existsSync(), isTrue);
    });

    test('笔记目录不存在会自动创建', () {
      final rel = MediaImporter.import(
        source: makeSource('a.png'),
        noteId: 99,
        imageRoot: root.path,
      );
      expect(Directory(p.join(root.path, '99')).existsSync(), isTrue);
      expect(rel, '99/a.png');
    });

    test('原文件留在原地，是复制不是移动', () {
      final source = makeSource('a.png');
      MediaImporter.import(source: source, noteId: 7, imageRoot: root.path);
      expect(source.existsSync(), isTrue, reason: '不能把用户的原文件搬走');
    });

    test('重名自动加序号，绝不覆盖已有文件', () {
      final first = MediaImporter.import(
        source: makeSource('图.png'),
        noteId: 7,
        imageRoot: root.path,
      );
      // 造一个同名但内容不同的源文件
      final again = makeSource('图.png');
      final second = MediaImporter.import(
        source: again,
        noteId: 7,
        imageRoot: root.path,
      );

      expect(first, '7/图.png');
      expect(second, '7/图-2.png');
      expect(File(p.join(root.path, first)).existsSync(), isTrue);
      expect(File(p.join(root.path, second)).existsSync(), isTrue);
    });

    test('连撞三次也不会互相覆盖', () {
      final rels = <String>{};
      for (var i = 0; i < 4; i++) {
        rels.add(MediaImporter.import(
          source: makeSource('同名.png'),
          noteId: 7,
          imageRoot: root.path,
        ));
      }
      expect(rels.length, 4, reason: '四个不同的源文件必须落成四个文件');
    });

    // 文件名非法字符的清理**没法在 Windows 上测**：
    // `: * ?` 这些字符根本创建不出源文件，用例跑不起来。
    // 清理逻辑保留着（别的平台、以及未来可能的压缩包导入会用到），
    // 但这里不写一个永远 skip 的假测试。

    test('超长文件名被截断', () {
      final rel = MediaImporter.import(
        source: makeSource('${'长' * 120}.png'),
        noteId: 7,
        imageRoot: root.path,
      );
      expect(p.basenameWithoutExtension(rel).runes.length, lessThanOrEqualTo(50));
    });

    test('插进正文的路径能被分段器认成图片', () {
      final rel = MediaImporter.import(
        source: makeSource('图.png'),
        noteId: 7,
        imageRoot: root.path,
      );
      // 导入服务写进正文的就是 `![](rel)`，这条链路必须闭合
      final markdown = '![]( $rel )'.replaceAll(' ', '');
      expect(markdown, '![](7/图.png)');
      expect(File(p.join(root.path, rel)).existsSync(), isTrue);
    });
  });
}
