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
    private val dragChannelName = "com.yuanworld.yuan_world/drop"
    private var dragChannel: MethodChannel? = null

    /**
     * 拖放事件只在原生 View 上派发，Activity 本身没有 `dispatchDragEvent`
     * （那是 `View` 的方法）。所以要挂到最外层的 decorView 上。
     *
     * **`ACTION_DRAG_STARTED` 必须返回 true** —— 否则系统认为这个窗口不接收
     * 拖入，后面的 ENTERED / DROP 一个都不会来。
     */
    private fun installDragListener() {
        // **必须把 desktop_drop 挂在 android.R.id.content 上的监听器摘掉。**
        //
        // 拖拽事件在 View 树里是从上往下派发的：decorView 先拿到，我返回 true
        // 就到此为止；返回 false 系统会继续往子 View 递，于是落到 desktop_drop
        // 的监听器上。它做的是「把 content:// URI 原样发给 Dart」—— 而 Dart 的
        // dart:io 根本打不开 content://，最后表现成「拖进来了，但一个文件都没
        // 识别到」。两个监听器抢同一个手势，只能留一个。
        //
        // 我们的做法比它靠谱（在这里就 requestDragAndDropPermissions 并把字节
        // 拷成真实文件），所以摘它、留我们自己的。
        (findViewById<android.view.ViewGroup>(android.R.id.content))
            ?.setOnDragListener(null)

        window.decorView.setOnDragListener { _, event ->
            when (event.action) {
                android.view.DragEvent.ACTION_DRAG_STARTED -> {
                    dragChannel?.invokeMethod("onDragStarted", null)
                    true
                }
                android.view.DragEvent.ACTION_DRAG_ENDED -> {
                    dragChannel?.invokeMethod("onDragEnded", null)
                    true
                }
                android.view.DragEvent.ACTION_DROP -> {
                    // 吃掉这个事件，不管有没有读到文件。返回 false 会让它继续
                    // 往下派发，被别的监听器再处理一次（重复导入或空列表）。
                    handleDrop(event)
                    true
                }
                else -> true
            }
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        installDragListener()
    }

    override fun onPostResume() {
        super.onPostResume()
        // desktop_drop 是在 configureFlutterEngine 之后才挂到 android.R.id.content
        // 上的，onCreate 那会儿它还不存在。这里每次恢复前台再摘一次，防止插件
        // 在别处重新 attach 时又抢走拖拽事件。
        (findViewById<android.view.ViewGroup>(android.R.id.content))
            ?.setOnDragListener(null)
    }

    override fun onDestroy() {
        dragChannel = null
        super.onDestroy()
    }

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

                    "pickFolderAndCopy" -> {
                        lastPickReason = null
                        pickFolderAndCopy { r ->
                            r.fold(
                                onSuccess = { path -> result.success(path) },
                                onFailure = { e ->
                                    result.error(
                                        "pick_failed",
                                        e.message ?: e.toString(),
                                        null
                                    )
                                },
                            )
                        }
                    }

                    "lastPickReason" -> {
                        result.success(lastPickReason)
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

        // 拖拽导入：Android 的拖放手势只到原生 View，Flutter 收不到。
        // 这里把落下的文件先拷进应用的接收目录，再把路径报给 Dart。
        dragChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, dragChannelName)
    }

    /// 拖进来待导入的文件放在这里，Dart 侧取走后会自己清。
    private fun dropDir(): File = File(cacheDir, "drops").apply { mkdirs() }

    /**
     * Android 7+ 的拖放：从 ClipData 里把 `content://` 全拷到 [dropDir]。
     *
     * 为什么要拷：剪贴板 / 中转站 / 分屏另一侧给的 URI 授权只在这一刻有效，
     * 松手之后随时可能失效，甚至原应用就退出了。不落盘就等于什么都没拿到。
     *
     * 只收文件、不收文本；目录（`vnd.android.document/directory`）也跳过 ——
     * 递归遍历别家应用的树要通过 DocumentsContract，代价大且容易半途失败，
     * 手机上用户真正想拖的是一两张图或一段视频。
     */
    private fun handleDrop(event: android.view.DragEvent): Boolean {
        if (event.action != android.view.DragEvent.ACTION_DROP) return false
        val clip = event.clipData ?: return false

        // **必须先申请拖放授权。** 跨应用拖过来的 content:// URI，读权限只
        // 在那一次手势里临时有效；不调这一句直接 openInputStream，抛
        // SecurityException 或者读到空。这是 Android 文档里明写的步骤，
        // 少了它整套东西看起来"能拖但是 0 字节"。
        try {
            requestDragAndDropPermissions(event)
        } catch (_: Exception) {
            // 同应用内拖拽不需要授权；失败也继续试一次
        }

        // 清掉**陈旧**残留，但别动刚才那次刚拷进来的。
        //
        // 以前这里是 `dropDir().listFiles()?.forEach { it.delete() }`，一次
        // 全清。问题是 Android 对一次拖拽手势可能派发多次 ACTION_DROP，
        // 第二次进来就把第一次刚拷好的文件删了，而 Dart 侧拿到的是第一批
        // 路径 —— 复制时源文件已经没了，报"导入失败"。改成只删 10 分钟前的。
        val staleBefore = System.currentTimeMillis() - 10 * 60 * 1000L
        dropDir().listFiles()?.forEach { f ->
            if (f.lastModified() < staleBefore) f.delete()
        }

        val saved = mutableListOf<String>()
        val rejected = mutableListOf<String>()
        val reasons = mutableListOf<String>()
        val stamp = System.currentTimeMillis()

        for (i in 0 until clip.itemCount) {
            val uri = clip.getItemAt(i).uri ?: continue
            val name = displayNameOf(uri) ?: "drop-$stamp-$i"
            try {
                if (isDirectoryUri(uri)) {
                    // 拖进来的是文件夹：建一个以它命名的容器，把整棵子树拷进去。
                    //
                    // 容器本身作为 "path" 交给 Dart —— 那边认路径是不是目录，
                    // 认出来就按「文集」处理（递归收文档、按相对路径还原文集
                    // 层级）。所以这里要**保留目录结构**，不能拍平。
                    //
                    // **容器名固定，不 uniqueFile**：每次拖同一个文件夹都该得到
                    // 同一个文集名，否则 Dart 侧会建出「小小说」「小小说-2」，
                    // 而去重是按「标题 + 文集」判断的 —— 文集 id 一变就认不出
                    // 是同一批文章，于是整批重复导入。
                    val container = File(dropDir(), sanitize(name))
                    if (container.exists()) container.deleteRecursively()
                    container.mkdirs()
                    val copied = copyTree(uri, container, reasons)
                    if (copied == 0) {
                        container.deleteRecursively()
                        rejected.add(name)
                        reasons.add("$name：这个文件夹里没有能读的文件")
                    } else {
                        saved.add(container.absolutePath)
                    }
                } else {
                    val target = uniqueFile(dropDir(), sanitize(name))
                    contentResolver.openInputStream(uri).use { input ->
                        if (input == null) throw IllegalStateException("读不到内容")
                        target.outputStream().use { out -> input.copyTo(out) }
                    }
                    if (target.length() == 0L) {
                        target.delete()
                        rejected.add(name)
                        reasons.add("$name：读出来是 0 字节")
                    } else {
                        saved.add(target.absolutePath)
                    }
                }
            } catch (e: Exception) {
                // 以前只把名字塞进 rejected，异常本身扔了。用户看到的就是
                // "导入失败：文件名"，完全不知道是权限、URI 还是磁盘。
                rejected.add(name)
                reasons.add("$name：${e.javaClass.simpleName} ${e.message ?: ""}".trim())
            }
        }

        if (saved.isEmpty() && rejected.isEmpty()) return false
        dragChannel?.invokeMethod(
            "onDrop",
            mapOf(
                "paths" to saved,
                "rejected" to rejected,
                "reasons" to reasons,
            ),
        )
        return true
    }

    /** 从 URI 猜一个带扩展名的文件名 —— 扩展名决定了它是图片还是视频。 */
    private fun displayNameOf(uri: Uri): String? {
        var name: String? = null
        if (uri.scheme == "content") {
            try {
                contentResolver.query(uri, null, null, null, null)?.use { c ->
                    val idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0 && c.moveToFirst()) name = c.getString(idx)
                }
            } catch (_: Exception) {
            }
        }
        if (name.isNullOrEmpty()) name = uri.lastPathSegment?.substringAfterLast('/')
        return name
    }

    /** 去掉路径分隔符之类会让写盘跑偏的字符。 */
    private fun sanitize(name: String): String =
        name.replace(Regex("""[\\/:*?"<>|]"""), "_").take(120).ifEmpty { "drop" }

    private fun uniqueFile(dir: File, name: String): File {
        val base = name.substringBeforeLast('.', name)
        val ext = name.substringAfterLast('.', "")
        var candidate = File(dir, name)
        var n = 2
        while (candidate.exists()) {
            val suffix = if (ext.isEmpty()) "" else ".$ext"
            candidate = File(dir, "$base-$n$suffix")
            n++
        }
        return candidate
    }

    /**
     * 拖进来的这一项是不是文件夹。
     *
     * 三种可能：`file://`（自应用内拖）、`content://` 的 document URI、
     * `content://` 的 tree URI。前两种要问 MIME，tree URI 一定是目录。
     */
    private fun isDirectoryUri(uri: Uri): Boolean {
        if (uri.scheme == "file") {
            val path = uri.path ?: return false
            return File(path).isDirectory
        }
        return try {
            if (DocumentsContract.isTreeUri(uri)) return true
            if (DocumentsContract.isDocumentUri(this, uri)) {
                contentResolver.query(
                    uri,
                    arrayOf(DocumentsContract.Document.COLUMN_MIME_TYPE),
                    null, null, null,
                )?.use { c ->
                    if (c.moveToFirst() && !c.isNull(0)) {
                        return c.getString(0) == DocumentsContract.Document.MIME_TYPE_DIR
                    }
                }
            }
            contentResolver.getType(uri) == DocumentsContract.Document.MIME_TYPE_DIR
        } catch (_: Exception) {
            false
        }
    }

    /**
     * 把一个目录 URI 的子项列出来：`(子 URI, 名字, MIME)`。
     *
     * [treeUri] 是用户当初选出来的那棵树。子项的 URI 一律用
     * `buildDocumentUriUsingTree(treeUri, childDocId)` 构造 —— 它继承 tree
     * 的授权。曾经这里拿子项的 docId 反过来拼 tree
     *（`buildTreeDocumentUri(authority, docId)`），MIUI 的 provider 不认，
     * query 返回空游标，于是子文件夹永远是空的（"多层结构没继承"）。
     */
    private fun childEntries(
        uri: Uri,
        treeUri: Uri,
    ): List<Triple<Uri, String, String>>? {
        val docId = try {
            if (DocumentsContract.isTreeUri(uri)) {
                DocumentsContract.getTreeDocumentId(uri)
            } else {
                DocumentsContract.getDocumentId(uri)
            }
        } catch (_: Exception) {
            return null
        }
        val tree = if (DocumentsContract.isTreeUri(uri)) uri else treeUri
        val childrenUri = try {
            DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
        } catch (_: Exception) {
            return null
        }
        val out = mutableListOf<Triple<Uri, String, String>>()
        try {
            contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                ),
                null, null, null,
            )?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0) ?: continue
                    val name = c.getString(1) ?: id.substringAfterLast('/')
                    val mime = c.getString(2) ?: ""
                    val childUri = try {
                        DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
                    } catch (_: Exception) {
                        continue
                    }
                    out.add(Triple(childUri, name, mime))
                }
            }
        } catch (_: Exception) {
            return null
        }
        return out
    }

    /**
     * 递归把目录 URI 里的内容拷进 [dest]，返回拷成功的文件数。
     *
     * [treeUri] 必须一路传下去 —— **不要拿子项的 docId 重新拼 tree URI**。
     * MIUI 的 DocumentsProvider 不认那种"事后拼出来的"tree，query 直接返回
     * 空游标，表现就是"只拷到了第一层，子文件夹全是空的"。子项一律用
     * `buildDocumentUriUsingTree(原 treeUri, childDocId)` 构造，走的是同一条
     * 已授权的树。
     *
     * 两个上限（`depth <= 8`、`files <= 500`）是防手滑：有人会把整个相册
     * 拖进来，那会拷出几个 G 塞满缓存盘，而用户只是想导一篇文档。超限时
     * 不报错，把已拷的交给上层 —— 能导入多少算多少。
     */
    private fun copyTree(
        root: Uri,
        dest: File,
        reasons: MutableList<String>,
        treeUri: Uri = root,
        depth: Int = 0,
        counter: IntArray = intArrayOf(0),
    ): Int {
        if (depth > 8) return counter[0]

        if (root.scheme == "file") {
            val src = root.path?.let { File(it) } ?: return counter[0]
            if (!src.isDirectory) return counter[0]
            src.listFiles()?.forEach { f ->
                if (counter[0] >= 500) return@forEach
                val target = File(dest, sanitize(f.name))
                if (f.isDirectory) {
                    target.mkdirs()
                    copyTree(Uri.fromFile(f), target, reasons, depth = depth + 1, counter = counter)
                } else {
                    try {
                        f.inputStream().use { i -> target.outputStream().use { i.copyTo(it) } }
                        counter[0]++
                    } catch (e: Exception) {
                        reasons.add("${f.name}：${e.javaClass.simpleName}")
                    }
                }
            }
            return counter[0]
        }

        val children = childEntries(root, treeUri) ?: return counter[0]
        for ((childUri, name, mime) in children) {
            if (counter[0] >= 500) break
            val safe = sanitize(name)
            val target = File(dest, safe)
            if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                target.mkdirs()
                copyTree(
                    childUri, target, reasons,
                    treeUri = treeUri, depth = depth + 1, counter = counter,
                )
            } else {
                try {
                    contentResolver.openInputStream(childUri).use { input ->
                        if (input == null) throw IllegalStateException("读不到内容")
                        target.outputStream().use { out -> input.copyTo(out) }
                    }
                    if (target.length() == 0L) {
                        target.delete()
                    } else {
                        counter[0]++
                    }
                } catch (e: Exception) {
                    reasons.add("$safe：${e.javaClass.simpleName} ${e.message ?: ""}".trim())
                }
            }
        }
        return counter[0]
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
     * 让用户挑一个文件夹，把**里面的文件真拷出来**，返回本地目录路径。
     *
     * 为什么不直接用 file_picker 的 `getDirectoryPath`：它拿 SAF 的 tree URI
     * 反推磁盘路径（`primary:<rel>` → `/storage/emulated/0/<rel>`），反推出来
     * 的路径**不一定真的可读** —— SAF 授权是 URI 级别的，拿到裸路径去
     * `listSync()` 要么 EACCES，要么返回空。真机上表现就是「选好了文件夹，
     * 提示该文件夹下没有找到可以导入的文档」。
     *
     * 这里改用 ACTION_OPEN_DOCUMENT_TREE，拿到 tree URI 后**通过
     * DocumentsContract 逐层读**，把文件拷进 cache，再把缓存目录交回去。
     * 这样 Dart 侧拿到的永远是可读的真实文件，不管用户选的是主存储、
     * SD 卡还是网盘目录。
     */
    private fun pickFolderAndCopy(callback: (Result<String?>) -> Unit) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try {
            startActivityForResult(intent, REQ_PICK_FOLDER)
        } catch (e: ActivityNotFoundException) {
            callback(Result.failure(e))
            return
        }
        pendingFolderCallback = callback
    }

    private var pendingFolderCallback: ((Result<String?>) -> Unit)? = null

    @Deprecated("FlutterActivity 仍走这套回调")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_PICK_FOLDER) return
        val cb = pendingFolderCallback ?: return
        pendingFolderCallback = null

        val tree = data?.data
        if (resultCode != android.app.Activity.RESULT_OK || tree == null) {
            cb(Result.success(null))
            return
        }
        // 拿持久授权。**拿不到就直接停**，不要硬着头皮往下读 ——
        // 持久授权失败意味着每次 query 子目录系统都要再弹一次确认框
        //（用户看到的"一闪一闪的弹窗"就是这个），拷出来的结果也不可靠。
        var granted = false
        try {
            contentResolver.takePersistableUriPermission(
                tree, Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
            granted = true
        } catch (_: Exception) {
        }

        try {
            // **有「所有文件访问」时，根本不用走 SAF 读文件。**
            //
            // SAF 那套（DocumentsContract 递归 query + 逐个
            // openInputStream）在 MIUI 上有三个躲不开的毛病：
            //   1. 每次 query 子目录都可能触发系统授权框 —— 用户看到的
            //      "一闪一闪的弹窗"；
            //   2. 子项的 tree URI 得自己拼，MIUI 不认拼出来的树，递归到
            //      第二层就返回空游标 —— "多层结构没继承"；
            //   3. 慢，几百个文件要几百次跨进程调用。
            //
            // 我们本来就申请了 MANAGE_EXTERNAL_STORAGE（这个应用只从 GitHub
            // 分发，不上架商店）。有它就能直接读磁盘真实路径，上面三条全没了。
            // SAF 只用来**让用户挑一个文件夹**，挑完立刻换算成路径。
            val docId = DocumentsContract.getTreeDocumentId(tree)
            val picked = docId.substringAfter(':', missingDelimiterValue = docId)
                .substringAfterLast('/')
                .ifEmpty { "folder-${System.currentTimeMillis()}" }

            val realDir = treeDocIdToPath(docId)
            val sourceDir = realDir?.takeIf { it.isDirectory && it.canRead() }

            if (sourceDir == null) {
                // 没有权限或路径换算不出来 —— 退回 SAF 递归（慢，但能work）
                val container = File(dropDir(), sanitize(picked))
                if (container.exists()) container.deleteRecursively()
                container.mkdirs()
                val reasons = mutableListOf<String>()
                val copied = copyTree(tree, container, reasons)
                if (copied == 0) {
                    container.deleteRecursively()
                    cb(Result.success(""))
                    lastPickReason = if (reasons.isEmpty()) {
                        "这个文件夹里没有文件，或者系统没给我们读它的权限"
                    } else {
                        reasons.take(3).joinToString("；")
                    }
                } else {
                    lastPickReason = null
                    cb(Result.success(container.absolutePath))
                }
                return
            }

            // 直接拷真实目录。**保留相对结构** —— 导入时要按相对路径还原
            // 「文集 → 子文集 → 文章」的层级。
            //
            // **容器名固定，不 uniqueFile。**
            // 以前用 uniqueFile 建 `小小说` / `小小说-2` / `小小说-3`，每次导入
            // 都换一个名字，于是 Dart 侧 p.basename(rootDir) 每次都不一样，
            // 文集也跟着建出「小小说」「小小说-2」—— 而且因为 collection_id
            // 变了，去重判断（标题 + 文集）匹配不上，同一批文章被重复导入。
            // 改成每次先删掉同名旧目录再建，名字永远稳定。
            val container = File(dropDir(), sanitize(picked))
            if (container.exists()) container.deleteRecursively()
            container.mkdirs()
            var count = 0
            sourceDir.walkTopDown().forEach { f ->
                if (count >= 500) return@forEach
                val rel = f.toRelativeString(sourceDir)
                if (rel.isEmpty() || rel == ".") return@forEach
                val target = File(container, rel)
                if (f.isDirectory) {
                    target.mkdirs()
                } else {
                    try {
                        target.parentFile?.mkdirs()
                        f.copyTo(target, overwrite = true)
                        count++
                    } catch (_: Exception) {
                    }
                }
            }
            if (count == 0) {
                container.deleteRecursively()
                cb(Result.success(""))
                lastPickReason = "这个文件夹里没有文件"
            } else {
                lastPickReason = null
                cb(Result.success(container.absolutePath))
            }
        } catch (e: Exception) {
            cb(Result.failure(e))
        }
    }

    /**
     * SAF 的 tree docId 换算成磁盘真实路径。
     *
     * docId 的格式是 `<卷ID>:<相对路径>`：
     *   - `primary:小小说`      → `/storage/emulated/0/小小说`
     *   - `1A2B-3C4D:照片`      → `/storage/1A2B-3C4D/照片`
     *   - `primary:`            → `/storage/emulated/0`（选了根）
     *
     * 换算不出来（比如网盘、下载 provider 的 `raw:`/`msf:` 形式）返回 null，
     * 调用方退回 SAF 递归。
     */
    private fun treeDocIdToPath(docId: String): File? {
        val idx = docId.indexOf(':')
        if (idx < 0) return null
        val volume = docId.substring(0, idx)
        val rel = docId.substring(idx + 1)
        if (volume.isEmpty() || rel.startsWith("raw:") || rel.startsWith("msf:")) {
            return null
        }
        val base = if (volume.equals("primary", ignoreCase = true)) {
            Environment.getExternalStorageDirectory()
        } else {
            File("/storage/$volume")
        }
        if (base == null || !base.exists()) return null
        return if (rel.isEmpty()) base else File(base, rel)
    }

    /** 上一次挑文件夹失败的原因（成功时为 null），供 Dart 侧展示。 */
    private var lastPickReason: String? = null

    private companion object {
        const val REQ_PICK_FOLDER = 0x9A01
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
