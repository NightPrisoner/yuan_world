package com.yuanworld.yuan_world

import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 把应用私有目录里的文件交给系统 / 别的应用。
 *
 * 为什么必须有这一段：
 * 从 Android 7（API 24）起，Intent 里带 `file://` 会直接抛
 * FileUriExposedException —— 系统连选择器都不会弹，Flutter 那边只会看到
 * 一个平台异常，用户看到的是"点了没反应"或"报错"。
 * 唯一合法的通道是 FileProvider 给出的 `content://`，而它只能在原生侧拼。
 *
 * 为什么目录不能"打开"：
 * `/data/user/0/<包名>/files/` 是应用私有存储，**任何文件管理器都读不到**
 * （没有 root 就没有权限，这是 Android 的设计，不是 bug）。
 * 所以目录走 [exportDirectory]：让用户挑一个公共目录，我们拷过去。
 */
class MainActivity : FlutterActivity() {

    private val channelName = "com.yuanworld.yuan_world/files"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openFile" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("bad_args", "path is empty", null)
                            return@setMethodCallHandler
                        }
                        try {
                            openFile(path)
                            result.success(true)
                        } catch (e: ActivityNotFoundException) {
                            result.error("no_viewer", "这台设备上没有能打开它的应用", e.message)
                        } catch (e: Exception) {
                            result.error("open_failed", e.message ?: e.toString(), null)
                        }
                    }

                    "shareFile" -> {
                        val path = call.argument<String>("path")
                        val title = call.argument<String>("title") ?: "分享"
                        if (path.isNullOrEmpty()) {
                            result.error("bad_args", "path is empty", null)
                            return@setMethodCallHandler
                        }
                        try {
                            shareFile(path, title)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("share_failed", e.message ?: e.toString(), null)
                        }
                    }

                    // 把私有目录里的东西导出到「下载」，让文件管理器能看见。
                    // 这是用户说"手动查找目录也找不到备份"的正解 —— 不是分享出去，
                    // 是搬到公共目录里。
                    "exportToDownloads" -> {
                        val path = call.argument<String>("path")
                        val asZip = call.argument<Boolean>("asZip") ?: false
                        if (path.isNullOrEmpty()) {
                            result.error("bad_args", "path is empty", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val saved = exportToDownloads(File(path), asZip)
                                runOnUiThread { result.success(saved) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error("export_failed", e.message ?: e.toString(), null)
                                }
                            }
                        }.start()
                    }

                    // 在文件管理器里定位到一个目录。
                    // 用户点「打开」的意思是"带我去那个位置看看" ——
                    // 不是让我们把文件打成 zip 塞到下载目录里。
                    // 「所有文件访问」权限的状态与申请入口。
                    // 有了它才能像桌面端那样把数据放到任意文件夹。
                    "hasAllFilesAccess" -> {
                        result.success(hasAllFilesAccess())
                    }

                    "requestAllFilesAccess" -> {
                        try {
                            val intent = Intent(
                                android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                Uri.parse("package:$packageName")
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                startActivity(
                                    Intent(android.provider.Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                                result.success(true)
                            } catch (e2: Exception) {
                                result.error("no_settings", e2.message ?: "打不开系统设置", null)
                            }
                        }
                    }

                    "openDirectory" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("bad_args", "path is empty", null)
                            return@setMethodCallHandler
                        }
                        try {
                            openDirectory(path)
                            result.success(true)
                        } catch (e: ActivityNotFoundException) {
                            result.error("no_viewer", "这台设备上没有文件管理器", e.message)
                        } catch (e: NoDirectoryViewerException) {
                            result.error("no_viewer", e.message, null)
                        } catch (e: NotVisibleException) {
                            result.error("not_visible", e.message, null)
                        } catch (e: Exception) {
                            result.error("open_failed", e.message ?: e.toString(), null)
                        }
                    }

                    // 「在文件管理器中定位」：跳进系统文件管理器并停在那个目录。
                    // 和 openDirectory 分开：那个是"选个应用打开"，这个是"带我去那儿"。
                    "locateDirectory" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("bad_args", "path is empty", null)
                            return@setMethodCallHandler
                        }
                        try {
                            locateDirectory(path)
                            result.success(true)
                        } catch (e: NoDirectoryViewerException) {
                            result.error("no_viewer", e.message, null)
                        } catch (e: Exception) {
                            result.error("locate_failed", e.message ?: e.toString(), null)
                        }
                    }

                    // 列出所有能打开这个目录的应用（让 Flutter 侧自己弹列表）
                    "listDirectoryViewers" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("bad_args", "path is empty", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(listDirectoryViewers(path))
                        } catch (e: Exception) {
                            result.error("list_failed", e.message ?: e.toString(), null)
                        }
                    }

                    // 用指定包名打开目录
                    "openDirectoryWith" -> {
                        val path = call.argument<String>("path")
                        val pkg = call.argument<String>("package")
                        if (path.isNullOrEmpty() || pkg.isNullOrEmpty()) {
                            result.error("bad_args", "path/package is empty", null)
                            return@setMethodCallHandler
                        }
                        try {
                            openDirectoryWith(path, pkg)
                            result.success(true)
                        } catch (e: ActivityNotFoundException) {
                            result.error("no_viewer", "这个应用打不开目录", e.message)
                        } catch (e: Exception) {
                            result.error("open_failed", e.message ?: e.toString(), null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /** 用系统默认程序打开一个私有目录里的文件（content:// + 临时读授权）。 */
    private fun openFile(path: String) {
        val file = File(path)
        if (!file.exists()) throw IllegalArgumentException("文件不存在：$path")
        val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeOf(file.name))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    /** 走系统分享面板把文件发出去（微信、网盘、邮件都在这儿）。 */
    private fun shareFile(path: String, title: String) {
        val file = File(path)
        if (!file.exists()) throw IllegalArgumentException("文件不存在：$path")
        val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mimeOf(file.name)
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, file.name)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, title))
    }

    /**
     * 把文件或目录导出到公共「下载」目录，返回存好之后的路径。
     *
     * 为什么必须走 MediaStore（Android 10+）：
     * 从 API 29 起，应用不能直接往 `/sdcard/Download` 里写裸路径了，
     * 会 EACCES。正规通道是 MediaStore.Downloads，系统帮你在公共目录里
     * 建条目 —— 用户拿任何文件管理器都能看到，也不需要"所有文件访问权限"。
     *
     * Android 9 及以下（API <= 28）没有 MediaStore.Downloads，退回直接写
     * 公共目录，那条路那时候还合法。
     */
    private fun exportToDownloads(src: File, asZip: Boolean): String {
        if (!src.exists()) throw IllegalArgumentException("文件不存在：${src.path}")

        val target: File = if (src.isDirectory) {
            // 目录先打包成一个 zip（Android 的下载目录放不了"文件夹"）
            zipDirectory(src)
        } else {
            src
        }

        val name = target.name
        val mime = mimeOf(name)
        val savedPath: String = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("系统没有给出可写的下载目录")
            try {
                resolver.openOutputStream(uri)?.use { out ->
                    target.inputStream().use { it.copyTo(out) }
                } ?: throw IllegalStateException("打不开下载目录里的这个文件")
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
            "/sdcard/Download/$name"
        } else {
            @Suppress("DEPRECATION")
            val dir = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS
            )
            if (!dir.exists()) dir.mkdirs()
            val out = File(dir, name)
            target.inputStream().use { input ->
                out.outputStream().use { input.copyTo(it) }
            }
            out.absolutePath
        }

        // 打包用的临时 zip 用完就删
        // **必须在导出成功之后才删** —— 以前把删除写在前面，
        // 结果 MediaStore 那边去读的时候文件已经没了，报
        // `cache/images.zip: open failed: ENOENT`。
        if (target != src) {
            try {
                target.delete()
            } catch (_: Exception) {
            }
        }
        return savedPath
    }

    /**
     * 在文件管理器里打开一个目录 —— 三种情况都要能落地。
     *
     * 1. **外部私有目录**（`/storage/emulated/0/Android/data/<包名>/files/...`）
     *    DocumentsUI 直接认识，用 `content://com.android.externalstorage.documents`
     *    的 docId 就能跳过去。
     * 2. **应用私有目录**（`/data/user/0/<包名>/files/...`）
     *    文件管理器自己走不到这里，但**我们能把它授权出去**：
     *    FileProvider 生成 `content://<包名>.fileprovider/files/...`，
     *    带上 `FLAG_GRANT_PREFIX_URI_PERMISSION`（整棵子树）和读权限，
     *    再弹「选择打开方式」——MT 管理器、Solid Explorer、系统文件选择器
     *    这类支持 content:// 的应用都能真的进去看。
     *    这就是用户说的"通过打开-选择应用"。
     * 3. 没有任何应用能处理 —— 抛 [NoDirectoryViewerException]，
     *    上层提示用户改用「分享」。
     */
    /** 系统里没有任何应用能看这个目录。 */
    class NoDirectoryViewerException(message: String) : Exception(message)

    /**
     * 目录要交给谁看 —— 一律走我们自己的 FileProvider。
     *
     * 为什么不用系统 DocumentsUI 的 `externalstorage.documents`：
     * Android 11+ 起它明确拒绝 `Android/data/`，真机上点了就弹
     *   UID xxxxx does not have permission to content://com.android.externalstorage
     *   .documents/document/primary%3AAndroid%2Fdata%2F... [user 0] [prefix];
     *   you could obtain access using ACTION_OPEN_DOCUMENT or related APIs
     * 而 ACTION_OPEN_DOCUMENT 是"让用户自己挑文件"，没法"跳到某个固定目录"。
     *
     * FileProvider 出的是 `content://<包名>.fileprovider/...`，授权由我们自己
     * 给（FLAG_GRANT_*），接收方拿到就能读。路径白名单见 res/xml/file_paths.xml
     * —— `files-path` 与 `external-files-path` 两个根都登记了，所以内部私有
     * 目录和 `Android/data/<包名>/files` 下的目录都能出 URI。
     */
    private fun directoryIntent(path: String): Intent {
        val dir = File(path)
        if (!dir.exists()) throw IllegalArgumentException("目录不存在：$path")

        // ── 情况一：公共存储（/storage/emulated/0/… 或 SD 卡 /storage/XXXX-XXXX/…）
        //
        // **一律走自家 FileProvider。**
        //
        // 曾经这里给公共存储拼过 `com.android.externalstorage.documents` 的
        // document URI，想让文件管理器直接定位到真实路径。实测行不通：那个
        // provider 要求调用方持有一份 SAF 授权才肯把 URI 转授出去，而
        // MANAGE_EXTERNAL_STORAGE 只给了文件读写能力、**不给** SAF 授权，
        // 于是系统直接拒，用户看到 `UID 10xxx does not have permission ...
        // you could obtain access using ACTION_OPEN_DOCUMENT`。
        //
        // 真正的"跳到那个位置"由 openDirectory() 走
        // ACTION_OPEN_DOCUMENT_TREE + EXTRA_INITIAL_URI 实现；这里的 Intent
        // 只用于「选个应用打开这个内容」，FileProvider 是对的。
        val uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            dir
        )
        return Intent(Intent.ACTION_VIEW).apply {
            // 通配 MIME：目录的"标准"类型 resource/folder 只被少数应用注册，
            // MT 管理器、Solid Explorer、ES 都只认通配 —— 用窄类型匹配时
            // 它们连候选都进不来，用户会以为"手机没有能打开的应用"。
            setDataAndType(uri, "*/*")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }
    }

    /**
     * 把真实文件路径换成系统 DocumentsProvider 的 URI（只在公共存储上成立）。
     *
     * 返回 null 表示这条路走不通，调用方改走 FileProvider。
     *
     * 为什么 `Android/data` 要排除：Android 11+ 起系统 DocumentsUI 自己都不许
     * 进那个目录（真机实测报 `does not have permission to
     * content://com.android.externalstorage.documents/document/primary%3AAndroid
     * %2Fdata%2F…`），递过去只会让用户看到一个错误框。
     */
    private fun externalStorageDocUri(path: String): Uri? {
        val norm = try {
            File(path).canonicalPath
        } catch (e: Exception) {
            return null
        }

        fun docUri(volume: String, rel: String): Uri? {
            // Android 11+ 禁止通过 DocumentsProvider 访问 Android/data 与 Android/obb
            if (rel == "Android" || rel.startsWith("Android/")) return null
            val docId = if (rel.isEmpty()) "$volume:" else "$volume:$rel"
            return DocumentsContract.buildDocumentUri(
                "com.android.externalstorage.documents", docId
            )
        }

        val primary = try {
            Environment.getExternalStorageDirectory()?.canonicalPath
        } catch (e: Exception) {
            null
        }
        if (primary != null && (norm == primary || norm.startsWith("$primary/"))) {
            val rel = norm.removePrefix(primary).trimStart('/')
            return docUri("primary", rel)
        }

        // SD 卡等其它卷：/storage/<VOLUME_ID>/<rel>
        if (norm.startsWith("/storage/")) {
            val rest = norm.removePrefix("/storage/")
            val slash = rest.indexOf('/')
            if (slash > 0) {
                val volume = rest.substring(0, slash)
                // emulated 已经由上面 primary 那条覆盖，self 是应用自己的沙箱
                if (volume != "emulated" && volume != "self") {
                    val rel = rest.substring(slash + 1)
                    return docUri(volume, rel)
                }
            }
        }
        return null
    }

    /**
     * 找出「真正是文件管理器」的候选应用。
     *
     * 系统自带的「打开方式」会把微信、QQ、支付宝全列进来（它们都注册了
     * 通配 MIME），可这些应用拿到一个目录 URI 只会失败。用户点「打开」的
     * 意思是"进到那个目录里看看"，所以这里把文件管理器挑出来，作为默认
     * 优先项交给系统。
     */
    private fun pickFileManager(candidates: List<android.content.pm.ResolveInfo>): String? {
        val managers = candidates.filter { ri ->
            val pkg = ri.activityInfo.packageName
            val label = ri.loadLabel(packageManager)?.toString() ?: ""
            val cls = ri.activityInfo.name.lowercase()
            val key = (pkg + " " + label + " " + cls).lowercase()
            // 认得出来的文件管理器关键词
            val known = listOf(
                "documentsui", "filemanager", "file_manager", "fileexplorer",
                "file_explorer", "zarchiver", "mt管理器", "mt manager",
                "solid", "x-plore", "fx ", "mixplorer", "es ", "re文件",
                "com.android.documentsui", "com.estrongs", "com.rarlab",
                "com.mixplorer", "bin.mt", "com.google.android.documentsui"
            )
            // 明确不是文件管理器的（社交/支付/浏览器）
            val deny = listOf(
                "wechat", "tencent.mm", "qq", "alipay", "browser", "chrome",
                "contacts", "dialer", "mms", "certinstaller", "vending",
                "printservice", "printspooler", "mail", "gmail", "weibo"
            )
            if (deny.any { key.contains(it) }) return@filter false
            known.any { key.contains(it) }
        }
        if (managers.isEmpty()) return null
        // 有多个就取第一个（已按系统排序，通常是用户默认那个）
        return managers.first().activityInfo.packageName
    }

    /**
     * 跳进系统文件管理器，并**直接停在这个目录**上。
     *
     * 用 `ACTION_OPEN_DOCUMENT_TREE` + `EXTRA_INITIAL_URI`：界面就是文件
     * 管理器本体，一进去就在目标文件夹（真机验证过，面包屑显示
     * `Redmi Note 12 Turbo > 元世界`）。底部会多一个「使用此文件夹」，
     * 按返回直接退出 —— 我们不拿这个授权去写任何东西，只是借它的界面。
     *
     * 为什么不用 `ACTION_VIEW` + `externalstorage.documents`：那个 provider
     * 要求调用方持有一份 SAF 授权才肯把 URI 转授出去，而
     * MANAGE_EXTERNAL_STORAGE 只给文件读写能力、**不给** SAF 授权，于是
     * 系统直接拒（`you could obtain access using ACTION_OPEN_DOCUMENT`）。
     */
    private fun locateDirectory(path: String) {
        val initial = externalStorageDocUri(path)
        if (initial == null) {
            throw NoDirectoryViewerException(
                "这个位置在应用私有区，文件管理器打不开。点「修改」可以搬到能看见的位置。"
            )
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, initial)
            }
        }
        try {
            startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            throw NoDirectoryViewerException(
                "这台设备上没有系统文件管理器，定位不了。可以用「打开」选个应用。"
            )
        }
    }

    private fun openDirectory(path: String) {
        // 「打开」= 让用户挑一个应用来打开它，**不自己替他决定**。
        //
        // 曾经这里对公共存储直接甩 ACTION_OPEN_DOCUMENT_TREE，一按就跳进
        // 系统文件管理器 —— 确实能"到那个位置"，但用户失去了选应用的权力，
        // 想用 MT 管理器、ZArchiver 看看都不行。跳转另外做成了 locateDirectory()。
        val base = directoryIntent(path)
        base.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        base.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        base.addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)

        // 弹出系统原生的「选择打开方式」。**不能先 resolveActivity 判空** ——
        // 它只返回默认应用，会把 MT 管理器这类判成"没有应用能打开"。
        //
        // 探测用通配 MIME：目录的标准 MIME（resource/folder）只被少数几个
        // 应用注册，MT 管理器、Solid Explorer 这类只认通配，用窄类型匹配
        // 时它们连候选都进不来。
        val probe = Intent(base).setDataAndType(base.data, "*/*")
        val candidates = packageManager.queryIntentActivities(probe, 0)
        if (candidates.isEmpty() && packageManager.queryIntentActivities(base, 0).isEmpty()) {
            throw NoDirectoryViewerException(
                "没有应用能打开这个目录。可以用「分享」把里面的文件发出去。"
            )
        }
        // 只有一个候选就直接开，别让用户点第二次。
        val only = candidates.singleOrNull()
        if (only != null) {
            val direct = Intent(base).setPackage(only.activityInfo.packageName)
            try {
                startActivity(direct)
                return
            } catch (_: ActivityNotFoundException) {
                // 落到下面走 chooser
            }
        }

        // 系统自带的「打开方式」会把微信、QQ、支付宝也列进来（它们都注册了
        // 通配 MIME），但这些应用拿到目录 URI 只会失败。点「打开」的意思是
        // "进到那个目录里"，所以把识别到的文件管理器**排到最前面**：
        // chooser 会照候选顺序展示，第一个就是它。
        val managerPkg = pickFileManager(candidates)
        val ordered = if (managerPkg == null) {
            candidates
        } else {
            candidates.sortedByDescending {
                if (it.activityInfo.packageName == managerPkg) 1 else 0
            }
        }

        val chooser = Intent.createChooser(base, "选择打开方式")
        if (managerPkg != null) {
            // EXTRA_INITIAL_INTENTS 里的项在系统面板中会排在最前，
            // 但它需要是**具体的** Intent（带 package），否则无效。
            val managerIntent = Intent(base).setPackage(managerPkg)
            chooser.putExtra(Intent.EXTRA_INITIAL_INTENTS, arrayOf(managerIntent))
        }

        // 关键补丁：系统 chooser 不会告诉我们用户点了哪个应用，所以没法在
        // "选中之后"再做定位。改成在列表里**额外摆一个"文件"入口** ——
        // 它就是 ACTION_OPEN_DOCUMENT_TREE + EXTRA_INITIAL_URI，点下去
        // 系统文件管理器会直接停在这个目录上（真机验证过）。
        // 其余应用照旧收到 ACTION_VIEW，能预览/复制，但停不到具体位置。
        val jump = jumpIntent(path)
        if (jump != null) {
            val extras = chooser.getParcelableArrayExtra(Intent.EXTRA_INITIAL_INTENTS)
                ?.filterIsInstance<Intent>()
                ?.toMutableList() ?: mutableListOf()
            extras.add(0, jump)
            chooser.putExtra(Intent.EXTRA_INITIAL_INTENTS, extras.toTypedArray())
        }

        try {
            startActivity(chooser)
        } catch (e: ActivityNotFoundException) {
            throw NoDirectoryViewerException(
                "没有应用能打开这个目录。可以用「分享」把里面的文件发出去。"
            )
        }
    }

    /**
     * 构造一个"跳到这个目录"的 Intent（指向系统文件管理器）。
     *
     * 只有能解析出磁盘真实路径的目录才给（`externalStorageDocUri` 返回非空）。
     * 应用私有目录在磁盘上没有挂载点，任何文件管理器都停不过去，返回 null。
     */
    private fun jumpIntent(path: String): Intent? {
        val initial = externalStorageDocUri(path) ?: return null
        val tree = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, initial)
            }
        }
        // 绑到系统文件管理器上，这样 chooser 里显示的就是「文件」这一项，
        // 而不是一个来路不明的图标。
        val resolved = packageManager.queryIntentActivities(tree, 0)
        val target = resolved.firstOrNull {
            it.activityInfo.packageName == "com.google.android.documentsui" ||
                it.activityInfo.packageName == "com.android.documentsui"
        } ?: resolved.firstOrNull() ?: return null
        return Intent(tree).setPackage(target.activityInfo.packageName).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
    }

    /**
     * 列出所有能打开这个目录的应用。
     *
     * 交给 Flutter 侧自己画列表 —— 系统那个 `createChooser` 在部分 ROM 上
     * 只显示"默认应用"，用户明明装了 MT 管理器却看不到（真机上验证过）。
     *
     * 返回 `List<Map<String, String>>`：`package` / `label`。
     */
    private fun listDirectoryViewers(path: String): List<Map<String, String>> {
        val base = directoryIntent(path)

        // 分三档探测。**顺序就是可信度**：越靠前越可能真的能浏览目录。
        //   0 = 明确声明能处理"目录"类型（ZArchiver 这类）
        //   1 = 只声明 */*，但看起来是文件管理器
        //   2 = 只声明 */* 的其它应用（浏览器、联系人…）
        // 只报 0 和 1 两档：2 档那些拿到目录 URI 只会报错或空白，
        // 列出来是让用户去撞墙。
        val tiers = listOf(
            0 to "resource/folder",
            0 to "vnd.android.document/directory",
            1 to "*/*",
        )
        val out = LinkedHashMap<String, MutableMap<String, String>>()
        for ((tier, t) in tiers) {
            val probe = Intent(base).setDataAndType(base.data, t)
            for (ri in packageManager.queryIntentActivities(probe, 0)) {
                val pkg = ri.activityInfo.packageName
                if (pkg == packageName) continue
                val label = ri.loadLabel(packageManager)?.toString() ?: pkg
                val cur = out[pkg]
                if (cur == null) {
                    out[pkg] = mutableMapOf(
                        "package" to pkg,
                        "label" to label,
                        "tier" to tier.toString(),
                        "icon" to iconBase64(ri.loadIcon(packageManager)),
                    )
                } else if (tier < (cur["tier"]?.toIntOrNull() ?: 9)) {
                    cur["tier"] = tier.toString()
                }
            }
        }
        return out.values.sortedWith(
            compareBy({ it["tier"]?.toIntOrNull() ?: 9 }, { it["label"] ?: "" })
        )
    }

    /** 用指定的包名打开目录（Flutter 侧弹完列表后回调这里）。 */
    private fun openDirectoryWith(path: String, pkg: String) {
        // 用户挑的是系统文件管理器 → 让它**跳到位**，而不只是"打开一个内容"。
        //
        // 为什么只有它能跳：ACTION_OPEN_DOCUMENT_TREE 是系统 DocumentsUI 的
        // 入口，EXTRA_INITIAL_URI 能让它一进去就停在这个目录上（真机验证过）。
        // 第三方文件管理器（MT、ZArchiver）收到的是自家 FileProvider 的
        // content:// URI —— 它们能通过 DocumentsContract 读到内容，但那个
        // URI 是"我们的命名空间"，没有磁盘路径可对应，所以停不到具体位置。
        if (isDocumentsUi(pkg) && externalStorageDocUri(path) != null) {
            locateDirectory(path)
            return
        }
        val base = directoryIntent(path)
        base.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        base.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        base.addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        base.setPackage(pkg)
        startActivity(base)
    }

    /** 是不是系统自带的「文件」应用（DocumentsUI）。 */
    private fun isDocumentsUi(pkg: String): Boolean =
        pkg == "com.google.android.documentsui" ||
            pkg == "com.android.documentsui"

    /** 目录在应用私有区，文件管理器根本读不到（旧逻辑保留，导出用）。 */
    class NotVisibleException(message: String) : Exception(message)

    /** 把一个目录压成一个 zip（放在 cache 里，导出完删掉）。 */
    private fun zipDirectory(dir: File): File {
        val out = File(cacheDir, "${dir.name}.zip")
        if (out.exists()) out.delete()
        java.util.zip.ZipOutputStream(out.outputStream().buffered()).use { zos ->
            val base = dir.toPath()
            dir.walkTopDown().forEach { f ->
                if (!f.isFile) return@forEach
                val rel = base.relativize(f.toPath()).toString().replace('\\', '/')
                zos.putNextEntry(java.util.zip.ZipEntry(rel))
                f.inputStream().use { it.copyTo(zos) }
                zos.closeEntry()
            }
        }
        return out
    }

    /**
     * 有没有「所有文件访问」权限。
     *
     * Android 11+ 才要求这个；10 及以下靠 WRITE_EXTERNAL_STORAGE 就够了。
     * 没有它的话，应用只能写自己的两个私有目录，用户挑的任意文件夹会 EACCES ——
     * 这就是手机上"修改位置"没法像桌面端那样自由的根本原因。
     */
    private fun hasAllFilesAccess(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return true
        return Environment.isExternalStorageManager()
    }

    /**
     * 把应用图标转成 base64 PNG，交给 Flutter 侧画。
     *
     * 为什么不直接用 `ListTile` 的默认占位图标：一个"选应用"的列表里
     * 全是同一个灰色文件夹，用户根本分不清谁是谁 —— 图标就是这个列表的
     * 全部信息量。尺寸先缩到 96px，几十个应用的字节量也可忽略。
     */
    private fun iconBase64(drawable: android.graphics.drawable.Drawable?): String {
        if (drawable == null) return ""
        return try {
            val size = 96
            val bmp = android.graphics.Bitmap.createBitmap(
                size, size, android.graphics.Bitmap.Config.ARGB_8888
            )
            val canvas = android.graphics.Canvas(bmp)
            drawable.setBounds(0, 0, size, size)
            drawable.draw(canvas)
            val bos = java.io.ByteArrayOutputStream()
            bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, bos)
            bmp.recycle()
            android.util.Base64.encodeToString(bos.toByteArray(), android.util.Base64.NO_WRAP)
        } catch (e: Exception) {
            ""
        }
    }

    private fun mimeOf(name: String): String = when {
        name.endsWith(".zip", true) -> "application/zip"
        name.endsWith(".db", true) -> "application/octet-stream"
        name.endsWith(".png", true) -> "image/png"
        name.endsWith(".jpg", true) || name.endsWith(".jpeg", true) -> "image/jpeg"
        name.endsWith(".webp", true) -> "image/webp"
        name.endsWith(".gif", true) -> "image/gif"
        name.endsWith(".mp4", true) -> "video/mp4"
        name.endsWith(".txt", true) || name.endsWith(".log", true) -> "text/plain"
        else -> "*/*"
    }
}
