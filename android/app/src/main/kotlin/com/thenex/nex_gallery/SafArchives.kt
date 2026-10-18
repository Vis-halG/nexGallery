package com.thenex.nex_gallery

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodCall
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/** SAF ZIP operations use new destinations, bounded streams and rollback on failure. */
class SafArchives(private val resolver: ContentResolver) {
    private val limitBytes = 20L * 1024 * 1024 * 1024
    private fun tree(value: String?): Uri {
        val uri = Uri.parse(requireNotNull(value))
        require(uri.scheme == "content" && DocumentsContract.isTreeUri(uri)) { "A chosen folder URI is required" }
        return doc(uri)
    }
    private fun id(uri: Uri): String = try { DocumentsContract.getDocumentId(uri) } catch (_: IllegalArgumentException) { DocumentsContract.getTreeDocumentId(uri) }
    private fun doc(uri: Uri) = DocumentsContract.buildDocumentUriUsingTree(uri, id(uri))
    private fun name(value: String): String {
        require(value.isNotBlank() && value.length <= 255 && value != "." && value != ".." && value.none { it in "/\\:\u0000" || it.code < 32 }) { "Unsafe archive name" }
        return value
    }
    private fun children(uri: Uri): List<Pair<Uri,String>> {
        val result = mutableListOf<Pair<Uri,String>>()
        resolver.query(DocumentsContract.buildChildDocumentsUriUsingTree(uri, id(uri)), arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { c ->
            while (c.moveToNext()) { require(result.size < 100000) { "Folder has too many items" }; result.add(DocumentsContract.buildDocumentUriUsingTree(uri, c.getString(0)) to c.getString(1)) }
        } ?: error("Could not read folder")
        return result
    }
    private fun displayName(uri: Uri): String = resolver.query(doc(uri), arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { c -> if (c.moveToFirst()) c.getString(0) else null } ?: error("Could not read item name")
    private fun create(parent: Uri, mime: String, value: String): Uri {
        val safe = name(value)
        require(children(parent).none { it.second.equals(safe, ignoreCase = true) }) { "Destination name already exists" }
        val result = DocumentsContract.createDocument(resolver, doc(parent), mime, safe) ?: error("Could not create destination")
        return DocumentsContract.buildDocumentUriUsingTree(parent, id(result))
    }
    fun rejectDescendant(source: Uri, parent: Uri) {
        if (source.authority != parent.authority) return
        val seen = mutableSetOf<String>()
        fun visit(uri: Uri, depth: Int) {
            require(depth <= 64 && seen.size < 100000 && seen.add(id(uri))) { "Source folder is too large or cyclic" }
            require(id(uri) != id(parent)) { "Choose a destination outside the source" }
            if (resolver.getType(doc(uri)) == DocumentsContract.Document.MIME_TYPE_DIR) children(uri).forEach { visit(it.first, depth+1) }
        }
        visit(doc(source), 0)
    }
    fun zip(call: MethodCall): Map<String, Any> {
        val source = tree(call.argument("uri"))
        val parent = tree(call.argument("parentUri"))
        rejectDescendant(source, parent)
        val archiveName = name(requireNotNull(call.argument<String>("name")))
        val target = create(parent, "application/zip", archiveName)
        var count = 0
        var bytes = 0L
        val seen = mutableSetOf<String>()
        try {
            ZipOutputStream(resolver.openOutputStream(target, "w") ?: error("Could not write ZIP")).use { output ->
                fun add(uri: Uri, path: String, depth: Int) {
                    require(++count <= 100000 && depth <= 64 && seen.add(id(uri))) { "Source folder is too large or cyclic" }
                    val directory = resolver.getType(doc(uri)) == DocumentsContract.Document.MIME_TYPE_DIR
                    output.putNextEntry(ZipEntry(path + if (directory) "/" else ""))
                    if (!directory) resolver.openInputStream(doc(uri))?.use { input ->
                        val buffer = ByteArray(65536)
                        while (true) { val n = input.read(buffer); if (n < 0) break; bytes += n; require(bytes <= limitBytes) { "ZIP exceeds 20 GB limit" }; output.write(buffer, 0, n) }
                    } ?: error("Could not read original")
                    output.closeEntry()
                    if (directory) children(uri).forEach { add(it.first, "$path/${name(it.second)}", depth+1) }
                }
                add(source, name(displayName(source)), 0)
            }
            return mapOf("status" to "completed", "uri" to target.toString(), "name" to archiveName)
        } catch (error: Exception) { DocumentsContract.deleteDocument(resolver, target); throw error }
    }
    fun extract(call: MethodCall): Map<String, Any> {
        val source = tree(call.argument("uri"))
        val parent = tree(call.argument("parentUri"))
        val folderName = name(requireNotNull(call.argument<String>("name")))
        val target = create(parent, DocumentsContract.Document.MIME_TYPE_DIR, folderName)
        val directories = mutableMapOf("" to target)
        val seen = mutableSetOf<String>()
        var count = 0
        var bytes = 0L
        try {
            ZipInputStream(resolver.openInputStream(source) ?: error("Could not read ZIP")).use { input ->
                while (true) {
                    val entry = input.nextEntry ?: break
                    require(++count <= 100000) { "ZIP has too many entries" }
                    val path = entry.name.replace('\\','/').trimEnd('/')
                    require(!entry.name.startsWith('/') && path.isNotEmpty() && seen.add(path.lowercase())) { "Unsafe or repeated ZIP path" }
                    val parts = path.split('/').map { name(it) }
                    require(parts.size <= 64) { "ZIP path is too deep" }
                    var current = target
                    var prefix = ""
                    parts.dropLast(if (entry.isDirectory) 0 else 1).forEach { part ->
                        prefix = if (prefix.isEmpty()) part else "$prefix/$part"
                        current = directories.getOrPut(prefix) { create(current, DocumentsContract.Document.MIME_TYPE_DIR, part) }
                    }
                    if (!entry.isDirectory) {
                        val file = create(current, "application/octet-stream", parts.last())
                        resolver.openOutputStream(file, "w")?.use { output ->
                            val buffer = ByteArray(65536)
                            while (true) { val n = input.read(buffer); if (n < 0) break; bytes += n; require(bytes <= limitBytes) { "ZIP exceeds 20 GB extraction limit" }; output.write(buffer,0,n) }
                        } ?: error("Could not write extracted file")
                    }
                    input.closeEntry()
                }
                require(count > 0) { "ZIP contains no entries" }
            }
            return mapOf("status" to "completed", "uri" to target.toString(), "name" to folderName)
        } catch (error: Exception) { DocumentsContract.deleteDocument(resolver, target); throw error }
    }
}
