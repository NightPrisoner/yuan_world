/// 导出落点的跨平台处理。
///
/// 手机上 `FilePicker.saveFile` 返回的是 SAF 的 document id
/// （`content://…` 或 `/document/msf:1234`），`toFilePath()` 会抛。
/// 导出完还要把图片视频拷到文件旁边，那需要真实目录 —— 所以这条边界
/// 必须有一处统一的判断，不能让每个调用点各自 try/catch。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/features/notes/widgets/note_actions.dart';

void main() {
  group('保存框返回的 Uri', () {
    test('桌面上的 file:// 能拿到真实路径', () {
      final uri = Uri.file(r'E:\笔记\我的文章.docx');
      expect(realPathOf(uri), r'E:\笔记\我的文章.docx');
    });

    test('Android 的 content:// 拿不到路径，返回 null 而不是抛异常', () {
      final uri = Uri.parse(
        'content://com.android.externalstorage.documents/document/'
        'primary%3ADocuments%2F%E6%96%87%E7%AB%A0.docx',
      );
      // 以前这里直接 toFilePath()，抛 Unsupported operation 之后被外层
      // catch 吞掉 —— 表现成"docx 出来了但 .files 文件夹没有"。
      expect(realPathOf(uri), isNull);
    });

    test('Android 的 document id 片段同样拿不到路径', () {
      final uri = Uri.parse('/document/msf:1234');
      expect(realPathOf(uri), isNull);
    });

    test('空路径当成拿不到', () {
      expect(realPathOf(Uri.parse('')), isNull);
    });
  });

  group('给用户看的位置说明', () {
    test('有真实路径就直接用它', () {
      expect(
        describeSavedTarget(Uri.file(r'E:\笔记\a.md')),
        r'E:\笔记\a.md',
      );
    });

    test('拿不到路径时退回文件名，不抛异常', () {
      final uri = Uri.parse(
        'content://com.android.externalstorage.documents/document/'
        'primary%3ADocuments%2F%E6%96%87%E7%AB%A0.docx',
      );
      final text = describeSavedTarget(uri);
      // 至少得是个能看的名字，而且绝不能抛 —— 这句话是塞进 SnackBar 的，
      // 抛出去用户连"已导出"都看不到。
      expect(text, contains('文章.docx'));
      expect(text, isNot(contains('content://')));
    });

    test('路径里没有任何片段时给一句兜底的话', () {
      // 例如 `content://com.android.externalstorage.documents` 这种
      // 只有 authority、没有 document 片段的 Uri。
      expect(
        describeSavedTarget(
          Uri.parse('content://com.android.externalstorage.documents'),
        ),
        '你选择的位置',
      );
    });
  });
}
