package com.thenex.nex_gallery

import android.app.Activity
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.Effect
import androidx.media3.effect.Presentation
import androidx.media3.effect.ScaleAndRotateTransformation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** One foreground export at a time; output is always an app-private new file. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class VideoEditor(private val activity: Activity) {
    private var transformer: Transformer? = null
    private var pending: MethodChannel.Result? = null
    private var output: File? = null

    fun start(call: MethodCall, result: MethodChannel.Result) {
        if (pending != null) { result.error("editor_busy", "An export is already running", null); return }
        try {
            fun privateFile(argument: String): File {
                val file = File(requireNotNull(call.argument<String>(argument))).canonicalFile
                require(listOf(activity.filesDir, activity.cacheDir).any {
                    file.path.startsWith(it.canonicalPath + File.separator)
                }) { "Editing paths must be app-private" }
                return file
            }
            val input = privateFile("input")
            val target = privateFile("output")
            require(input.isFile && !target.exists() && target.parentFile?.isDirectory == true) { "Invalid editing files" }
            val start = call.argument<Number>("startMs")!!.toLong()
            val end = call.argument<Number>("endMs")!!.toLong()
            val rotation = call.argument<Number>("rotation")!!.toInt()
            require(start >= 0 && end > start && rotation in listOf(0, 90, 180, 270)) { "Invalid edit range" }
            val effects = mutableListOf<Effect>()
            if (rotation != 0) effects.add(ScaleAndRotateTransformation.Builder().setRotationDegrees(rotation.toFloat()).build())
            if (call.argument<Boolean>("compress") == true) effects.add(Presentation.createForHeight(720))
            val media = MediaItem.Builder().setUri(Uri.fromFile(input)).setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder().setStartPositionMs(start).setEndPositionMs(end).build()
            ).build()
            val edited = EditedMediaItem.Builder(media).setRemoveAudio(call.argument<Boolean>("mute") == true)
                .setEffects(Effects(emptyList(), effects)).build()
            val built = Transformer.Builder(activity).setVideoMimeType(MimeTypes.VIDEO_H264)
                .addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                        val callback = pending
                        pending = null; transformer = null; output = null
                        callback?.success(mapOf("path" to target.absolutePath))
                    }
                    override fun onError(composition: Composition, exportResult: ExportResult, exception: ExportException) {
                        val callback = pending
                        pending = null; transformer = null; output = null
                        target.delete()
                        callback?.error("video_export_failed", exception.message, null)
                    }
                }).build()
            pending = result; output = target; transformer = built
            built.start(edited, target.absolutePath)
        } catch (error: Exception) {
            transformer?.cancel(); transformer = null; pending = null
            output?.delete(); output = null
            result.error("video_export_failed", error.message, null)
        }
    }

    fun cancel() {
        transformer?.cancel(); transformer = null
        output?.delete(); output = null
        pending?.error("export_cancelled", "Video export was cancelled", null); pending = null
    }
}
