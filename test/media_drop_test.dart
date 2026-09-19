/// 拖入媒体：哪些文件能进正文、哪些不能。
///
/// 系统拖拽事件在测试里造不出来（desktop_drop 走的是平台通道），
/// 所以把"认不认这个文件"抽成纯函数 [MediaImporter.splitMediaPaths] 单独测，
/// 页面那边只负责把结果落到光标处。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/media/media_importer.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('yw_drop_'));
  tearDown(() => dir.deleteSync(recursive: true));

  String touch(String name) {
    final f = File('${dir.path}${Platform.pathSeparator}$name');
    f.writeAsBytesSync(<int>[1, 2, 3]);
    return f.path;
  }

  test('图片和视频都认', () {
    final png = touch('图.png');
    final jpg = touch('照片.JPG');
    final mp4 = touch('视频.mp4');
    final mov = touch('片段.mov');

    final r = MediaImporter.splitMediaPaths(<String>[png, jpg, mp4, mov]);
    expect(r.media, <String>[png, jpg, mp4, mov]);
    expect(r.others, isEmpty);
  });

  test('文档、压缩包这些不认（会被跳过并提示）', () {
    final docx = touch('论文.docx');
    final txt = touch('笔记.txt');
    final zip = touch('打包.zip');

    final r = MediaImporter.splitMediaPaths(<String>[docx, txt, zip]);
    expect(r.media, isEmpty);
    expect(r.others, <String>[docx, txt, zip]);
  });

  test('文件夹不认', () {
    final sub = Directory('${dir.path}${Platform.pathSeparator}子文件夹')
      ..createSync();
    final png = touch('图.png');

    final r = MediaImporter.splitMediaPaths(<String>[sub.path, png]);
    expect(r.media, <String>[png]);
    expect(r.others, <String>[sub.path]);
  });

  test('空路径忽略，不会崩', () {
    final r = MediaImporter.splitMediaPaths(<String>['', '']);
    expect(r.media, isEmpty);
    expect(r.others, isEmpty);
  });

  test('扩展名大小写不敏感', () {
    expect(MediaImporter.isMediaPath('A.PNG'), isTrue);
    expect(MediaImporter.isMediaPath('B.Mp4'), isTrue);
    expect(MediaImporter.isMediaPath('C.docx'), isFalse);
  });

  test('没有扩展名的文件不认', () {
    expect(MediaImporter.isMediaPath('README'), isFalse);
  });
}
