package dev.opendocs.opendocs

import android.app.Service
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.pdf.PdfRenderer
import android.os.*
import org.libreoffice.kit.Document
import org.libreoffice.kit.LibreOfficeKit
import org.libreoffice.kit.Office
import java.io.*
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt

/** The full office engine lives in a private process; a broken document cannot take down the library. */
class SlideConversionService : Service() {
    private val worker = Executors.newSingleThreadExecutor()
    private val cancelled = AtomicBoolean(false)
    private var office: Office? = null
    private var inputSnapshot: File? = null
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
        when (message.what) {
            1 -> {
                val source = message.data.getString("path")
                val reply = message.replyTo
                worker.execute {
                    cancelled.set(false)
                    try {
                        require(source != null)
                        val output = convert(File(source), reply)
                        send(reply, 2, output)
                    } catch (error: Throwable) {
                        if ((applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0) android.util.Log.w("OpenDocsSlides", "Slide conversion failed: ${error.javaClass.simpleName}", error)
                        send(reply, 4, Bundle().apply { putString("error", if (cancelled.get()) "Conversion cancelled." else "Could not prepare this document. The file may be damaged, encrypted or too large.") })
                    } finally {
                        inputSnapshot?.delete(); inputSnapshot=null
                    }
                }
            }
            5 -> cancelled.set(true)
        }
        true
    })
    override fun onBind(intent: Intent): IBinder = messenger.binder
    override fun onDestroy() {
        cancelled.set(true); worker.shutdownNow(); super.onDestroy()
        // Native office code is process-wide; release its memory after the client disconnects.
        if (Build.VERSION.SDK_INT >= 28 && android.app.Application.getProcessName().endsWith(":slides")) android.os.Process.killProcess(android.os.Process.myPid())
    }
    private fun send(reply: Messenger, type: Int, data: Bundle) {
        try { reply.send(Message.obtain(null, type).apply { this.data = data }) } catch (_: RemoteException) { cancelled.set(true) }
    }
    private fun progress(reply: Messenger, done: Int, total: Int, stage: String) = send(reply, 3, Bundle().apply {
        putInt("completed", done); putInt("total", total); putString("stage", stage)
    })
    private fun unpackAssets(path: String, target: File) {
        val children = assets.list(path) ?: emptyArray()
        if (children.isEmpty()) {
            target.parentFile?.mkdirs()
            assets.open(path).use { input -> target.outputStream().use { input.copyTo(it) } }
        } else {
            target.mkdirs()
            children.forEach { child -> unpackAssets("$path/$child", File(target, child)) }
        }
    }
    private fun initialize(reply: Messenger) {
        if (office != null) return
        progress(reply, 0, 0, "Preparing offline document engine")
        val marker = File(filesDir, "libreoffice-engine-26.2.6.3.ready")
        if (!marker.exists()) {
            // These directories are part of the official Android bootstrap, not network downloads.
            assets.list("unpack")?.forEach { child -> unpackAssets("unpack/$child", File(applicationInfo.dataDir, child)) }
            marker.writeText("26.2.6.3")
        }
        LibreOfficeKit.putenv("SAL_LOG=-INFO-WARN")
        LibreOfficeKit.putenv("SAL_LOK_OPTIONS=compact_fonts")
        LibreOfficeKit.putenv("SAL_ENABLE_FILE_LOCKING=0")
        LibreOfficeKit.init(this)
        val handle = LibreOfficeKit.getLibreOfficeKitHandle() ?: error("Office engine unavailable")
        office = Office(handle).apply { setOptionalFeatures(0) }
    }
    // Writer exports original pagination first. Android rasterizes that layout one page at a time.
    private fun renderWord(document: Document, dir: File, id: String, target: File, meta: File, reply: Messenger): Bundle {
        val layout = File(dir, "$id-layout.pdf")
        val pending = File(dir, "$id-word.pending.pdf")
        val jpeg = File(dir, "$id-word.jpg")
        try {
            progress(reply, 0, 0, "Preparing document pages")
            document.saveAs(layout.absolutePath, "pdf", "")
            check(layout.exists() && layout.length() > 100)
            ParcelFileDescriptor.open(layout, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                PdfRenderer(descriptor).use { pdf ->
                    val count = pdf.pageCount
                    require(count in 1..250)
                    ImagePdfWriter(pending, count, 1.0, 1.0).use { writer ->
                        for (index in 0 until count) {
                            check(!cancelled.get())
                            progress(reply, index, count, "Rendering page ${index + 1} of $count")
                            pdf.openPage(index).use { page ->
                                val scale = 1920.0 / maxOf(page.width, page.height)
                                val width = (page.width * scale).roundToInt().coerceAtLeast(1)
                                val height = (page.height * scale).roundToInt().coerceAtLeast(1)
                                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                                try {
                                    bitmap.eraseColor(Color.WHITE)
                                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                    jpeg.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it)) }
                                    writer.addPage(index, jpeg, width, height, page.width.toDouble(), page.height.toDouble())
                                } finally { bitmap.recycle() }
                            }
                        }
                        writer.finish()
                    }
                    check(pending.renameTo(target))
                    meta.writeText(count.toString())
                    progress(reply, count, count, "Document ready")
                    return Bundle().apply { putString("path", target.path); putInt("pages", count); putBoolean("cached", false) }
                }
            }
        } finally { layout.delete(); pending.delete(); jpeg.delete() }
    }
    private fun convert(source: File, reply: Messenger): Bundle {
        require(source.isFile && source.length() in 1..(128L * 1024 * 1024))
        require(source.extension.lowercase() in setOf("ppt", "pptx", "doc", "docx"))
        val digest = MessageDigest.getInstance("SHA-256")
        val inputDirectory=File(cacheDir,"slide-input").apply { mkdirs() }
        inputDirectory.listFiles()?.forEach { it.delete() }
        val snapshot=File.createTempFile("slide-", ".${source.extension.lowercase()}", inputDirectory)
        inputSnapshot=snapshot
        source.inputStream().use { input -> snapshot.outputStream().use { copy ->
            val bytes=ByteArray(64*1024);var size=0L
            while(true){val n=input.read(bytes);if(n<0)break;size+=n;require(size<=128L*1024*1024);digest.update(bytes,0,n);copy.write(bytes,0,n)}
        } }

        val id = digest.digest().joinToString("") { "%02x".format(it) }
        val dir = File(cacheDir, "slide-pdf").apply { mkdirs() }
        var cacheBytes = dir.listFiles()?.sumOf { it.length() } ?: 0L
        dir.listFiles()?.sortedBy { it.lastModified() }?.forEach { file ->
            if (cacheBytes > 160L * 1024 * 1024 || file.name.endsWith(".pending.pdf") || file.name.endsWith(".jpg")) {
                val size = file.length(); if (file.delete()) cacheBytes -= size
            }
        }
        val target = File(dir, "$id-lo26-image-v3.pdf")
        val meta = File(dir, "$id-lo26-image-v3.count")
        val cachedCount=if(meta.exists()) meta.readText().toIntOrNull() else null
        if (target.exists() && target.length()>100 && cachedCount!=null && cachedCount in 1..250) return Bundle().apply { putString("path", target.path); putInt("pages", cachedCount); putBoolean("cached",true) }
        initialize(reply)
        check(!cancelled.get())
        val document = office!!.documentLoad(snapshot.absolutePath) ?: error("Unsupported presentation")
        val pending = File(dir, "$id.pending.pdf")
        try {
            if (document.documentType == Document.DOCTYPE_TEXT) {
                return renderWord(document, dir, id, target, meta, reply)
            }
            require(document.documentType == Document.DOCTYPE_PRESENTATION)
            document.initializeForRendering()
            document.setPartMode(Document.PART_MODE_SLIDE)
            val count = document.parts
            require(count in 1..250) { "Slide limit exceeded" }
            val widthTwips = document.documentWidth.toInt()
            val heightTwips = document.documentHeight.toInt()
            require(widthTwips > 0 && heightTwips > 0)
            val width = if (widthTwips >= heightTwips) 1920 else (1920.0 * widthTwips / heightTwips).roundToInt().coerceAtLeast(1)
            val height = if (heightTwips >= widthTwips) 1920 else (1920.0 * heightTwips / widthTwips).roundToInt().coerceAtLeast(1)
            val buffer = ByteBuffer.allocateDirect(width * height * 4)
            ImagePdfWriter(pending, count, widthTwips / 20.0, heightTwips / 20.0).use { writer ->
                for (index in 0 until count) {
                    check(!cancelled.get())
                    progress(reply, index, count, "Rendering slide ${index + 1} of $count")
                    document.setPart(index)
                    buffer.rewind()
                    document.paintTile(buffer, width, height, 0, 0, widthTwips, heightTwips)
                    buffer.rewind()
                    val tile = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    val opaque = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    try {
                        tile.copyPixelsFromBuffer(buffer)
                        val canvas = Canvas(opaque); canvas.drawColor(Color.WHITE); canvas.drawBitmap(tile, 0f, 0f, Paint(Paint.FILTER_BITMAP_FLAG))
                        val image = File(dir, "$id-slide.jpg")
                        image.outputStream().use { out -> check(opaque.compress(Bitmap.CompressFormat.JPEG, 90, out)) }
                        if (index == 0 && (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0) File(dir, "$id-preview.png").outputStream().use { opaque.compress(Bitmap.CompressFormat.PNG, 100, it) }
                        writer.addPage(index, image, width, height)
                        image.delete()
                    } finally { tile.recycle(); opaque.recycle() }
                }
                writer.finish()
            }
            check(pending.length() > 100)
            check(pending.renameTo(target))
            meta.writeText(count.toString())
            progress(reply, count, count, "Slides ready")
            return Bundle().apply { putString("path",target.path); putInt("pages",count); putBoolean("cached",false) }
        } finally {
            document.destroy(); pending.delete()
        }
    }
}

/** Writes one JPEG per PDF page directly to disk; only one rendered slide is held in memory. */
private class ImagePdfWriter(file: File, private val pageCount: Int, private val pageWidth: Double, private val pageHeight: Double) : Closeable {
    private val output = BufferedOutputStream(FileOutputStream(file))
    private var position = 0L
    private val offsets = LongArray(3 + pageCount * 3)
    private var completed = false
    init { text("%PDF-1.4\n%OpenDocs slide images\n") }
    private fun text(value: String) { val bytes=value.toByteArray(Charsets.US_ASCII); output.write(bytes); position+=bytes.size }
    private fun start(id: Int) { offsets[id]=position; text("$id 0 obj\n") }
    fun addPage(index: Int, jpeg: File, width: Int, height: Int, pageWidth: Double = this.pageWidth, pageHeight: Double = this.pageHeight) {
        val page=3+index*3; val image=page+1; val content=page+2
        start(page); text("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $pageWidth $pageHeight] /Resources << /XObject << /Slide $image 0 R >> >> /Contents $content 0 R >>\nendobj\n")
        start(image); text("<< /Type /XObject /Subtype /Image /Width $width /Height $height /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${jpeg.length()} >>\nstream\n")
        jpeg.inputStream().use { input -> val buffer=ByteArray(64*1024); while(true){val n=input.read(buffer);if(n<0)break;output.write(buffer,0,n);position+=n} }
        text("\nendstream\nendobj\n")
        val commands="q $pageWidth 0 0 $pageHeight 0 0 cm /Slide Do Q\n"
        start(content); text("<< /Length ${commands.toByteArray(Charsets.US_ASCII).size} >>\nstream\n$commands" + "endstream\nendobj\n")
    }
    fun finish() {
        start(1);text("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
        start(2);text("<< /Type /Pages /Count $pageCount /Kids [${(0 until pageCount).joinToString(" ") { "${3+it*3} 0 R" }}] >>\nendobj\n")
        val xref=position;text("xref\n0 ${offsets.size}\n0000000000 65535 f \n")
        for(id in 1 until offsets.size)text("${offsets[id].toString().padStart(10,'0')} 00000 n \n")
        text("trailer\n<< /Size ${offsets.size} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n");output.flush();completed=true
    }
    override fun close(){output.close();check(completed){"Slide conversion incomplete"}}
}
