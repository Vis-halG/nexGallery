import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../data/android_media/android_media_bridge.dart';
import '../../data/windows_files/windows_files_bridge.dart';
import '../../services/files/file_tools.dart';

/// Lets the user choose a file to import. Android copies the chosen document
/// into app cache; the caller deletes the returned file after reading it.
Future<File?> pickImportFile({String description = 'nexGallery backup'}) async {
  if (Platform.isAndroid) {
    final bridge = AndroidMediaBridge.instance;
    final picked = await bridge.pickDocument();
    final uri = picked.uri;
    if (picked.status != 'selected' || uri == null) return null;
    final cached = await bridge.copyDocumentToAppCache(uri);
    return File(cached.path);
  }
  if (Platform.isWindows) {
    final escaped = description.replaceAll("'", "''");
    final result = await Process.run('powershell.exe', [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-STA',
      '-Command',
      '[Console]::OutputEncoding = [Text.Encoding]::UTF8; '
          'Add-Type -AssemblyName System.Windows.Forms; '
          r'$d = New-Object System.Windows.Forms.OpenFileDialog; '
          "\$d.Filter = '$escaped|*.*'; "
          r"if ($d.ShowDialog() -eq 'OK') { [Console]::Out.Write($d.FileName) }",
    ], stdoutEncoding: utf8);
    final path = (result.stdout as String).trim();
    return result.exitCode == 0 && path.isNotEmpty ? File(path) : null;
  }
  throw UnsupportedError(
    'Importing files is available on Android and Windows.',
  );
}

/// Saves a copy of [source] where the user chooses. Returns a description of
/// the destination, or null when the user cancelled.
Future<String?> exportToUserFolder(
  File source,
  String name, {
  String mimeType = 'application/octet-stream',
}) async {
  final safe = safeName(name);
  if (Platform.isAndroid) {
    final bridge = AndroidMediaBridge.instance;
    final folder = await bridge.pickDirectory();
    final uri = folder.uri;
    if (uri == null) return null;
    await bridge.exportAppFile(
      source.path,
      uri,
      name: safe,
      mimeType: mimeType,
    );
    return safe;
  }
  if (Platform.isWindows) {
    final folder = await const WindowsFilesBridge().chooseFolder();
    if (folder == null) return null;
    var target = p.join(folder, safe);
    for (var copy = 2; await File(target).exists(); copy++) {
      target = p.join(
        folder,
        '${p.basenameWithoutExtension(safe)} ($copy)${p.extension(safe)}',
      );
    }
    await FileTools().copy(source.path, target);
    return target;
  }
  throw UnsupportedError(
    'Exporting files is available on Android and Windows.',
  );
}
