package com.thenex.nex_gallery

import android.Manifest
import android.app.Activity
import android.app.RecoverableSecurityException
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Size
import android.view.WindowManager
import androidx.annotation.RequiresApi
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Dependency-free Android MediaStore bridge.
 *
 * All public results contain primitive values, lists, maps, or byte arrays so
 * they can be decoded by Flutter's StandardMessageCodec. User media is
 * addressed by content URI; exposed filesystem paths are restricted to this
 * app's private files and cache directories.
 */
class AndroidMediaBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val resolver = activity.contentResolver
    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newFixedThreadPool(2)
    private var permissionResult: MethodChannel.Result? = null
    private var permissionTypes: Set<MediaKind> = emptySet()
    private var consentResult: MethodChannel.Result? = null
    private var consentOperation: String? = null
    private var consentCount = 0
    private var consentDeletedCount = 0
    private var directoryPickerResult: MethodChannel.Result? = null
    private var documentPickerResult: MethodChannel.Result? = null
    private val videoEditor = VideoEditor(activity)
    private val secretLock = Any()
    private val cacheFileLock = Any()

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getPermissionStatus" -> result.success(permissionStatus(parseKinds(call)))
                "requestPermissions" -> requestPermissions(call, result)
                "queryMedia" -> runAsync(result) { queryMedia(call) }
                "loadThumbnail" -> runAsync(result) { loadThumbnail(call) }
                "deleteMedia" -> deleteOrTrash(call, result, trash = false)
                "trashMedia" -> deleteOrTrash(call, result, trash = true)
                "openMedia" -> openMedia(call, result)
                "shareMedia" -> shareMedia(call, result)
                "getStorageStats" -> runAsync(result) { storageStats() }
                "getAppDataPath" -> result.success(activity.filesDir.absolutePath)
                "pickDirectory" -> pickDirectory(result)
                "pickDocument" -> pickDocument(result)
                "copyDocumentToAppCache" -> runAsync(result) { copyDocumentToAppCache(call) }
                "openAppFile" -> openAppFile(call, result)
                "shareAppFile" -> shareAppFile(call, result)
                "getPersistedDirectories" -> runAsync(result) { persistedDirectories() }
                "listDirectory" -> runAsync(result) { listDirectory(call) }
                "createDirectory" -> runAsync(result) { createDirectory(call) }
                "renameDocument" -> runAsync(result) { renameDocument(call) }
                "deleteDocument" -> runAsync(result) { deleteDocument(call) }
                "zipDocument" -> runAsync(result) { SafArchives(resolver).zip(call) }
                "extractDocument" -> runAsync(result) { SafArchives(resolver).extract(call) }
                "copyDocument" -> runAsync(result) { copyDocument(call) }
                "exportAppFile" -> runAsync(result) { exportAppFile(call) }
                "exportAppMedia" -> runAsync(result) { exportAppMedia(call) }
                "editVideo" -> videoEditor.start(call, result)
                "cancelVideoEdit" -> { videoEditor.cancel(); result.success(null) }
                "setPrivacyScreen" -> {
                    if (call.argument<Boolean>("enabled") == true) {
                        activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else { activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) }
                    result.success(mapOf("status" to "completed"))
                }
                "storeSecret" -> runAsync(result) { storeSecret(call) }
                "readSecret" -> runAsync(result) { readSecret(call) }
                "deleteSecret" -> runAsync(result) { deleteSecret(call) }
                "openAppSettings" -> openAppSettings(result)
                else -> result.notImplemented()
            }
        } catch (error: BridgeException) {
            result.error(error.code, error.message, null)
        } catch (error: SecurityException) {
            result.error("permission_denied", error.message, null)
        } catch (error: Exception) {
            // Synchronous framework calls such as MediaStore consent creation
            // can reject a malformed or unsupported provider URI. Always finish
            // the MethodChannel call instead of leaving Flutter waiting forever.
            result.error(
                "android_media_error",
                error.message ?: "Android could not complete the media operation",
                null,
            )
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        videoEditor.cancel()
        worker.shutdownNow()
        permissionResult?.error("activity_destroyed", "Activity closed during permission request", null)
        permissionResult = null
        consentResult?.error("activity_destroyed", "Activity closed during media consent", null)
        consentResult = null
        directoryPickerResult?.error("activity_destroyed", "Activity closed during folder selection", null)
        directoryPickerResult = null
        documentPickerResult?.error("activity_destroyed", "Activity closed during document selection", null)
        documentPickerResult = null
    }

    fun onRequestPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != PERMISSION_REQUEST || permissionResult == null) return false
        val result = permissionResult
        val kinds = permissionTypes
        permissionResult = null
        permissionTypes = emptySet()
        result?.success(permissionStatus(kinds))
        return true
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == DOCUMENT_PICKER_REQUEST && documentPickerResult != null) {
            val result = documentPickerResult
            documentPickerResult = null
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                result?.success(mapOf("status" to "cancelled"))
                return true
            }
            val uri = try {
                validatedUri(data.data!!.toString())
            } catch (error: BridgeException) {
                result?.error(error.code, error.message, null)
                return true
            }
            val canRead = data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0
            val persisted = canRead && persistUriGrant(uri, read = true, write = false)
            if (result != null) {
                runAsync(result) { documentDescriptor(uri, "selected", persisted) }
            }
            return true
        }
        if (requestCode == DIRECTORY_PICKER_REQUEST && directoryPickerResult != null) {
            val result = directoryPickerResult
            directoryPickerResult = null
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                result?.success(mapOf("status" to "cancelled"))
                return true
            }
            val uri = data.data!!
            val canRead = data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0
            val canWrite = data.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0
            val persisted = persistDirectoryGrant(uri, canRead, canWrite)
            if (result != null) {
                runAsync(result) {
                    directoryDescriptor(
                        uri,
                        "selected",
                        persisted,
                        grantedRead = canRead,
                        grantedWrite = canWrite,
                    )
                }
            }
            return true
        }
        if (requestCode != CONSENT_REQUEST || consentResult == null) return false
        val result = consentResult
        val operation = consentOperation ?: "mediaConsent"
        val count = consentCount
        val alreadyDeleted = consentDeletedCount
        clearConsent()
        if (resultCode == Activity.RESULT_OK) {
            val retried = operation == "deleteAuthorization"
            result?.success(
                mapOf(
                    "status" to if (retried) "authorized" else "completed",
                    "operation" to operation,
                    "requestedCount" to count,
                    "deletedCount" to if (retried) alreadyDeleted else count,
                    "affectedCount" to if (retried) alreadyDeleted else count,
                    "requiresRetry" to retried,
                ),
            )
        } else {
            result?.success(
                mapOf(
                    "status" to "cancelled",
                    "operation" to operation,
                    "requestedCount" to count,
                    "deletedCount" to alreadyDeleted,
                    "affectedCount" to alreadyDeleted,
                    "requiresRetry" to false,
                ),
            )
        }
        return true
    }

    private fun requestPermissions(call: MethodCall, result: MethodChannel.Result) {
        if (hasPendingSystemRequest()) {
            result.error("permission_request_active", "Another permission request is in progress", null)
            return
        }
        val kinds = parseKinds(call)
        val includeLegacyWrite = call.argument<Boolean>("includeWriteForLegacy") ?: false
        val needed = permissionsFor(kinds, includeLegacyWrite).filterNot(::isGranted)
        if (needed.isEmpty()) {
            result.success(permissionStatus(kinds))
            return
        }
        permissionResult = result
        permissionTypes = kinds
        try {
            activity.requestPermissions(needed.toTypedArray(), PERMISSION_REQUEST)
        } catch (error: Exception) {
            permissionResult = null
            permissionTypes = emptySet()
            throw error
        }
    }

    private fun permissionStatus(kinds: Set<MediaKind>): Map<String, Any> {
        val requested = if (kinds.isEmpty()) MediaKind.entries.toSet() else kinds
        val statuses = linkedMapOf<String, String>()
        requested.forEach { kind -> statuses[kind.wireName] = permissionFor(kind) }
        val visualStatuses = requested
            .filter { it != MediaKind.AUDIO }
            .map(::permissionFor)
        val visualAccess = when {
            visualStatuses.isNotEmpty() && visualStatuses.all { it == "granted" } -> "full"
            visualStatuses.any { it == "granted" || it == "partial" } -> "partial"
            else -> "denied"
        }
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "statuses" to statuses,
            "visualAccess" to visualAccess,
            "canOpenSettings" to true,
        )
    }

    private fun permissionFor(kind: MediaKind): String {
        if (Build.VERSION.SDK_INT >= 33) {
            val permission = when (kind) {
                MediaKind.IMAGE -> Manifest.permission.READ_MEDIA_IMAGES
                MediaKind.VIDEO -> Manifest.permission.READ_MEDIA_VIDEO
                MediaKind.AUDIO -> Manifest.permission.READ_MEDIA_AUDIO
            }
            if (isGranted(permission)) return "granted"
            if (Build.VERSION.SDK_INT >= 34 && kind != MediaKind.AUDIO &&
                isGranted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
            ) {
                return "partial"
            }
            return "denied"
        }
        return if (isGranted(Manifest.permission.READ_EXTERNAL_STORAGE)) "granted" else "denied"
    }

    private fun permissionsFor(kinds: Set<MediaKind>, includeLegacyWrite: Boolean): List<String> {
        if (Build.VERSION.SDK_INT >= 33) {
            val permissions = mutableListOf<String>()
            if (MediaKind.IMAGE in kinds) permissions += Manifest.permission.READ_MEDIA_IMAGES
            if (MediaKind.VIDEO in kinds) permissions += Manifest.permission.READ_MEDIA_VIDEO
            if (MediaKind.AUDIO in kinds) permissions += Manifest.permission.READ_MEDIA_AUDIO
            if (Build.VERSION.SDK_INT >= 34 &&
                (MediaKind.IMAGE in kinds || MediaKind.VIDEO in kinds)
            ) {
                permissions += Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED
            }
            return permissions.distinct()
        }
        return buildList {
            add(Manifest.permission.READ_EXTERNAL_STORAGE)
            if (includeLegacyWrite && Build.VERSION.SDK_INT <= 28) {
                add(Manifest.permission.WRITE_EXTERNAL_STORAGE)
            }
        }
    }

    private fun queryMedia(call: MethodCall): Map<String, Any?> {
        val kind = MediaKind.fromWire(call.argument<String>("mediaType"))
            ?: throw BridgeException("invalid_media_type", "mediaType must be image, video, or audio")
        val limit = (call.argument<Number>("limit")?.toInt() ?: 100).coerceIn(1, MAX_PAGE_SIZE)
        val offset = (call.argument<Number>("offset")?.toInt() ?: 0).coerceAtLeast(0)
        val descending = call.argument<Boolean>("descending") ?: true
        val sortBy = call.argument<String>("sortBy") ?: "dateAdded"
        val sortColumn = sortColumn(kind, sortBy)
        val projection = projection(kind)
        val uri = collectionUri(kind)
        val selectionParts = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= 29) {
            selectionParts += "${MediaStore.MediaColumns.IS_PENDING}=0"
        }
        if (Build.VERSION.SDK_INT >= 30) {
            selectionParts += "${MediaStore.MediaColumns.IS_TRASHED}=0"
        }
        val selection = selectionParts.takeIf { it.isNotEmpty() }?.joinToString(" AND ")
        val items = ArrayList<Map<String, Any?>>(limit + 1)
        val direction = if (descending) "DESC" else "ASC"
        resolver.query(uri, projection, selection, null, "$sortColumn $direction")?.use { cursor ->
            if (offset > 0 && !cursor.moveToPosition(offset - 1)) {
                return@use
            }
            while (cursor.moveToNext() && items.size < limit + 1) {
                items += cursorItem(cursor, kind, uri)
            }
        } ?: throw BridgeException("query_failed", "Android returned no cursor for $kind")
        val hasMore = items.size > limit
        if (hasMore) items.removeAt(items.lastIndex)
        return mapOf(
            "items" to items,
            "mediaType" to kind.wireName,
            "offset" to offset,
            "limit" to limit,
            "hasMore" to hasMore,
            "nextOffset" to if (hasMore) offset + items.size else null,
        )
    }

    private fun projection(kind: MediaKind): Array<String> = buildList {
        add(MediaStore.MediaColumns._ID)
        add(MediaStore.MediaColumns.DISPLAY_NAME)
        add(MediaStore.MediaColumns.MIME_TYPE)
        add(MediaStore.MediaColumns.SIZE)
        add(MediaStore.MediaColumns.DATE_ADDED)
        add(MediaStore.MediaColumns.DATE_MODIFIED)
        if (kind != MediaKind.AUDIO) {
            add(MediaStore.MediaColumns.WIDTH)
            add(MediaStore.MediaColumns.HEIGHT)
            add(MediaStore.Images.ImageColumns.DATE_TAKEN)
            add(MediaStore.Images.ImageColumns.BUCKET_ID)
            add(MediaStore.Images.ImageColumns.BUCKET_DISPLAY_NAME)
        }
        if (kind != MediaKind.IMAGE) add(MediaStore.MediaColumns.DURATION)
        if (kind == MediaKind.IMAGE) add(MediaStore.Images.ImageColumns.ORIENTATION)
        if (kind == MediaKind.AUDIO) {
            add(MediaStore.Audio.AudioColumns.TITLE)
            add(MediaStore.Audio.AudioColumns.ARTIST)
            add(MediaStore.Audio.AudioColumns.ALBUM)
        }
        if (Build.VERSION.SDK_INT >= 29) {
            add(MediaStore.MediaColumns.RELATIVE_PATH)
            add(MediaStore.MediaColumns.IS_PENDING)
        }
        if (Build.VERSION.SDK_INT >= 30) add(MediaStore.MediaColumns.IS_TRASHED)
    }.distinct().toTypedArray()

    private fun cursorItem(
        cursor: android.database.Cursor,
        kind: MediaKind,
        collection: Uri,
    ): Map<String, Any?> {
        val id = cursor.long(MediaStore.MediaColumns._ID) ?: 0L
        return linkedMapOf(
            "id" to id,
            "uri" to ContentUris.withAppendedId(collection, id).toString(),
            "mediaType" to kind.wireName,
            "displayName" to cursor.string(MediaStore.MediaColumns.DISPLAY_NAME),
            "mimeType" to cursor.string(MediaStore.MediaColumns.MIME_TYPE),
            "size" to cursor.long(MediaStore.MediaColumns.SIZE),
            "dateAdded" to cursor.long(MediaStore.MediaColumns.DATE_ADDED),
            "dateModified" to cursor.long(MediaStore.MediaColumns.DATE_MODIFIED),
            "dateTaken" to if (kind != MediaKind.AUDIO) {
                cursor.long(MediaStore.Images.ImageColumns.DATE_TAKEN)
            } else {
                null
            },
            "width" to if (kind != MediaKind.AUDIO) cursor.long(MediaStore.MediaColumns.WIDTH) else null,
            "height" to if (kind != MediaKind.AUDIO) cursor.long(MediaStore.MediaColumns.HEIGHT) else null,
            "duration" to if (kind != MediaKind.IMAGE) cursor.long(MediaStore.MediaColumns.DURATION) else null,
            "orientation" to if (kind == MediaKind.IMAGE) {
                cursor.long(MediaStore.Images.ImageColumns.ORIENTATION)
            } else {
                null
            },
            "bucketId" to if (kind != MediaKind.AUDIO) {
                cursor.string(MediaStore.Images.ImageColumns.BUCKET_ID)
            } else {
                null
            },
            "bucketName" to if (kind != MediaKind.AUDIO) {
                cursor.string(MediaStore.Images.ImageColumns.BUCKET_DISPLAY_NAME)
            } else {
                null
            },
            "title" to if (kind == MediaKind.AUDIO) cursor.string(MediaStore.Audio.AudioColumns.TITLE) else null,
            "artist" to if (kind == MediaKind.AUDIO) cursor.string(MediaStore.Audio.AudioColumns.ARTIST) else null,
            "album" to if (kind == MediaKind.AUDIO) cursor.string(MediaStore.Audio.AudioColumns.ALBUM) else null,
            "relativePath" to if (Build.VERSION.SDK_INT >= 29) {
                cursor.string(MediaStore.MediaColumns.RELATIVE_PATH)
            } else {
                null
            },
        )
    }

    private fun loadThumbnail(call: MethodCall): Map<String, Any> {
        val uri = validatedUri(call.argument<String>("uri"))
        val requestedSize = (call.argument<Number>("size")?.toInt() ?: 256).coerceIn(32, MAX_THUMBNAIL_SIZE)
        val formatName = (call.argument<String>("format") ?: "jpeg").lowercase()
        val quality = (call.argument<Number>("quality")?.toInt() ?: 85).coerceIn(1, 100)
        val compressFormat = when (formatName) {
            "jpeg", "jpg" -> Bitmap.CompressFormat.JPEG
            "png" -> Bitmap.CompressFormat.PNG
            else -> throw BridgeException("invalid_format", "format must be jpeg or png")
        }
        var bitmap = if (Build.VERSION.SDK_INT >= 29) {
            resolver.loadThumbnail(uri, Size(requestedSize, requestedSize), null)
        } else {
            legacyThumbnail(uri, requestedSize)
        }
        if (bitmap.width > requestedSize || bitmap.height > requestedSize) {
            val scale = minOf(requestedSize.toFloat() / bitmap.width, requestedSize.toFloat() / bitmap.height)
            val scaled = Bitmap.createScaledBitmap(
                bitmap,
                max(1, (bitmap.width * scale).roundToInt()),
                max(1, (bitmap.height * scale).roundToInt()),
                true,
            )
            if (scaled !== bitmap) bitmap.recycle()
            bitmap = scaled
        }
        val output = ByteArrayOutputStream()
        if (!bitmap.compress(compressFormat, quality, output)) {
            bitmap.recycle()
            throw BridgeException("thumbnail_encode_failed", "Could not encode thumbnail")
        }
        val width = bitmap.width
        val height = bitmap.height
        bitmap.recycle()
        return mapOf(
            "bytes" to output.toByteArray(),
            "width" to width,
            "height" to height,
            "mimeType" to if (compressFormat == Bitmap.CompressFormat.PNG) "image/png" else "image/jpeg",
        )
    }

    private fun legacyThumbnail(uri: Uri, size: Int): Bitmap {
        val mime = resolver.getType(uri).orEmpty()
        return when {
            mime.startsWith("video/") || mime.startsWith("audio/") -> {
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(activity, uri)
                    if (mime.startsWith("audio/")) {
                        val art = retriever.embeddedPicture
                            ?: throw BridgeException("thumbnail_unavailable", "Audio file has no embedded artwork")
                        decodeBounded(art, size)
                    } else {
                        retriever.getFrameAtTime(-1, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                            ?: throw BridgeException("thumbnail_unavailable", "Video has no decodable frame")
                    }
                } finally {
                    retriever.release()
                }
            }
            else -> resolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFileDescriptor(descriptor.fileDescriptor, null, bounds)
                val sample = calculateSampleSize(bounds.outWidth, bounds.outHeight, size)
                val options = BitmapFactory.Options().apply { inSampleSize = sample }
                BitmapFactory.decodeFileDescriptor(descriptor.fileDescriptor, null, options)
                    ?: throw BridgeException("thumbnail_decode_failed", "Image could not be decoded")
            } ?: throw FileNotFoundException("Could not open $uri")
        }
    }

    private fun decodeBounded(bytes: ByteArray, size: Int): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val options = BitmapFactory.Options().apply {
            inSampleSize = calculateSampleSize(bounds.outWidth, bounds.outHeight, size)
        }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
            ?: throw BridgeException("thumbnail_decode_failed", "Artwork could not be decoded")
    }

    private fun calculateSampleSize(width: Int, height: Int, requested: Int): Int {
        var sample = 1
        while (width / (sample * 2) >= requested && height / (sample * 2) >= requested) sample *= 2
        return sample
    }

    private fun deleteOrTrash(call: MethodCall, result: MethodChannel.Result, trash: Boolean) {
        if (hasPendingSystemRequest()) {
            result.error("media_consent_active", "Another media consent request is in progress", null)
            return
        }
        val uris = parseUris(call)
        if (uris.isEmpty()) {
            result.error("empty_uris", "At least one content URI is required", null)
            return
        }
        if (trash && Build.VERSION.SDK_INT < 30) {
            result.success(
                mapOf(
                    "status" to "unsupported",
                    "operation" to "trash",
                    "requestedCount" to uris.size,
                    "deletedCount" to 0,
                    "affectedCount" to 0,
                    "requiresRetry" to false,
                ),
            )
            return
        }
        if (Build.VERSION.SDK_INT >= 30) {
            val pendingIntent = if (trash) {
                val trashed = call.argument<Boolean>("trashed") ?: true
                MediaStore.createTrashRequest(resolver, uris, trashed)
            } else {
                MediaStore.createDeleteRequest(resolver, uris)
            }
            consentResult = result
            consentOperation = if (trash) "trash" else "delete"
            consentCount = uris.size
            try {
                activity.startIntentSenderForResult(
                    pendingIntent.intentSender,
                    CONSENT_REQUEST,
                    null,
                    0,
                    0,
                    0,
                )
            } catch (error: Exception) {
                clearConsent()
                result.error("consent_launch_failed", error.message, null)
            }
            return
        }
        legacyDelete(uris, result)
    }

    private fun legacyDelete(uris: List<Uri>, result: MethodChannel.Result) {
        worker.execute {
            var deleted = 0
            for (uri in uris) {
                try {
                    deleted += resolver.delete(uri, null, null).coerceAtLeast(0)
                } catch (error: SecurityException) {
                    if (Build.VERSION.SDK_INT >= 29 && error is RecoverableSecurityException) {
                        launchRecoverableDeleteConsent(error, result, uris.size, deleted)
                    } else {
                        mainHandler.post { result.error("permission_denied", error.message, null) }
                    }
                    return@execute
                } catch (error: Exception) {
                    mainHandler.post { result.error("android_media_error", error.message, null) }
                    return@execute
                }
            }
            mainHandler.post {
                result.success(
                    mapOf(
                        "status" to "completed",
                        "operation" to "delete",
                        "requestedCount" to uris.size,
                        "deletedCount" to deleted,
                        "affectedCount" to deleted,
                        "requiresRetry" to false,
                    ),
                )
            }
        }
    }

    @RequiresApi(29)
    private fun launchRecoverableDeleteConsent(
        recoverable: RecoverableSecurityException,
        result: MethodChannel.Result,
        requestedCount: Int,
        completedBeforeConsent: Int,
    ) {
        mainHandler.post {
            if (consentResult != null) {
                result.error(
                    "media_consent_active",
                    "Another media consent request is in progress",
                    null,
                )
                return@post
            }
            // Android 10 grants access to the current item. The caller retries
            // after approval so no deletion is hidden from it.
            consentDeletedCount = completedBeforeConsent
            consentCount = requestedCount
            consentOperation = "deleteAuthorization"
            consentResult = result
            try {
                activity.startIntentSenderForResult(
                    recoverable.userAction.actionIntent.intentSender,
                    CONSENT_REQUEST,
                    null,
                    0,
                    0,
                    0,
                )
            } catch (error: Exception) {
                clearConsent()
                result.error("consent_launch_failed", error.message, null)
            }
        }
    }

    private fun openMedia(call: MethodCall, result: MethodChannel.Result) {
        val uri = validatedUri(call.argument<String>("uri"))
        val mime = call.argument<String>("mimeType") ?: resolver.getType(uri) ?: "*/*"
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = ClipData.newUri(resolver, "media", uri)
        }
        launchIntent(intent, result)
    }

    private fun shareMedia(call: MethodCall, result: MethodChannel.Result) {
        val uris = parseUris(call)
        if (uris.isEmpty()) {
            result.error("empty_uris", "At least one content URI is required", null)
            return
        }
        val mime = call.argument<String>("mimeType") ?: commonMimeType(uris)
        val intent = Intent(if (uris.size == 1) Intent.ACTION_SEND else Intent.ACTION_SEND_MULTIPLE).apply {
            type = mime
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = ClipData.newUri(resolver, "media", uris.first()).also { clip ->
                uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) }
            }
            if (uris.size == 1) {
                putExtra(Intent.EXTRA_STREAM, uris.first())
            } else {
                putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
            }
        }
        val title = call.argument<String>("chooserTitle") ?: "Share media"
        launchIntent(Intent.createChooser(intent, title), result)
    }

    private fun launchIntent(intent: Intent, result: MethodChannel.Result) {
        try {
            activity.startActivity(intent)
            result.success(mapOf("status" to "launched"))
        } catch (error: ActivityNotFoundException) {
            result.success(mapOf("status" to "unavailable"))
        } catch (error: SecurityException) {
            result.error("intent_permission_denied", error.message, null)
        }
    }

    private fun storageStats(): Map<String, Any?> {
        val data = statForPath(Environment.getDataDirectory().absolutePath)
        val shared = statForPath(Environment.getExternalStorageDirectory().absolutePath)
        return mapOf(
            "data" to data,
            "shared" to shared,
            "sharedState" to Environment.getExternalStorageState(),
            "sdkInt" to Build.VERSION.SDK_INT,
        )
    }

    private fun pickDirectory(result: MethodChannel.Result) {
        if (hasPendingSystemRequest()) {
            result.error("system_request_active", "Another Android system request is in progress", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
        }
        directoryPickerResult = result
        try {
            activity.startActivityForResult(intent, DIRECTORY_PICKER_REQUEST)
        } catch (error: ActivityNotFoundException) {
            directoryPickerResult = null
            result.success(mapOf("status" to "unavailable"))
        } catch (error: Exception) {
            directoryPickerResult = null
            throw error
        }
    }

    private fun persistDirectoryGrant(uri: Uri, canRead: Boolean, canWrite: Boolean): Boolean {
        return persistUriGrant(uri, canRead, canWrite)
    }

    private fun persistUriGrant(uri: Uri, read: Boolean, write: Boolean): Boolean {
        val flags =
            (if (read) Intent.FLAG_GRANT_READ_URI_PERMISSION else 0) or
                (if (write) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)
        if (flags == 0) return false
        return try {
            resolver.takePersistableUriPermission(uri, flags)
            true
        } catch (_: SecurityException) {
            // Some document providers grant session access but do not support
            // persisted grants. Surface that state to Flutter.
            false
        } catch (_: IllegalArgumentException) {
            false
        }
    }

    private fun pickDocument(result: MethodChannel.Result) {
        if (hasPendingSystemRequest()) {
            result.error("system_request_active", "Another Android system request is in progress", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
        }
        documentPickerResult = result
        try {
            activity.startActivityForResult(intent, DOCUMENT_PICKER_REQUEST)
        } catch (error: ActivityNotFoundException) {
            documentPickerResult = null
            result.success(mapOf("status" to "unavailable"))
        } catch (error: Exception) {
            documentPickerResult = null
            throw error
        }
    }

    private fun documentDescriptor(
        uri: Uri,
        status: String,
        persisted: Boolean,
    ): Map<String, Any?> {
        val metadata = documentMetadata(uri)
        return mapOf(
            "status" to status,
            "uri" to uri.toString(),
            "name" to metadata.name,
            "mimeType" to metadata.mimeType,
            "size" to metadata.size,
            "persisted" to persisted,
        )
    }

    private fun documentMetadata(uri: Uri): DocumentMetadata {
        var name: String? = null
        var size: Long? = null
        resolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                name = cursor.string(OpenableColumns.DISPLAY_NAME)
                size = cursor.long(OpenableColumns.SIZE)
            }
        }
        return DocumentMetadata(
            name = name,
            mimeType = resolver.getType(uri),
            size = size,
        )
    }

    private fun copyDocumentToAppCache(call: MethodCall): Map<String, Any?> {
        val uri = validatedUri(call.argument<String>("uri"))
        val metadata = documentMetadata(uri)
        val safeName = sanitizedFileName(metadata.name ?: "document")
        val directory = File(activity.cacheDir, IMPORT_CACHE_DIRECTORY)
        if (!directory.exists() && !directory.mkdirs()) {
            throw BridgeException("cache_unavailable", "Android could not create the transfer cache")
        }
        val target = reserveCacheFile(directory, safeName)
        try {
            val copied = resolver.openInputStream(uri)?.use { input ->
                FileOutputStream(target, false).use { output -> input.copyTo(output, COPY_BUFFER_SIZE) }
            } ?: throw FileNotFoundException("Could not open $uri")
            return mapOf(
                "path" to target.absolutePath,
                "size" to copied,
                "name" to target.name,
                "mimeType" to (metadata.mimeType ?: "application/octet-stream"),
            )
        } catch (error: Exception) {
            target.delete()
            throw error
        }
    }

    private fun reserveCacheFile(directory: File, name: String): File = synchronized(cacheFileLock) {
        val dot = name.lastIndexOf('.').takeIf { it > 0 } ?: name.length
        val stem = name.substring(0, dot)
        val extension = name.substring(dot)
        for (index in 0..MAX_CACHE_NAME_ATTEMPTS) {
            val suffix = if (index == 0) "" else " ($index)"
            val maxStemLength = (MAX_CACHE_FILE_NAME_CHARS - extension.length - suffix.length)
                .coerceAtLeast(1)
            val candidateName = stem.take(maxStemLength) + suffix + extension
            val candidate = File(directory, candidateName)
            if (candidate.createNewFile()) return@synchronized candidate
        }
        throw BridgeException("cache_name_exhausted", "Android could not reserve a transfer filename")
    }

    private fun sanitizedFileName(value: String): String {
        val cleaned = value
            .replace(UNSAFE_FILE_NAME_CHARACTERS, "_")
            .trim()
            .trim('.')
        return (cleaned.ifEmpty { "document" }).take(MAX_CACHE_FILE_NAME_CHARS)
    }

    private fun openAppFile(call: MethodCall, result: MethodChannel.Result) {
        val (file, uri, mimeType) = appFileIntentData(call)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = ClipData.newUri(resolver, file.name, uri)
        }
        launchIntent(intent, result)
    }

    private fun shareAppFile(call: MethodCall, result: MethodChannel.Result) {
        val (file, uri, mimeType) = appFileIntentData(call)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = ClipData.newUri(resolver, file.name, uri)
            putExtra(Intent.EXTRA_STREAM, uri)
        }
        val title = call.argument<String>("chooserTitle") ?: "Share file"
        launchIntent(Intent.createChooser(intent, title), result)
    }

    private fun appFileIntentData(call: MethodCall): AppFileIntentData {
        val file = validatedAppFile(call.argument<String>("path"))
        val uri = FileProvider.getUriForFile(
            activity,
            "${activity.packageName}.fileprovider",
            file,
        )
        val requestedMime = call.argument<String>("mimeType")
        if (requestedMime != null && !MIME_TYPE_PATTERN.matches(requestedMime)) {
            throw BridgeException("invalid_mime_type", "mimeType is invalid")
        }
        return AppFileIntentData(
            file,
            uri,
            requestedMime ?: resolver.getType(uri) ?: "application/octet-stream",
        )
    }

    private fun validatedAppFile(value: String?): File {
        if (value.isNullOrBlank()) {
            throw BridgeException("invalid_path", "An app-private file path is required")
        }
        val file = File(value).canonicalFile
        val roots = listOf(activity.filesDir.canonicalFile, activity.cacheDir.canonicalFile)
        val insideAppStorage = roots.any { root ->
            file.path.startsWith(root.path + File.separator)
        }
        if (!insideAppStorage) {
            throw BridgeException("path_not_allowed", "Only app-private files can be opened or shared")
        }
        if (!file.isFile) {
            throw FileNotFoundException("App-private file does not exist")
        }
        return file
    }

    private fun persistedDirectories(): List<Map<String, Any?>> =
        resolver.persistedUriPermissions.filter { DocumentsContract.isTreeUri(it.uri) }.map { permission ->
            directoryDescriptor(permission.uri, "persisted", persisted = true) +
                mapOf(
                    "canRead" to permission.isReadPermission,
                    "canWrite" to permission.isWritePermission,
                )
        }

    private fun directoryDescriptor(
        uri: Uri,
        status: String,
        persisted: Boolean,
        grantedRead: Boolean = false,
        grantedWrite: Boolean = false,
    ): Map<String, Any?> {
        val persistedPermission = resolver.persistedUriPermissions.firstOrNull { it.uri == uri }
        return mapOf(
            "status" to status,
            "uri" to uri.toString(),
            "name" to documentDisplayName(documentUri(uri)),
            "persisted" to persisted,
            "canRead" to (persistedPermission?.isReadPermission ?: grantedRead),
            "canWrite" to (persistedPermission?.isWritePermission ?: grantedWrite),
        )
    }

    private fun listDirectory(call: MethodCall): Map<String, Any?> {
        val treeUri = validatedTreeUri(call.argument<String>("uri"))
        val limit = (call.argument<Number>("limit")?.toInt() ?: 100).coerceIn(1, MAX_PAGE_SIZE)
        val offset = (call.argument<Number>("offset")?.toInt() ?: 0).coerceAtLeast(0)
        val parentId = documentId(treeUri)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
        val items = ArrayList<Map<String, Any?>>(limit + 1)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_FLAGS,
        )
        resolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            if (offset > 0 && !cursor.moveToPosition(offset - 1)) return@use
            while (cursor.moveToNext() && items.size < limit + 1) {
                val childId = cursor.string(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                    ?: continue
                val mimeType = cursor.string(DocumentsContract.Document.COLUMN_MIME_TYPE)
                val flags = cursor.long(DocumentsContract.Document.COLUMN_FLAGS)?.toInt() ?: 0
                items += mapOf(
                    "uri" to DocumentsContract
                        .buildDocumentUriUsingTree(treeUri, childId)
                        .toString(),
                    "name" to cursor.string(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                    "mimeType" to mimeType,
                    "isDirectory" to (mimeType == DocumentsContract.Document.MIME_TYPE_DIR),
                    "size" to cursor.long(DocumentsContract.Document.COLUMN_SIZE),
                    "lastModified" to cursor.long(DocumentsContract.Document.COLUMN_LAST_MODIFIED),
                    "flags" to flags,
                    "canWrite" to flags.hasDocumentFlag(DocumentsContract.Document.FLAG_SUPPORTS_WRITE),
                    "canDelete" to flags.hasDocumentFlag(DocumentsContract.Document.FLAG_SUPPORTS_DELETE),
                    "canRename" to flags.hasDocumentFlag(DocumentsContract.Document.FLAG_SUPPORTS_RENAME),
                    "canCreate" to flags.hasDocumentFlag(DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE),
                    "hasThumbnail" to flags.hasDocumentFlag(DocumentsContract.Document.FLAG_SUPPORTS_THUMBNAIL),
                )
            }
        } ?: throw BridgeException("directory_query_failed", "Document provider returned no cursor")
        val hasMore = items.size > limit
        if (hasMore) items.removeAt(items.lastIndex)
        return mapOf(
            "items" to items,
            "uri" to treeUri.toString(),
            "offset" to offset,
            "limit" to limit,
            "hasMore" to hasMore,
            "nextOffset" to if (hasMore) offset + items.size else null,
        )
    }

    private fun createDirectory(call: MethodCall): Map<String, Any?> {
        val parent = validatedTreeUri(call.argument<String>("parentUri"))
        val name = validatedDocumentName(call.argument<String>("name"))
        val created = DocumentsContract.createDocument(
            resolver,
            documentUri(parent),
            DocumentsContract.Document.MIME_TYPE_DIR,
            name,
        ) ?: return mapOf("status" to "unsupported", "uri" to null)
        return mapOf(
            "status" to "completed",
            "uri" to created.toString(),
            "name" to (documentDisplayName(created) ?: name),
        )
    }

    private fun renameDocument(call: MethodCall): Map<String, Any?> {
        val uri = validatedTreeUri(call.argument<String>("uri"))
        val name = validatedDocumentName(call.argument<String>("name"))
        val renamed = DocumentsContract.renameDocument(resolver, documentUri(uri), name)
            ?: return mapOf("status" to "unsupported", "uri" to uri.toString())
        return mapOf(
            "status" to "completed",
            "uri" to renamed.toString(),
            "name" to (documentDisplayName(renamed) ?: name),
        )
    }

    private fun deleteDocument(call: MethodCall): Map<String, Any?> {
        val uri = validatedTreeUri(call.argument<String>("uri"))
        val deleted = DocumentsContract.deleteDocument(resolver, documentUri(uri))
        return mapOf(
            "status" to if (deleted) "completed" else "failed",
            "uri" to uri.toString(),
        )
    }

    private fun exportAppMedia(call: MethodCall): Map<String, Any?> {
        val file = validatedAppFile(call.argument<String>("path"))
        val name = validatedDocumentName(call.argument<String>("name"))
        val mime = call.argument<String>("mimeType") ?: "image/png"
        if (mime != "image/png" && mime != "video/mp4") throw BridgeException("invalid_mime", "Only image and video exports are supported")
        val video = mime == "video/mp4"
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.MediaColumns.RELATIVE_PATH, if (video) "Movies/nexGallery" else "Pictures/nexGallery")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            } else {
                val dir = File(Environment.getExternalStoragePublicDirectory(if (video) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES), "nexGallery")
                if (!dir.exists() && !dir.mkdirs()) throw BridgeException("export_failed", "Could not create the export folder")
                val target = File(dir, name)
                if (target.exists()) throw BridgeException("destination_exists", "Export destination exists")
                @Suppress("DEPRECATION")
                put(MediaStore.MediaColumns.DATA, target.absolutePath)
            }
        }
        val collection = if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val uri = resolver.insert(collection, values) ?: throw BridgeException("export_failed", "Android could not create an exported copy")
        try {
            resolver.openOutputStream(uri, "w")?.use { output -> file.inputStream().use { it.copyTo(output) } }
                ?: throw BridgeException("export_failed", "Android could not write the copy")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
            }
        } catch (error: Exception) { resolver.delete(uri, null, null); throw error }
        return mapOf("status" to "completed", "uri" to uri.toString())
    }

    private fun exportAppFile(call: MethodCall): Map<String, Any?> {
        val file = validatedAppFile(call.argument<String>("path"))
        val parent = validatedTreeUri(call.argument<String>("parentUri"))
        val name = validatedDocumentName(call.argument<String>("name"))
        val mime = call.argument<String>("mimeType") ?: "application/octet-stream"
        ensureNoChild(parent, name)
        val uri = DocumentsContract.createDocument(resolver, documentUri(parent), mime, name)
            ?: throw BridgeException("export_failed", "This provider cannot create files")
        try {
            resolver.openOutputStream(uri, "w")?.use { output -> file.inputStream().use { it.copyTo(output) } }
                ?: throw BridgeException("export_failed", "The provider could not write this file")
        } catch (error: Exception) { DocumentsContract.deleteDocument(resolver, uri); throw error }
        return mapOf("status" to "completed", "uri" to uri.toString(), "name" to name)
    }

    private fun ensureNoChild(parent: Uri, name: String) {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(parent, documentId(parent))
        resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                if (cursor.getString(0).equals(name, ignoreCase = true)) throw BridgeException("destination_exists", "An item with this name already exists")
            }
        } ?: throw BridgeException("provider_unavailable", "Could not check the destination folder")
    }

    private fun copyDocument(call: MethodCall): Map<String, Any?> {
        val source = validatedTreeUri(call.argument<String>("uri"))
        val parent = validatedTreeUri(call.argument<String>("parentUri"))
        SafArchives(resolver).rejectDescendant(source, parent)
        var count = 0
        fun copyOne(input: Uri, destination: Uri, depth: Int): Uri {
            if (++count > 100000 || depth > 64) throw BridgeException("copy_limit", "The folder is too large or too deep")
            val name = validatedDocumentName(documentDisplayName(documentUri(input)))
            val mime = resolver.getType(documentUri(input)) ?: "application/octet-stream"
            ensureNoChild(destination, name)
            val rawCreated = DocumentsContract.createDocument(resolver, documentUri(destination), mime, name)
                ?: throw BridgeException("copy_failed", "The provider could not create the copy")
            val created = DocumentsContract.buildDocumentUriUsingTree(destination, documentId(rawCreated))
            try {
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    val children = DocumentsContract.buildChildDocumentsUriUsingTree(input, documentId(input))
                    resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null)?.use { cursor ->
                        while (cursor.moveToNext()) { copyOne(DocumentsContract.buildDocumentUriUsingTree(input, cursor.getString(0)), created, depth + 1) }
                    } ?: throw BridgeException("copy_failed", "Could not read the source folder")
                } else {
                    resolver.openInputStream(documentUri(input))?.use { stream ->
                        resolver.openOutputStream(created, "w")?.use { output -> stream.copyTo(output) }
                            ?: throw BridgeException("copy_failed", "Could not write the copy")
                    } ?: throw BridgeException("copy_failed", "Could not read the source file")
                }
                return created
            } catch (error: Exception) { DocumentsContract.deleteDocument(resolver, created); throw error }
        }
        val copied = copyOne(source, parent, 0)
        if (call.argument<Boolean>("move") == true && !DocumentsContract.deleteDocument(resolver, documentUri(source))) {
            throw BridgeException("move_partial", "The copy was saved, but the provider could not delete the original")
        }
        return mapOf("status" to "completed", "uri" to copied.toString(), "name" to documentDisplayName(copied))
    }

    private fun documentDisplayName(uri: Uri): String? =
        resolver.query(
            uri,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                cursor.string(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            } else {
                null
            }
        }

    private fun validatedTreeUri(value: String?): Uri {
        val uri = validatedUri(value)
        if (!DocumentsContract.isTreeUri(uri)) {
            throw BridgeException("invalid_tree_uri", "A Storage Access Framework tree URI is required")
        }
        return uri
    }

    private fun documentUri(treeUri: Uri): Uri =
        DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId(treeUri))

    private fun documentId(treeUri: Uri): String = try {
        DocumentsContract.getDocumentId(treeUri)
    } catch (_: IllegalArgumentException) {
        DocumentsContract.getTreeDocumentId(treeUri)
    }

    private fun validatedDocumentName(value: String?): String {
        val name = value?.trim().orEmpty()
        if (name.isEmpty() || name.length > 255 || '/' in name || '\u0000' in name) {
            throw BridgeException("invalid_name", "Document name must be 1..255 characters without slashes")
        }
        return name
    }

    private fun Int.hasDocumentFlag(flag: Int): Boolean = this and flag != 0

    private fun storeSecret(call: MethodCall): Map<String, Any> {
        val key = validatedSecretKey(call.argument<String>("key"))
        val value = call.argument<String>("value")
            ?: throw BridgeException("invalid_secret", "Secret value is required")
        if (value.toByteArray(StandardCharsets.UTF_8).size > MAX_SECRET_BYTES) {
            throw BridgeException("secret_too_large", "Secret must not exceed $MAX_SECRET_BYTES bytes")
        }
        synchronized(secretLock) {
            val cipher = Cipher.getInstance(SECRET_TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, getOrCreateSecretKey())
            val encrypted = cipher.doFinal(value.toByteArray(StandardCharsets.UTF_8))
            val iv = cipher.iv
            val payload = ByteBuffer.allocate(2 + iv.size + encrypted.size)
                .put(SECRET_FORMAT_VERSION)
                .put(iv.size.toByte())
                .put(iv)
                .put(encrypted)
                .array()
            val encoded = Base64.encodeToString(payload, Base64.NO_WRAP)
            if (!secretPreferences().edit().putString(key, encoded).commit()) {
                throw BridgeException("secret_store_failed", "Android could not persist the encrypted secret")
            }
        }
        return mapOf("status" to "stored")
    }

    private fun readSecret(call: MethodCall): Map<String, Any?> {
        val key = validatedSecretKey(call.argument<String>("key"))
        return synchronized(secretLock) {
            val encoded = secretPreferences().getString(key, null)
                ?: return@synchronized mapOf("found" to false, "value" to null)
            try {
                val payload = Base64.decode(encoded, Base64.NO_WRAP)
                if (payload.size < MIN_SECRET_PAYLOAD_BYTES || payload[0] != SECRET_FORMAT_VERSION) {
                    throw BridgeException("secret_corrupt", "Encrypted secret has an invalid format")
                }
                val ivSize = payload[1].toInt() and 0xff
                if (ivSize !in 12..16 || payload.size <= 2 + ivSize) {
                    throw BridgeException("secret_corrupt", "Encrypted secret has an invalid IV")
                }
                val iv = payload.copyOfRange(2, 2 + ivSize)
                val encrypted = payload.copyOfRange(2 + ivSize, payload.size)
                val cipher = Cipher.getInstance(SECRET_TRANSFORMATION)
                cipher.init(
                    Cipher.DECRYPT_MODE,
                    getOrCreateSecretKey(),
                    GCMParameterSpec(GCM_TAG_BITS, iv),
                )
                val plaintext = cipher.doFinal(encrypted)
                mapOf(
                    "found" to true,
                    "value" to String(plaintext, StandardCharsets.UTF_8),
                )
            } catch (error: BridgeException) {
                throw error
            } catch (_: Exception) {
                throw BridgeException("secret_decrypt_failed", "Encrypted secret could not be decrypted")
            }
        }
    }

    private fun deleteSecret(call: MethodCall): Map<String, Any> {
        val key = validatedSecretKey(call.argument<String>("key"))
        return synchronized(secretLock) {
            val existed = secretPreferences().contains(key)
            if (existed && !secretPreferences().edit().remove(key).commit()) {
                throw BridgeException("secret_delete_failed", "Android could not delete the encrypted secret")
            }
            mapOf("deleted" to existed)
        }
    }

    private fun getOrCreateSecretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(SECRET_KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val specification = KeyGenParameterSpec.Builder(
            SECRET_KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build()
        generator.init(specification)
        return generator.generateKey()
    }

    private fun secretPreferences() =
        activity.getSharedPreferences(SECRET_PREFERENCES, Activity.MODE_PRIVATE)

    private fun validatedSecretKey(value: String?): String {
        val key = value.orEmpty()
        if (!SECRET_NAME_PATTERN.matches(key)) {
            throw BridgeException(
                "invalid_secret_key",
                "Secret key must contain 1..128 letters, numbers, dots, dashes, or underscores",
            )
        }
        return key
    }

    private fun statForPath(path: String): Map<String, Any> {
        val stat = StatFs(path)
        val total = stat.totalBytes
        val available = stat.availableBytes
        return mapOf(
            "totalBytes" to total,
            "availableBytes" to available,
            "usedBytes" to (total - available).coerceAtLeast(0L),
        )
    }

    private fun openAppSettings(result: MethodChannel.Result) {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", activity.packageName, null),
        )
        launchIntent(intent, result)
    }

    private fun sortColumn(kind: MediaKind, sortBy: String): String = when (sortBy) {
        "dateAdded" -> MediaStore.MediaColumns.DATE_ADDED
        "dateModified" -> MediaStore.MediaColumns.DATE_MODIFIED
        "dateTaken" -> if (kind == MediaKind.AUDIO) {
            throw BridgeException("invalid_sort", "dateTaken is unavailable for audio")
        } else {
            MediaStore.Images.ImageColumns.DATE_TAKEN
        }
        "displayName" -> MediaStore.MediaColumns.DISPLAY_NAME
        "size" -> MediaStore.MediaColumns.SIZE
        "duration" -> if (kind == MediaKind.IMAGE) {
            throw BridgeException("invalid_sort", "duration is unavailable for images")
        } else {
            MediaStore.MediaColumns.DURATION
        }
        else -> throw BridgeException("invalid_sort", "Unsupported sortBy value")
    }

    private fun collectionUri(kind: MediaKind): Uri = when (kind) {
        MediaKind.IMAGE -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        MediaKind.VIDEO -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        MediaKind.AUDIO -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
    }

    private fun parseKinds(call: MethodCall): Set<MediaKind> {
        val names = call.argument<List<*>>("mediaTypes")?.filterIsInstance<String>().orEmpty()
        if (names.isEmpty()) return MediaKind.entries.toSet()
        return names.map { name ->
            MediaKind.fromWire(name)
                ?: throw BridgeException("invalid_media_type", "Unknown media type: $name")
        }.toSet()
    }

    private fun parseUris(call: MethodCall): List<Uri> =
        call.argument<List<*>>("uris")
            ?.filterIsInstance<String>()
            ?.map(::validatedUri)
            ?.distinct()
            .orEmpty()

    private fun validatedUri(value: String?): Uri {
        if (value.isNullOrBlank()) throw BridgeException("invalid_uri", "A content URI is required")
        val uri = Uri.parse(value)
        if (uri.scheme != "content") {
            throw BridgeException("invalid_uri", "Only content:// URIs are accepted")
        }
        return uri
    }

    private fun commonMimeType(uris: List<Uri>): String {
        val types = uris.mapNotNull(resolver::getType)
        if (types.isEmpty()) return "*/*"
        if (types.distinct().size == 1) return types.first()
        val groups = types.map { it.substringBefore('/') }.distinct()
        return if (groups.size == 1) "${groups.first()}/*" else "*/*"
    }

    private fun isGranted(permission: String): Boolean =
        activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun clearConsent() {
        consentResult = null
        consentOperation = null
        consentCount = 0
        consentDeletedCount = 0
    }

    private fun hasPendingSystemRequest(): Boolean =
        permissionResult != null ||
            consentResult != null ||
            directoryPickerResult != null ||
            documentPickerResult != null

    private fun runAsync(result: MethodChannel.Result, operation: () -> Any?) {
        worker.execute {
            try {
                val value = operation()
                mainHandler.post { result.success(value) }
            } catch (error: BridgeException) {
                mainHandler.post { result.error(error.code, error.message, null) }
            } catch (error: SecurityException) {
                mainHandler.post {
                    result.error(
                        "permission_denied",
                        error.message ?: "Android denied access to this media",
                        null,
                    )
                }
            } catch (error: FileNotFoundException) {
                mainHandler.post { result.error("media_not_found", error.message, null) }
            } catch (error: Exception) {
                mainHandler.post { result.error("android_media_error", error.message, null) }
            }
        }
    }

    private fun android.database.Cursor.string(column: String): String? {
        val index = getColumnIndex(column)
        return if (index >= 0 && !isNull(index)) getString(index) else null
    }

    private fun android.database.Cursor.long(column: String): Long? {
        val index = getColumnIndex(column)
        return if (index >= 0 && !isNull(index)) getLong(index) else null
    }

    private enum class MediaKind(val wireName: String) {
        IMAGE("image"),
        VIDEO("video"),
        AUDIO("audio");

        companion object {
            fun fromWire(value: String?): MediaKind? = entries.firstOrNull { it.wireName == value }
        }
    }

    private data class DocumentMetadata(
        val name: String?,
        val mimeType: String?,
        val size: Long?,
    )

    private data class AppFileIntentData(
        val file: File,
        val uri: Uri,
        val mimeType: String,
    )

    private class BridgeException(val code: String, override val message: String) : Exception(message)

    companion object {
        const val CHANNEL_NAME = "com.thenex.nex_gallery/media"
        private const val PERMISSION_REQUEST = 7401
        private const val CONSENT_REQUEST = 7402
        private const val DIRECTORY_PICKER_REQUEST = 7403
        private const val DOCUMENT_PICKER_REQUEST = 7404
        private const val MAX_PAGE_SIZE = 500
        private const val MAX_THUMBNAIL_SIZE = 1024
        private const val COPY_BUFFER_SIZE = 64 * 1024
        private const val MAX_CACHE_FILE_NAME_CHARS = 128
        private const val MAX_CACHE_NAME_ATTEMPTS = 999
        private const val IMPORT_CACHE_DIRECTORY = "incoming_transfers"
        private const val MAX_SECRET_BYTES = 16 * 1024
        private const val MIN_SECRET_PAYLOAD_BYTES = 2 + 12 + 16
        private const val GCM_TAG_BITS = 128
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val SECRET_KEY_ALIAS = "nexGallery.localSecrets.v1"
        private const val SECRET_PREFERENCES = "nexgallery_secure_secrets"
        private const val SECRET_TRANSFORMATION = "AES/GCM/NoPadding"
        private const val SECRET_FORMAT_VERSION: Byte = 1
        private val SECRET_NAME_PATTERN = Regex("^[A-Za-z0-9._-]{1,128}$")
        private val MIME_TYPE_PATTERN = Regex("^[A-Za-z0-9.+*-]+/[A-Za-z0-9.+*-]+$")
        private val UNSAFE_FILE_NAME_CHARACTERS = Regex("[\\\\/\\u0000-\\u001F\\u007F]")
    }
}
