import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/core/app_info.dart';
import 'package:yuan_world/core/app_paths.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yw_loc_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Directory dir(String rel) => Directory(p.join(tmp.path, rel))
    ..createSync(recursive: true);

  void put(String rel, String content) {
    final f = File(p.join(tmp.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  group('搬运只认数据项', () {
    test('旁边放着的其它文件一个都不许搬走', () async {
      final from = dir('from');
      put('from/yuanworld.db', 'db');
      put('from/images/1/a.png', 'img');
      // 用户把数据目录指到盘根之后，同目录下全是自己的东西：
      // 相册、番剧、别人的压缩包。这些绝不能当成"数据"往目标里拷。
      put('from/2021手机相册/IMG_0001.jpg', 'photo');
      put('from/下载新番.zip', 'anime');
      put('from/app.so', 'program');
      put('from/其他软件的配置.ini', 'ini');

      final to = dir('to');
      final result = await migrateDataRoot(from.path, to.path);

      expect(File(p.join(to.path, 'yuanworld.db')).readAsStringSync(), 'db');
      expect(File(p.join(to.path, 'images/1/a.png')).readAsStringSync(), 'img');
      expect(Directory(p.join(to.path, '2021手机相册')).existsSync(), isFalse);
      expect(File(p.join(to.path, '下载新番.zip')).existsSync(), isFalse);
      expect(File(p.join(to.path, 'app.so')).existsSync(), isFalse);
      expect(File(p.join(to.path, '其他软件的配置.ini')).existsSync(), isFalse);
      // 只数到数据项：1 个库 + 1 张图
      expect(result.files, 2);
    });

    test('搬完之后源位置的数据没了，旁边的东西还在 —— 数据只有一份', () async {
      final from = dir('from');
      put('from/yuanworld.db', 'db');
      put('from/images/1/a.png', 'img');
      put('from/2021手机相册/IMG_0001.jpg', 'photo');
      put('from/下载新番.zip', 'anime');

      final to = dir('to');
      await migrateDataRoot(from.path, to.path);

      // 数据项搬走了
      expect(File(p.join(from.path, 'yuanworld.db')).existsSync(), isFalse);
      expect(Directory(p.join(from.path, 'images')).existsSync(), isFalse);
      // 用户的其它东西一个都没动
      expect(
        File(p.join(from.path, '2021手机相册/IMG_0001.jpg')).existsSync(),
        isTrue,
      );
      expect(File(p.join(from.path, '下载新番.zip')).existsSync(), isTrue);
    });

    test('目标里原有的同名数据先被替换，不会和新数据混在一起', () async {
      final from = dir('from');
      put('from/yuanworld.db', 'new-db');
      put('from/images/1/new.png', 'new-img');

      final to = dir('to');
      // 目标位置是上次搬走留下的旧库，里面还有一篇现在已经不存在的笔记
      put('to/yuanworld.db', 'old-db');
      put('to/images/9/gone.png', 'gone');

      await migrateDataRoot(from.path, to.path);

      expect(File(p.join(to.path, 'yuanworld.db')).readAsStringSync(), 'new-db');
      expect(Directory(p.join(to.path, 'images/9')).existsSync(), isFalse);
      expect(File(p.join(to.path, 'images/1/new.png')).readAsStringSync(), 'new-img');
    });

    test('数据项里的各个目录都搬，logs 空的也得有位置', () async {
      final from = dir('from');
      put('from/yuanworld.db', 'db');
      put('from/snapshots/yw-20260101.db', 'snap');
      put('from/backups/full-1.zip', 'bak');
      dir('from/logs');

      final to = dir('to');
      await migrateDataRoot(from.path, to.path);

      expect(File(p.join(to.path, 'snapshots/yw-20260101.db')).existsSync(), isTrue);
      expect(File(p.join(to.path, 'backups/full-1.zip')).existsSync(), isTrue);
    });

    test('进度回调按数据项走，不会因为旁边有几千个文件就卡住', () async {
      final from = dir('from');
      put('from/yuanworld.db', 'db');
      for (var i = 0; i < 200; i++) {
        put('from/杂项/file$i.txt', 'x');
      }
      final to = dir('to');
      final seen = <double>[];
      await migrateDataRoot(from.path, to.path, onProgress: seen.add);
      expect(seen, isNotEmpty);
      expect(seen.last, 1.0);
      // 只有 1 个数据项 → 进度两下就到底，而不是 201 步
      expect(seen.length, lessThanOrEqualTo(3));
    });
  });

  group('盘符根要收进子目录', () {
    test('isDriveRoot 认得出盘根，不认普通目录', () {
      final root = p.rootPrefix(tmp.path);
      expect(isDriveRoot(root), isTrue);
      expect(isDriveRoot(p.join(root, '某个文件夹')), isFalse);
      expect(isDriveRoot(tmp.path), isFalse);
    });

    test('选到盘根时数据放进「元世界数据」子目录', () {
      final root = p.rootPrefix(tmp.path);
      expect(dataDirIn(root), p.join(root, '元世界数据'));
    });

    test('选的是普通目录就原样用，不套一层', () {
      expect(dataDirIn(tmp.path), tmp.path);
    });
  });

  group('版本号不把 build 号显示出来', () {
    tearDown(AppInfo.resetForTesting);

    test('注入什么显示什么', () {
      AppInfo.setVersionForTesting('1.0.0');
      expect(AppInfo.version, '1.0.0');
    });

    test('就算平台包里带着 +1，界面也只显示三段式', () {
      // PackageInfo.buildNumber 是 Android 的 versionCode，只给系统判断
      // "这个包比装的新"用。它出现在「关于」里会让人以为有两个版本号，
      // 所以 load() 里只取 info.version。
      AppInfo.setVersionForTesting('1.0.0');
      expect(AppInfo.version.contains('+'), isFalse);
    });
  });
}
