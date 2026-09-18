/// 隐私空间的密码、密保问题与进入逻辑。
///
/// 安全上的两条底线：
///   1. **改密码/清密码必须先验证原密码** —— 否则任何人拿到设备后
///      打开设置、留空、确定，密码就没了，等于没设。
///   2. **忘记密码要走密保问题**，而不是给一个后门。
///
/// 口令用 FNV-1a 散列存储，**不存明文**。这是本机单机应用的"防顺手一看"
/// 场景，不是抗离线爆破场景 —— 但明文是绝对不能存的。
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/theme/app_theme.dart';

const String kPrivacyPasswordKey = 'privacy.password_hash';
const String kPrivacyQuestionKey = 'privacy.question';
const String kPrivacyAnswerKey = 'privacy.answer_hash';

/// PBKDF2 迭代次数。
///
/// 取 2 万而不是常见的 10 万：PBKDF2 在**纯 Dart** 里跑，而且是在 UI 线程上，
/// 迭代次数太高会让"点解锁 → 卡住好几秒"。2 万已经比原来的 FNV-1a
/// 高出不知道多少个数量级 —— 那个函数对一个 4 位密码可以瞬间穷举完。
const int kPbkdf2Iterations = 20000;

final Random _rng = Random.secure();

String _newSalt() =>
    base64Url.encode(List<int>.generate(16, (_) => _rng.nextInt(256)));

/// PBKDF2-HMAC-SHA256。
///
/// 没有引第三方实现，因为算法本身只有十几行 ——
/// 多一个依赖就多一份供应链风险，而这个函数是安全边界。
List<int> _pbkdf2(String password, List<int> salt, int iterations, int length) {
  final hmac = Hmac(sha256, utf8.encode(password));
  final out = <int>[];
  var block = 1;

  while (out.length < length) {
    final blockBytes = <int>[
      ...salt,
      (block >> 24) & 0xFF,
      (block >> 16) & 0xFF,
      (block >> 8) & 0xFF,
      block & 0xFF,
    ];
    var u = hmac.convert(blockBytes).bytes;
    final acc = List<int>.from(u);

    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < acc.length; j++) {
        acc[j] ^= u[j];
      }
    }
    out.addAll(acc);
    block++;
  }
  return out.sublist(0, length);
}

/// 把明文口令变成 `pbkdf2$迭代次数$盐$散列`。
///
/// **带盐**：同样的密码在两次设置里会得到不同的串，
/// 别人翻数据库也看不出"这两个地方用的是同一个密码"。
String hashPassword(String raw) {
  final salt = _newSalt();
  final dk = _pbkdf2(raw, base64Url.decode(salt), kPbkdf2Iterations, 32);
  return 'pbkdf2\$$kPbkdf2Iterations\$$salt\$${base64Url.encode(dk)}';
}

/// 老版本的 FNV-1a 散列。
///
/// **只为校验历史密码保留**，新设的密码一律走 PBKDF2。
/// 删掉它的话，已经设过密码的用户会瞬间被锁在门外。
String _legacyHash(String raw) {
  var h = 0x811c9dc5;
  for (final c in raw.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return '${h.toRadixString(16).padLeft(8, '0')}:${raw.length}';
}

/// [needsUpgrade] 为真表示这条是老格式，验证通过后应当换成新的。
typedef VerifyOutcome = ({bool ok, bool needsUpgrade});

VerifyOutcome verifySecret(String raw, String stored) {
  if (stored.isEmpty) return (ok: false, needsUpgrade: false);

  if (stored.startsWith('pbkdf2\$')) {
    final parts = stored.split('\$');
    if (parts.length != 4) return (ok: false, needsUpgrade: false);
    final iterations = int.tryParse(parts[1]) ?? kPbkdf2Iterations;
    List<int> salt;
    try {
      salt = base64Url.decode(parts[2]);
    } catch (_) {
      return (ok: false, needsUpgrade: false);
    }
    final dk = _pbkdf2(raw, salt, iterations, 32);
    return (ok: base64Url.encode(dk) == parts[3], needsUpgrade: false);
  }

  return (ok: _legacyHash(raw) == stored, needsUpgrade: true);
}

/// 密保答案的比较键：大小写和首尾空格都不计较（它不是密码）。
String answerKey(String raw) => raw.trim().toLowerCase();

bool hasPrivacyPassword(AppState state) =>
    (state.repo.getSetting(kPrivacyPasswordKey) ?? '').isNotEmpty;

bool hasSecurityQuestion(AppState state) =>
    (state.repo.getSetting(kPrivacyQuestionKey) ?? '').isNotEmpty;

/// 进入隐私空间。没密码直接进，有密码验一下就进 —— 不再有中间页。
Future<bool> enterPrivacySpace(BuildContext context) async {
  final state = context.read<AppState>();
  if (!hasPrivacyPassword(state)) {
    state.enterPrivacyMode();
    return true;
  }
  final ok = await verifyPassword(context);
  if (!ok) return false;
  state.enterPrivacyMode();
  return true;
}

// ── 验证密码 ──────────────────────────────────────────────────────────────

/// 弹密码框。验过返回 true。
///
/// 底下带一个「忘记密码」——有密保问题才能走通，没有就只能取消。
Future<bool> verifyPassword(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => const _VerifyDialog(),
  );
  return result ?? false;
}

class _VerifyDialog extends StatefulWidget {
  const _VerifyDialog();

  @override
  State<_VerifyDialog> createState() => _VerifyDialogState();
}

class _VerifyDialogState extends State<_VerifyDialog> {
  final _input = TextEditingController();
  bool _wrong = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final state = context.read<AppState>();
    final stored = state.repo.getSetting(kPrivacyPasswordKey) ?? '';
    final outcome = verifySecret(_input.text, stored);
    if (outcome.ok) {
      // 老格式（FNV）在验证通过后顺手升级成 PBKDF2 ——
      // 用户不会因为"没重新设密码"就一直留在弱散列上
      if (outcome.needsUpgrade) {
        state.repo.setSetting(kPrivacyPasswordKey, hashPassword(_input.text));
      }
      Navigator.pop(context, true);
      return;
    }
    setState(() => _wrong = true);
    HapticFeedback.heavyImpact();
  }

  Future<void> _forgot() async {
    final state = context.read<AppState>();
    if (!hasSecurityQuestion(state)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有设置密保问题，无法找回')),
      );
      return;
    }
    final ok = await verifySecurityAnswer(context);
    if (!ok || !mounted) return;
    // 密保通过了，等价于验证过身份，直接放行
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('输入密码'),
      content: SizedBox(
        width: 280,
        child: TextField(
          controller: _input,
          autofocus: true,
          obscureText: true,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: '密码',
            errorText: _wrong ? '密码不对' : null,
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _forgot, child: const Text('忘记密码')),
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        TextButton(onPressed: _submit, child: const Text('进入')),
      ],
    );
  }
}

// ── 密保问题 ──────────────────────────────────────────────────────────────

/// 回答密保问题。答对返回 true。
Future<bool> verifySecurityAnswer(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => const _AnswerDialog(),
  );
  return result ?? false;
}

class _AnswerDialog extends StatefulWidget {
  const _AnswerDialog();

  @override
  State<_AnswerDialog> createState() => _AnswerDialogState();
}

class _AnswerDialogState extends State<_AnswerDialog> {
  final _input = TextEditingController();
  bool _wrong = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final state = context.read<AppState>();
    final stored = state.repo.getSetting(kPrivacyAnswerKey) ?? '';
    final outcome = verifySecret(answerKey(_input.text), stored);
    if (outcome.ok) {
      if (outcome.needsUpgrade) {
        state.repo.setSetting(
          kPrivacyAnswerKey,
          hashPassword(answerKey(_input.text)),
        );
      }
      Navigator.pop(context, true);
      return;
    }
    setState(() => _wrong = true);
    HapticFeedback.heavyImpact();
  }

  @override
  Widget build(BuildContext context) {
    final question =
        context.read<AppState>().repo.getSetting(kPrivacyQuestionKey) ?? '';
    return AlertDialog(
      title: const Text('密保问题'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              question,
              style: AppText.callout.copyWith(
                color: context.colors.label,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _input,
              autofocus: true,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: '答案',
                errorText: _wrong ? '答案不对' : null,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        TextButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }
}

// ── 设置 / 修改 / 清除密码 ────────────────────────────────────────────────

/// 设置或修改密码。
///
/// 已经设过密码时**必须先验原密码** —— 这是关键的一步：
/// 少了它，任何人打开设置留空点确定就把密码清了。
Future<void> showPasswordSetup(BuildContext context) async {
  final state = context.read<AppState>();

  if (hasPrivacyPassword(state)) {
    final ok = await verifyPassword(context);
    if (!ok || !context.mounted) return;
  }

  final result = await showDialog<_PasswordResult>(
    context: context,
    builder: (ctx) => _PasswordDialog(canClear: hasPrivacyPassword(state)),
  );
  if (result == null || !context.mounted) return;

  if (result.clear) {
    state.repo.setSetting(kPrivacyPasswordKey, '');
    state.repo.setSetting(kPrivacyQuestionKey, '');
    state.repo.setSetting(kPrivacyAnswerKey, '');
    _toast(context, '密码与密保问题已清除');
    return;
  }

  state.repo.setSetting(kPrivacyPasswordKey, hashPassword(result.password!));
  if (result.question != null && result.question!.isNotEmpty) {
    state.repo.setSetting(kPrivacyQuestionKey, result.question!);
    state.repo.setSetting(
      kPrivacyAnswerKey,
      hashPassword(answerKey(result.answer ?? '')),
    );
  }
  _toast(context, '密码已更新');
}

/// 单独设置密保问题（已有密码时）。
Future<void> showSecurityQuestionSetup(BuildContext context) async {
  final state = context.read<AppState>();
  if (!hasPrivacyPassword(state)) {
    _toast(context, '请先设置密码');
    return;
  }
  final ok = await verifyPassword(context);
  if (!ok || !context.mounted) return;

  final result = await showDialog<_PasswordResult>(
    context: context,
    builder: (ctx) => _PasswordDialog(canClear: false, questionOnly: true),
  );
  if (result == null || !context.mounted) return;
  if (result.question == null || result.question!.isEmpty) return;

  state.repo.setSetting(kPrivacyQuestionKey, result.question!);
  state.repo.setSetting(
    kPrivacyAnswerKey,
    hashPassword(answerKey(result.answer ?? '')),
  );
  _toast(context, '密保问题已更新');
}

void _toast(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
  );
}

class _PasswordResult {
  const _PasswordResult({this.password, this.question, this.answer, this.clear = false});
  final String? password;
  final String? question;
  final String? answer;
  final bool clear;
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.canClear, this.questionOnly = false});

  /// 已经设过密码时才给「清除密码」——没设过就没什么可清的。
  final bool canClear;

  /// 只改密保问题，不动密码。
  final bool questionOnly;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _a = TextEditingController();
  final _b = TextEditingController();
  final _question = TextEditingController();
  final _answer = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    // 已有密保问题时把问题带出来，改答案时不用重打一遍
    final state = context.read<AppState>();
    _question.text = state.repo.getSetting(kPrivacyQuestionKey) ?? '';
  }

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    _question.dispose();
    _answer.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.questionOnly) {
      if (_question.text.trim().isEmpty || _answer.text.trim().isEmpty) {
        setState(() => _error = '问题和答案都要填');
        return;
      }
      Navigator.pop(
        context,
        _PasswordResult(
          question: _question.text.trim(),
          answer: _answer.text,
        ),
      );
      return;
    }

    final a = _a.text;
    if (a.length < 4) {
      setState(() => _error = '密码至少 4 位');
      return;
    }
    if (a != _b.text) {
      setState(() => _error = '两次输入不一致');
      return;
    }
    final q = _question.text.trim();
    if (q.isNotEmpty && _answer.text.trim().isEmpty) {
      setState(() => _error = '设了密保问题就要填答案');
      return;
    }
    Navigator.pop(
      context,
      _PasswordResult(password: a, question: q, answer: _answer.text),
    );
  }

  void _clear() {
    Navigator.pop(context, const _PasswordResult(clear: true));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final title = widget.questionOnly
        ? '设置密保问题'
        : widget.canClear
            ? '修改密码'
            : '设置密码';

    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!widget.questionOnly) ...[
                TextField(
                  controller: _a,
                  autofocus: true,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '新密码'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _b,
                  obscureText: true,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: '再输一次',
                    errorText: _error,
                  ),
                ),
                const SizedBox(height: 18),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '密保问题（可选，忘记密码时用来找回）',
                  style: AppText.caption1.copyWith(color: c.tertiaryLabel),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _question,
                decoration: const InputDecoration(
                  labelText: '问题',
                  hintText: '如：我第一只宠物叫什么',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _answer,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: '答案',
                  errorText: widget.questionOnly ? _error : null,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.canClear)
          TextButton(
            onPressed: _clear,
            style: TextButton.styleFrom(foregroundColor: c.destructive),
            child: const Text('清除密码'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }
}
