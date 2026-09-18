import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/features/stats/stats_charts.dart';

/// 数据可视化的缩放窗口。
///
/// 这几个不变量错了图会**静默出错** —— 比如切片长度和轴对不上时，
/// 多线模式画出来是错位的线，但不会抛异常，只能靠测试盯着。
void main() {
  group('trendWindow', () {
    test('不放大时给全量', () {
      final w = trendWindow(24, 1, 0);
      expect(w.start, 0);
      expect(w.end, 24);
    });

    test('放大后窗口变窄', () {
      final w = trendWindow(24, 3, 0);
      expect(w.end - w.start, 8);
      expect(w.start, 0);
    });

    test('窗口右端贴到末尾时不会被裁短', () {
      final w = trendWindow(24, 3, 1);
      expect(w.end, 24);
      expect(w.end - w.start, 8);
    });

    test('倍率再大也至少留 2 个点', () {
      // 只有 3 个桶、放大 12 倍 —— 少于 2 个点 fl_chart 画不出线
      final w = trendWindow(3, 12, 0);
      expect(w.end - w.start, greaterThanOrEqualTo(2));
    });

    test('点太少时忽略缩放', () {
      final w = trendWindow(2, 8, 0.5);
      expect(w.start, 0);
      expect(w.end, 2);
    });

    test('viewStart 越界会被夹住，不产生负下标', () {
      for (final v in <double>[-5, -0.01, 1.5, 99]) {
        final w = trendWindow(30, 4, v);
        expect(w.start, greaterThanOrEqualTo(0));
        expect(w.end, lessThanOrEqualTo(30));
        expect(w.end, greaterThan(w.start));
      }
    });

    test('平移过程中窗口长度恒定', () {
      const n = 40;
      const zoom = 5.0;
      final expected = (n / zoom).ceil();
      for (var i = 0; i <= 20; i++) {
        final w = trendWindow(n, zoom, i / 20);
        expect(w.end - w.start, expected, reason: 'viewStart=${i / 20}');
      }
    });

    test('窗口严格跟着 viewStart 单调右移', () {
      var prev = -1;
      for (var i = 0; i <= 10; i++) {
        final w = trendWindow(40, 4, i / 10);
        expect(w.start, greaterThanOrEqualTo(prev));
        prev = w.start;
      }
    });
  });

  group('sliceRange', () {
    test('正常区间', () {
      expect(sliceRange(<int>[0, 1, 2, 3, 4], 1, 4), <int>[1, 2, 3]);
    });

    test('越界不抛异常，只返回能取到的部分', () {
      // 某条序列比轴短（那个文件夹在窗口里没有数据）时会走到这里
      expect(sliceRange(<int>[0, 1, 2], 1, 99), <int>[1, 2]);
      expect(sliceRange(<int>[0, 1, 2], 5, 9), isEmpty);
    });

    test('起点超过终点时给空表而不是反向切片', () {
      expect(sliceRange(<int>[0, 1, 2], 2, 1), isEmpty);
    });
  });
}
