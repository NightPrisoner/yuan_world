/// 查询笔记时的**公共口径**。集中在这里，是为了把同一类 bug 一次堵住。
///
/// 代码审查反复发现同一个错误：某个聚合查询漏了 `deleted_at IS NULL`，
/// 于是回收站里的内容照样被算进"标签数""写作趋势""长文排行"里 ——
/// 明明已经删了，侧栏角标和统计数字还挂着它。
///
/// 单看每一处都只是"少写了一个条件"，review 时很难看出来；
/// 同一个条件在文件里有 **4 种写法**，靠肉眼比对是不现实的。
///
/// ## 为什么是函数而不是常量
///
/// **别名必须显式传进来。** 试过用常量（`kLiveN` / `kLiveNotes`）配合正则
/// 批量替换 —— 结果打破 172 个测试：SQLite 在表起了别名之后**不认原名**，
/// `FROM notes n` 只能写 `n.`，`FROM notes` 写 `n.` 就报 `no such column`。
/// 正则只认列名，看不见外围的 FROM/JOIN，替换出来的前缀一半是错的。
///
/// 做成 `liveNote("n")` 之后，**调用点必须自己看一眼表是怎么引用的**，
/// 这类错误在写的时候就暴露了，而不是等到跑测试。
///
/// 用法：`'FROM notes n WHERE ${liveNote("n")}'`
/// （参数用双引号，这样整段能安全地放进单引号或三引号字符串里）
library;

/// 笔记"活着"的条件：没归档、没隐藏、不在回收站。
String liveNote(String alias) =>
    '$alias.is_archived = 0 AND $alias.is_hidden = 0 AND $alias.deleted_at IS NULL';

/// 隐私空间那一套：**反过来只看隐藏的**，但一样要排掉回收站。
String hiddenNote(String alias) =>
    '$alias.is_hidden = 1 AND $alias.deleted_at IS NULL';

/// 文集"活着"的条件（文集没有归档态）。
String liveCollection(String alias) =>
    '$alias.is_hidden = 0 AND $alias.deleted_at IS NULL';
