/// 导出完成后那句提示：图片视频怎么处理、打包在哪。
///
/// 用户的原话：「图片视频都能正常导出了，我让你做的相关提示怎么没有？」
/// 「提示解释一下图片视频等文件会如何如何处理，打包在哪里」。
///
/// 这件事不能靠"用户自己去看文件夹" —— docx / pdf 里图片是嵌进去的，
/// 视频根本不在正文里，用户导出完只看见一个文档，不知道视频跟没跟过来。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/exporter/note_exporter.dart';
import 'package:yuan_world/features/notes/widgets/note_actions.dart';

void main() {
  group('单篇导出', () {
    test('docx：图片说"嵌进文档"，视频说"放在旁边的文件夹"', () {
      final hint = mediaHintOf(
        ExportFormat.docx,
        mediaFolder: '我的笔记.files',
        images: 3,
        videos: 2,
      );
      expect(hint, contains('3 张图片已嵌进文档'));
      expect(hint, contains('2 个视频'));
      expect(hint, contains('我的笔记.files'));
      // 视频不在文档里这件事必须说出来，否则用户以为文档里就能播
      expect(hint, contains('旁边的'));
    });

    test('pdf 说的是 PDF，不是"文档"', () {
      final hint = mediaHintOf(
        ExportFormat.pdf,
        mediaFolder: '我的笔记.files',
        images: 1,
        videos: 1,
      );
      expect(hint, contains('1 张图片已嵌进PDF'));
      expect(hint, contains('1 个视频'));
    });

    test('markdown / txt：提醒"整包一起移动"，否则链接会断', () {
      for (final format in <ExportFormat>[
        ExportFormat.markdown,
        ExportFormat.text,
      ]) {
        final hint = mediaHintOf(
          format,
          mediaFolder: '我的笔记.files',
          images: 2,
          videos: 0,
        );
        expect(hint, contains('2 张图片'));
        expect(hint, contains('整包一起移动'));
        // 这两种格式图片不在文档里，不能说"已嵌进"
        expect(hint, isNot(contains('嵌进')));
      }
    });

    test('没有媒体时不出这句提示', () {
      expect(
        mediaHintOf(
          ExportFormat.docx,
          mediaFolder: '空.files',
          images: 0,
          videos: 0,
        ),
        '',
      );
    });
  });

  group('批量导出', () {
    test('docx / pdf：说清视频在包内每篇自己的文件夹里', () {
      for (final format in <ExportFormat>[
        ExportFormat.docx,
        ExportFormat.pdf,
      ]) {
        final hint = zipMediaHint(format);
        expect(hint, contains('嵌进文档'));
        expect(hint, contains('.files'));
      }
    });

    test('markdown / txt：说清正文里的路径就是包内那个文件夹', () {
      for (final format in <ExportFormat>[
        ExportFormat.markdown,
        ExportFormat.text,
      ]) {
        final hint = zipMediaHint(format);
        expect(hint, contains('.files'));
        expect(hint, contains('整包一起移动'));
      }
    });
  });
}
