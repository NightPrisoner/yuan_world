/// 文章目录的测试。
///
/// 目录最容易出的问题是「点进去跳错位置」，所以这里除了抽取逻辑，
/// 还专门验证标题的 block 下标与正文渲染用的是同一套坐标。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/core/utils/text_stats.dart';
import 'package:yuan_world/core/utils/toc.dart';

void main() {
  group('目录抽取', () {
    test('按层级抽出全部标题', () {
      const md = '''
# 一级
正文

## 二级
更多正文

### 三级

## 另一个二级
''';
      final toc = extractToc(md);
      expect(toc.map((e) => e.text).toList(),
          <String>['一级', '二级', '三级', '另一个二级']);
      expect(toc.map((e) => e.level).toList(), <int>[1, 2, 3, 2]);
    });

    test('没有标题就是空目录', () {
      expect(extractToc('只有正文\n\n还有一段'), isEmpty);
      expect(extractToc(''), isEmpty);
    });

    test('正文里的 # 不算标题', () {
      // 行中间出现的 # 是正文内容，不该进目录
      final toc = extractToc('# 真标题\n\n这段话里有 # 号但不是标题');
      expect(toc.length, 1);
      expect(toc.first.text, '真标题');
    });

    test('block 下标与正文渲染用的是同一套坐标', () {
      const md = '# 标题\n\n第一段\n\n## 第二节\n\n第二段';
      final blocks = parseContent(md);
      final toc = extractToc(md);

      for (final e in toc) {
        expect(e.blockIndex, lessThan(blocks.length));
        expect(
          blocks[e.blockIndex].type,
          ContentBlockType.heading,
          reason: '目录指向的 block 必须是标题',
        );
        expect(blocks[e.blockIndex].text.trim(), e.text);
      }
    });

    test('标题里的行内标记会被清掉', () {
      final toc = extractToc('# **重点**标题');
      expect(toc.first.text, '重点标题');
    });

    test('空标题不进目录', () {
      expect(extractToc('#\n\n##'), isEmpty);
    });

    test('六级标题都能抽到', () {
      final toc = extractToc('# a\n## b\n### c\n#### d\n##### e\n###### f');
      expect(toc.map((e) => e.level).toList(), <int>[1, 2, 3, 4, 5, 6]);
    });
  });

  group('层级缩进', () {
    test('最浅的一级作为基准，相对它算缩进', () {
      final toc = extractToc('## 二级\n### 三级\n#### 四级');
      final min = minTocLevel(toc);
      expect(min, 2);
      expect(toc.map((e) => e.depthOf(min)).toList(), <int>[0, 1, 2]);
    });

    test('从一级开始时基准是 1', () {
      final toc = extractToc('# 一\n### 三');
      final min = minTocLevel(toc);
      expect(toc.map((e) => e.depthOf(min)).toList(), <int>[0, 2]);
    });

    test('空目录的基准回落到 1，不会崩', () {
      expect(minTocLevel(const <TocEntry>[]), 1);
    });

    test('缩进有上限，不会无限往右推', () {
      final toc = extractToc('# 一\n###### 六');
      expect(toc.last.depthOf(1), lessThanOrEqualTo(5));
    });
  });
}
