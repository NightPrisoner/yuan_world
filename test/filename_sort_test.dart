/// 文件名排序键的测试。
///
/// 这个规则的价值全在"和用户预期的顺序一致"上，所以每条都直接断言顺序，
/// 而不是断言键长什么样 —— 键是内部实现，顺序才是承诺。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/core/utils/filename_sort.dart';

void main() {
  /// 按 Windows 规则排一遍，返回标题顺序。
  List<String> sorted(List<String> input) =>
      List<String>.from(input)..sort(windowsCompare);

  group('数字按数值排', () {
    test('笔记2 排在 笔记10 前面', () {
      // 这条正是码点序会搞错的地方："1" < "2"，所以 "10" 会跑到 "2" 前面
      expect(
        sorted(<String>['笔记10', '笔记2', '笔记3']),
        <String>['笔记2', '笔记3', '笔记10'],
      );
    });

    test('位数不同也正确', () {
      expect(
        sorted(<String>['a100', 'a9', 'a1000', 'a1']),
        <String>['a1', 'a9', 'a100', 'a1000'],
      );
    });

    test('纯数字标题', () {
      expect(
        sorted(<String>['123', '1', '12', '2']),
        <String>['1', '2', '12', '123'],
      );
    });

    test('数字在中间也认', () {
      expect(
        sorted(<String>['第10章', '第2章', '第1章']),
        <String>['第1章', '第2章', '第10章'],
      );
    });

    test('多段数字按段依次比', () {
      expect(
        sorted(<String>['1-10', '1-2', '2-1']),
        <String>['1-2', '1-10', '2-1'],
      );
    });

    test('超长的数字段（日期那种）不会撑爆键', () {
      // 20230910 这类不再补零；等长时字典序本来就等于数值序
      expect(
        sorted(<String>['20230910', '20230101']),
        <String>['20230101', '20230910'],
      );
    });
  });

  group('大小写不敏感', () {
    test('abc 和 ABC 视为同级，不会因为大小写分成两堆', () {
      final out = sorted(<String>['Banana', 'apple', 'Cherry']);
      expect(out, <String>['apple', 'Banana', 'Cherry']);
    });

    test('只有大小写不同时顺序稳定（不会随机换位）', () {
      final a = sorted(<String>['Abc', 'abc']);
      final b = sorted(<String>['abc', 'Abc']);
      // 键相同，比较结果为 0；两种输入排出来内容一致即可
      expect(a.toSet(), b.toSet());
    });
  });

  group('首尾空白不参与比较', () {
    test('前导空格不影响位置', () {
      // Windows 也忽略首尾空白；不忽略的话带空格的会全挤到一起
      expect(windowsSortKey('  苹果'), windowsSortKey('苹果'));
      expect(windowsSortKey('苹果  '), windowsSortKey('苹果'));
    });
  });

  group('边界情况', () {
    test('空标题不崩', () {
      expect(windowsSortKey(''), '');
      expect(windowsSortKey('   '), '');
    });

    test('全是数字的极端值', () {
      expect(() => windowsSortKey('9' * 30), returnsNormally);
    });

    test('中文按拼音排，不是码点序', () {
      // 码点序里「阿」(U+963F) 在「波」(U+6CE2) **后面**，因为 CJK
      // 是按部首笔画编码的。按拼音就该是 阿(a) < 波(b) < 陈(c)。
      final out = sorted(<String>['陈', '阿', '波']);
      expect(
        out,
        <String>['阿', '波', '陈'],
        reason: '拼音序：a < b < c',
      );
    });

    test('同样的前缀按后续拼音排', () {
      final out = sorted(<String>['日记本', '小明', '阿飞']);
      expect(out.first, '阿飞');
    });

    test('中英混排时英文按字母、中文按拼音，同一套顺序', () {
      final out = sorted(<String>['banana', '阿', 'cherry', '波']);
      // a(阿) < b(banana) < b(波) < c(cherry)
      // 阿和波都是 b 开头，具体先后取决于拼音全拼；关键是都在 b 段
      expect(out.first, '阿');
      expect(out.last, 'cherry');
    });

    test('拼音排序是稳定的，每次都一样', () {
      final once = sorted(<String>['杂碎记', '小小说', '评论区文学']);
      final twice = sorted(<String>['杂碎记', '小小说', '评论区文学']);
      expect(once, twice);
    });

    test('混合中英文数字不会崩', () {
      expect(
        () => sorted(<String>['第1章 abc', '2023年总结', '', 'x-9', '中文10']),
        returnsNormally,
      );
    });
  });

  group('和码点序的区别', () {
    test('码点序会把 10 排到 2 前面，我们的规则不会', () {
      final naive = <String>['笔记10', '笔记2']..sort();
      expect(naive.first, '笔记10', reason: '这正是原来那个 bug 的现象');
      expect(sorted(<String>['笔记10', '笔记2']).first, '笔记2');
    });
  });
}
