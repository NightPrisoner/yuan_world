/// 视频控制条什么时候显示、什么时候收起。
///
/// 用户的两次反馈：
///   · 「鼠标不在视频内，下边这一堆不要显示」
///   · 「未播放或播放完时下边这一堆也不要显示，应该有个图标在视频正中央」
///   · 「全屏播放的时候鼠标不动一定时间下边那一栏不要显示」
///
/// 规则本身抽在 [VideoControlsVisibility] 里（和 UI 无关），这里逐条钉住。
/// 静止超时用很短的时长来测，不真的等 3 秒。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/features/notes/widgets/video_controls_visibility.dart';

const Duration tick = Duration(milliseconds: 25);
const Duration idle = Duration(milliseconds: 40);

/// 等超过一个静止超时周期。
Future<void> waitIdle() => Future<void>.delayed(idle + tick);

VideoControlsVisibility make({void Function()? onChanged}) =>
    VideoControlsVisibility(idleHide: idle, onChanged: onChanged);

void main() {
  test('默认什么都不显示（不做任何事就不该有控件杵着）', () {
    final v = make();
    addTearDown(v.dispose);
    expect(v.barVisible, isFalse);
    expect(v.hovering, isFalse);
  });

  test('鼠标进来就显示', () {
    final v = make();
    addTearDown(v.dispose);
    v.enter();
    expect(v.barVisible, isTrue);
  });

  test('鼠标离开就不显示', () {
    final v = make();
    addTearDown(v.dispose);
    v.enter();
    v.exit();
    expect(v.hovering, isFalse);
    expect(v.barVisible, isFalse);
  });

  test('播放中鼠标静止一段时间后自动收起（全屏看片的关键）', () async {
    final v = make();
    addTearDown(v.dispose);
    v.setPlaying(true);
    v.enter();
    expect(v.barVisible, isTrue, reason: '刚进来应该是显示的');

    await waitIdle();
    expect(v.barVisible, isFalse, reason: '静止超时后该收起');
    expect(v.hovering, isTrue, reason: '鼠标还在画面里，只是没动');
  });

  test('收起后动一下鼠标又出来', () async {
    final v = make();
    addTearDown(v.dispose);
    v.setPlaying(true);
    v.enter();
    await waitIdle();
    expect(v.barVisible, isFalse);

    v.hover();
    expect(v.barVisible, isTrue);

    await waitIdle();
    expect(v.barVisible, isFalse, reason: '再静止还是要收');
  });

  test('暂停时静止不会自动收起（用户正在拖进度条）', () async {
    final v = make();
    addTearDown(v.dispose);
    v.setPlaying(false);
    v.enter();
    await waitIdle();
    expect(v.barVisible, isTrue, reason: '暂停时收起来会让人没法拖进度');
  });

  test('暂停时鼠标离开仍然收起', () {
    final v = make();
    addTearDown(v.dispose);
    v.setPlaying(false);
    v.enter();
    v.exit();
    expect(v.barVisible, isFalse);
  });

  test('播放中鼠标离开立刻收起，不用等超时', () {
    final v = make();
    addTearDown(v.dispose);
    v.setPlaying(true);
    v.enter();
    v.exit();
    expect(v.barVisible, isFalse);
  });

  test('鼠标不在画面里时开始播放：不会凭空冒出控制条', () async {
    final v = make();
    addTearDown(v.dispose);
    v.setPlaying(true);
    await waitIdle();
    expect(v.barVisible, isFalse);
  });

  test('暂停时控制条是显示的：切到暂停会立刻亮出来', () {
    final v = make();
    addTearDown(v.dispose);
    v.setPlaying(true);
    v.enter();
    v.setPlaying(false);
    expect(v.barVisible, isTrue);
  });

  test('只有显隐变化才通知重绘（鼠标移动不能每次都 setState）', () {
    var notified = 0;
    final v = make(onChanged: () => notified++);
    addTearDown(v.dispose);
    v.enter();
    expect(notified, 1);
    // 连续移动：控制条一直是显示状态，不该再通知
    v.hover();
    v.hover();
    v.hover();
    expect(notified, 1, reason: '没变化还通知就是在白白重绘');
  });

  test('重复 enter 不重复通知', () {
    var notified = 0;
    final v = make(onChanged: () => notified++);
    addTearDown(v.dispose);
    v.enter();
    v.enter();
    expect(notified, 1);
  });

  test('dispose 之后定时器不会再改动状态', () async {
    final v = make();
    v.setPlaying(true);
    v.enter();
    v.dispose();
    await waitIdle();
    // 已经是"没被定时器改回 false"之外还要保证不抛异常
    expect(v.barVisible, isTrue);
  });

  // ── 触摸设备（手机）：没有悬停，靠"点画面空白处"切显隐 ──────────────────
  //
  // 用户明确要的分工：
  //   · 空白处 = 显示 ↔ 隐藏控制条（**不碰播放状态**）
  //   · 正中央那个按钮 = 播放 / 暂停 / 重播
  // 起因是他反馈"点空白只是唤起控件、再点一下把控件关掉"——那正是他要的，
  // 我一开始理解反了，把空白处改成了播放/暂停。

  test('手机上点空白处：先亮出来（没有悬停）', () {
    final v = make();
    addTearDown(v.dispose);
    expect(v.hovering, isFalse, reason: '手机就是没有悬停');
    v.toggle();
    expect(v.barVisible, isTrue);
  });

  test('再点一次空白处：收起来（用户要的就是这个）', () {
    final v = make();
    addTearDown(v.dispose);
    v.toggle();
    expect(v.barVisible, isTrue);
    v.toggle();
    expect(v.barVisible, isFalse);
    expect(v.hovering, isFalse);
  });

  test('手动收起后，不会又被自动收起的倒计时"补一刀"', () async {
    final v = make();
    addTearDown(v.dispose);
    v.setPlaying(true);
    v.toggle(); // 亮出来并开始倒计时
    v.toggle(); // 立刻手动收起
    expect(v.barVisible, isFalse);
    await waitIdle();
    expect(v.barVisible, isFalse);
  });

  test('播放中点空白处亮出来，静止到点仍会自动收起', () async {
    final v = make();
    addTearDown(v.dispose);
    v.setPlaying(true);
    v.toggle();
    expect(v.barVisible, isTrue);
    await waitIdle();
    expect(v.barVisible, isFalse, reason: '播放中该自动收');
  });

  test('暂停时点空白处亮出来之后不会自动收（要能拖进度）', () async {
    final v = make();
    addTearDown(v.dispose);
    v.toggle();
    await waitIdle();
    expect(v.barVisible, isTrue);
  });

  test('暂停时控制条一定显示（手机上暂停了却看不到 = 没法拖进度/全屏）', () {
    final v = make();
    addTearDown(v.dispose);
    v.setPlaying(true);
    v.setPlaying(false);
    expect(v.barVisible, isTrue, reason: '暂停必须能看到控制条，哪怕没悬停过');
  });
}
