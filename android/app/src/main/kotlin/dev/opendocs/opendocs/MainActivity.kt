package dev.opendocs.opendocs

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private val executor = Executors.newSingleThreadExecutor()
    private val scanning = AtomicBoolean(false)
    private var channel: MethodChannel? = null
    private var slideConverter: SlideConversionClient? = null
    private var accessResult: MethodChannel.Result? = null
    private var folderResult: MethodChannel.Result? = null
    private val incoming = mutableListOf<Map<String, Any>>()
    private val extensions = setOf("pdf", "doc", "docx", "ppt", "pptx")
    private val prefs get() = getSharedPreferences("opendocs.storage", MODE_PRIVATE)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.opendocs/storage")
        slideConverter = SlideConversionClient(this, channel!!)
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "convertSlides" -> { val path=call.argument<String>("path"); if(path==null) result.error("SLIDES","Choose a presentation first.",null) else slideConverter!!.convert(path,result) }
                "cancelSlides" -> { slideConverter?.cancel(); result.success(null) }
                "accessStatus" -> result.success(mapOf("allFiles" to hasAccess(), "folders" to folders().size))
                "requestAccess" -> requestAccess(result)
                "chooseFolder" -> {
                    if (folderResult != null) result.error("BUSY", "A folder picker is already open.", null)
                    else {
                        folderResult = result
                        try { startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                        }, 711) } catch (e: Exception) { folderResult = null; result.error("PICKER", e.message, null) }
                    }
                }
                "scan" -> scan(result)
                "cancelScan" -> { scanning.set(false); result.success(null) }
                "forgetFolders" -> {
                    folders().forEach { try { contentResolver.releasePersistableUriPermission(Uri.parse(it), Intent.FLAG_GRANT_READ_URI_PERMISSION) } catch (_: Exception) {} }
                    prefs.edit().remove("folders").apply(); result.success(null)
                }
                "materialize" -> executor.execute {
                    try {
                        val source = call.argument<String>("uri") ?: error("Missing document URI")
                        val file = if (source.startsWith("content:")) copyUri(Uri.parse(source), false) else mapOf("path" to source)
                        runOnUiThread { result.success(file) }
                    } catch (e: Exception) { runOnUiThread { result.error("OPEN", "File is unavailable. Scan again or choose it again.", null) } }
                }
                "takeIncoming" -> { val ready = incoming.toList(); incoming.clear(); result.success(ready) }
                else -> result.notImplemented()
            }
        }
        acceptIntent(intent)
    }

    private fun hasAccess(): Boolean = if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager()
        else checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
    private fun folders(): Set<String> = prefs.getStringSet("folders", emptySet())!!.toSet()
    private fun requestAccess(result: MethodChannel.Result) {
        if (hasAccess()) { result.success(true); return }
        if (accessResult != null) { result.error("BUSY", "Permission request is already open.", null); return }
        accessResult = result
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                startActivityForResult(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName")), 710)
            } else requestPermissions(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE), 710)
        } catch (_: Exception) {
            accessResult = null
            result.error("PERMISSION", "This device does not offer all-files access. Use Choose folder instead.", null)
        }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 710) { accessResult?.success(hasAccess()); accessResult = null }
    }
    @Deprecated("Required by Flutter activity result dispatch")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 710) { accessResult?.success(hasAccess()); accessResult = null }
        if (requestCode == 711) {
            val result = folderResult; folderResult = null
            val uri = if (resultCode == RESULT_OK) data?.data else null
            if (uri == null) { result?.success(false); return }
            try {
                contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                prefs.edit().putStringSet("folders", folders() + uri.toString()).apply()
                result?.success(true)
            } catch (e: Exception) { result?.error("FOLDER", "Could not keep permission for this folder.", null) }
        }
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); acceptIntent(intent) }
    private fun acceptIntent(intent: Intent?) {
        if (intent == null) return
        val uris = when (intent.action) {
            Intent.ACTION_VIEW -> listOfNotNull(intent.data)
            Intent.ACTION_SEND -> listOfNotNull(if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java) else @Suppress("DEPRECATION") intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
            Intent.ACTION_SEND_MULTIPLE -> (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java) else @Suppress("DEPRECATION") intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM))?.take(20) ?: emptyList()
            else -> emptyList()
        }
        if (uris.isEmpty()) return
        executor.execute {
            for (uri in uris) {
                try {
                    require(uri.scheme == "content" || uri.scheme == "file")
                    if (uri.scheme == "file") {
                        val f = File(uri.path!!).canonicalFile
                        val appRoot = File(applicationInfo.dataDir).canonicalPath + File.separator
                        require(!f.path.startsWith(appRoot)) { "Private files cannot be shared through external intents" }
                    }
                    val copied = copyUri(uri, true)
                    runOnUiThread { incoming.add(copied); channel?.invokeMethod("incomingAvailable", null) }
                } catch (e: Exception) {
                    if ((applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0) android.util.Log.w("OpenDocs", "Incoming fixture/file could not be read: ${e.javaClass.simpleName}", e)
                    runOnUiThread { channel?.invokeMethod("incomingError", "Could not open this file. Use a local PDF, DOC, DOCX, PPT or PPTX under 128 MB.") }
                }
            }
        }
    }
    private fun copyUri(uri: Uri, permanent: Boolean): Map<String, Any> {
        var name = uri.lastPathSegment?.substringAfterLast('/') ?: "document"
        if (uri.scheme == "content") contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) name = c.getString(0) ?: name
        }
        val ext = name.substringAfterLast('.', "").lowercase()
        require(ext in extensions) { "Unsupported format" }
        name = name.replace(Regex("[\\x00-\\x1f/\\\\]"), "_").take(240)
        val directory = File(if (permanent) filesDir else cacheDir, if (permanent) "documents" else "opened").apply { mkdirs() }
        val file = File(directory, "${UUID.randomUUID()}.$ext")
        try {
            val input = if (uri.scheme == "file") File(uri.path!!).inputStream() else contentResolver.openInputStream(uri) ?: error("Unavailable")
            input.use { source -> file.outputStream().use { target ->
                val buffer = ByteArray(64 * 1024); var total = 0L
                while (true) { val n = source.read(buffer); if (n < 0) break; total += n; require(total <= 128L * 1024 * 1024) { "File too large" }; target.write(buffer, 0, n) }
            } }
        } catch (e: Exception) { file.delete(); throw e }
        return mapOf("name" to name, "path" to file.path, "size" to file.length(), "modified" to file.lastModified(), "owned" to permanent)
    }

    private fun scan(result: MethodChannel.Result) {
        if (!scanning.compareAndSet(false, true)) { result.error("BUSY", "A scan is already running.", null); return }
        executor.execute {
            val docs = linkedMapOf<String, Map<String, Any>>()
            var denied = 0; var directories = 0; var truncated = false
            try {
                if (hasAccess()) {
                    val roots = mutableSetOf(Environment.getExternalStorageDirectory().canonicalPath)
                    getExternalFilesDirs(null).filterNotNull().forEach { f -> f.path.indexOf("/Android/").takeIf { it > 0 }?.let { roots.add(f.path.substring(0, it)) } }
                    val queue = ArrayDeque<File>(); roots.forEach { queue.add(File(it)) }
                    val seen = mutableSetOf<String>()
                    while (queue.isNotEmpty() && scanning.get()) {
                        if (docs.size >= 50000 || directories >= 10000) { truncated = true; break }
                        val dir = queue.removeFirst(); val canonical = try { dir.canonicalPath } catch (_: Exception) { denied++; continue }
                        if (!seen.add(canonical) || !roots.any { canonical == it || canonical.startsWith("$it/") }) continue
                        directories++
                        val children = dir.listFiles(); if (children == null) { denied++; continue }
                        for (file in children) {
                            if (!scanning.get()) break
                            if (file.name.startsWith('.')) continue
                            if (file.isDirectory) {
                                val protected = file.parentFile?.name == "Android" && file.name in setOf("data", "obb")
                                if (!protected && file.path.count { it == '/' } < 45) queue.add(file)
                            }
                            else if (file.extension.lowercase() in extensions && file.isFile) {
                                docs[file.path] = mapOf("name" to file.name, "path" to file.path, "size" to file.length(), "modified" to file.lastModified(), "owned" to false)
                                if (docs.size >= 50000) { truncated = true; break }
                            }
                        }
                    }
                }
                for (tree in folders()) {
                    if (!scanning.get() || truncated) break
                    val treeUri = Uri.parse(tree)
                    val queue = ArrayDeque<String>(); queue.add(DocumentsContract.getTreeDocumentId(treeUri))
                    val seen = mutableSetOf<String>()
                    while (queue.isNotEmpty() && scanning.get()) {
                        if (docs.size >= 50000 || directories >= 10000) { truncated = true; break }
                        val id = queue.removeFirst(); if (!seen.add(id)) continue; directories++
                        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, id)
                        try {
                            contentResolver.query(childrenUri, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null)?.use { c ->
                                while (c.moveToNext() && scanning.get()) {
                                    val childId = c.getString(0); val name = c.getString(1) ?: "document"
                                    if (c.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) queue.add(childId)
                                    else if (name.substringAfterLast('.', "").lowercase() in extensions) {
                                        val uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, childId).toString()
                                        docs[uri] = mapOf("name" to name, "path" to uri, "size" to c.getLong(3), "modified" to c.getLong(4), "owned" to false)
                                        if (docs.size >= 50000) { truncated = true; break }
                                    }
                                }
                            }
                        } catch (_: Exception) { denied++ }
                    }
                }
                val cancelled = !scanning.get(); scanning.set(false)
                runOnUiThread { result.success(mapOf("documents" to docs.values.toList(), "skipped" to denied, "truncated" to truncated, "cancelled" to cancelled)) }
            } catch (e: Exception) { scanning.set(false); runOnUiThread { result.error("SCAN", "Storage access changed. Grant access or choose a folder again.", null) } }
        }
    }
}
