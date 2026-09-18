/// 正文分段（编辑器内联显示图片）的测试。
///
/// 最要紧的一条：**拆分再拼回必须和原文一字不差**。
/// 只要有一处对不上，用户每次编辑都会悄悄改坏正文，
/// 而且这种损坏是累积的、很难回溯。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/features/notes/editor/body_segments.dart';

void main() {
  group('无损往返', () {
    void roundTrip(String body) {
      final segments = splitBodySegments(body);
      expect(
        joinBodySegments(segments),
        body,
        reason: '拆分再拼回必须和原文一致',
      );
    }

    test('各种正文都能原样拼回', () {
      const samples = <String>[
        '',
        '纯文字',
        '第一段\n\n第二段',
        '![](1/a.png)',
        '文字在前\n\n![](1/a.png)',
        '![](1/a.png)\n\n文字在后',
        '上\n![](1/a.png)\n下',
        '![](1/a.png)\n![](1/b.png)',
        '图一\n\n![](1/a.png)\n\n中间文字\n\n![](1/b.png)\n\n结尾',
        // 带说明和标题的图片，拼回时不能被简化
        '![说明](1/a.png)',
        '![说明](1/a.png "标题")',
        // 图片行前后有空格
        '  ![](1/a.png)  ',
        // 末尾有空行
        '文字\n\n',
        // 开头就是空行
        '\n文字',
        // 行内的图片语法不算整行图片，应留在文字里
        '这行有 ![](1/a.png) 但不是单独一行',
      ];
      for (final s in samples) {
        roundTrip(s);
      }
    });

    test('多图长文也逐字节一致', () {
      final body = List.generate(
        30,
        (i) => '段落 $i\n\n![](img/p$i.png)',
      ).join('\n\n');
      roundTrip(body);
    });
  });

  group('分段结果', () {
    test('文字与图片交替', () {
      final segs = splitBodySegments('前\n![](1/a.png)\n后');
      expect(segs.length, 3);
      expect(segs[0], const TextSegment('前'));
      expect(segs[1], const ImageSegment('![](1/a.png)', '1/a.png'));
      expect(segs[2], const TextSegment('后'));
    });

    test('开头就是图片', () {
      final segs = splitBodySegments('![](1/a.png)\n文字');
      expect(segs.first, isA<ImageSegment>());
      expect(segs.last, const TextSegment('文字'));
    });

    test('结尾是图片', () {
      final segs = splitBodySegments('文字\n![](1/a.png)');
      expect(segs.first, const TextSegment('文字'));
      expect(segs.last, isA<ImageSegment>());
    });

    test('连续两张图会拆成两段', () {
      final segs = splitBodySegments('![](1/a.png)\n![](1/b.png)');
      expect(segs.whereType<ImageSegment>().length, 2);
    });

    test('纯文字只有一段', () {
      final segs = splitBodySegments('就是一段话');
      expect(segs.length, 1);
      expect(segs.single, const TextSegment('就是一段话'));
    });

    test('空正文没有段', () {
      expect(splitBodySegments(''), isEmpty);
    });
  });

  group('图片路径识别', () {
    test('剥掉导入阶段遗留的 images/ 前缀', () {
      expect(imagePathOf('![](images/45/1.png)'), '45/1.png');
    });

    test('外链不当成本地图', () {
      expect(imagePathOf('![](https://example.com/a.png)'), isNull);
      expect(isImageLine('![](https://example.com/a.png)'), isTrue,
          reason: '它仍然是"整行图片"，只是本地渲染不了');
    });

    test('空路径不算', () {
      expect(imagePathOf('![]()'), isNull);
    });

    test('行内图片不算整行图片', () {
      expect(isImageLine('前面有字 ![](1/a.png)'), isFalse);
    });

    test('带说明和标题也能取出路径', () {
      expect(imagePathOf('![说明](1/a.png "标题")'), '1/a.png');
    });
  });

  group('保证有落笔的地方', () {
    test('空笔记也必须有文字段', () {
      // 这条对应一个真实 bug：新建笔记后分段结果是空列表，
      // 编辑器一个输入框都没渲染，**完全没法打字**。
      final segs = ensureTextSegment(splitBodySegments(''));
      expect(segs.length, 1);
      expect(segs.single, isA<TextSegment>());
      expect((segs.single as TextSegment).text, '');
    });

    test('正文全是图片时补一个空文字段', () {
      final segs = ensureTextSegment(
        splitBodySegments('![](1/a.png)\n![](1/b.png)'),
      );
      expect(segs.whereType<TextSegment>().length, 1);
      expect(segs.whereType<ImageSegment>().length, 2);
      expect((segs.last as TextSegment).text, '', reason: '补在末尾，落笔在最下面');
    });

    test('已经有文字段就不动它', () {
      final original = splitBodySegments('正文\n![](1/a.png)');
      final segs = ensureTextSegment(original);
      expect(segs, original);
      expect(identical(segs, original), isTrue, reason: '不该白复制一份');
    });

    test('补过的结果仍然能无损拼回', () {
      final segs = ensureTextSegment(splitBodySegments('![](1/a.png)'));
      expect(joinBodySegments(segs), '![](1/a.png)\n');
    });
  });

  group('媒体统计', () {
    test('图片和动图算图，视频算视频', () {
      const md = '正文\n\n![](7/a.png)\n\n![](7/b.gif)\n\n![](7/c.mp4)';
      final m = mediaBreakdown(md);
      expect(m.images, 2, reason: 'gif 也是图');
      expect(m.videos, 1);
    });

    test('总数包含视频', () {
      expect(mediaCountOf('![](7/a.png)\n\n![](7/c.mov)'), 2);
    });

    test('没有媒体时都是 0', () {
      final m = mediaBreakdown('纯文字正文');
      expect(m.images, 0);
      expect(m.videos, 0);
    });

    test('空正文不崩', () {
      expect(mediaCountOf(''), 0);
      expect(mediaBreakdown('').images, 0);
    });
  });

  group('图片序号', () {
    test('按顺序数第几张', () {
      final segs = splitBodySegments('a\n![](1/x.png)\nb\n![](1/y.png)');
      expect(imageIndexOf(segs, 0), 0);
      expect(imageIndexOf(segs, 1), 1);
      expect(imageIndexOf(segs, 3), 2);
    });

    test('总数', () {
      final segs = splitBodySegments('![](1/x.png)\n![](1/y.png)');
      expect(imageCountOf(segs), 2);
    });
  });
}
