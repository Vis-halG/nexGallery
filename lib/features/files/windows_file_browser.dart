import '../../l10n/app_strings.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../data/windows_files/windows_files_bridge.dart';
import '../../services/files/file_tools.dart';
import '../../src/gallery_model.dart';

class WindowsFileBrowser extends StatefulWidget {
  const WindowsFileBrowser({required this.model, super.key});
  final GalleryModel model;
  @override
  State<WindowsFileBrowser> createState() => _WindowsFileBrowserState();
}

class _WindowsFileBrowserState extends State<WindowsFileBrowser> {
  String? _root, _path, _error;
  List<FileSystemEntity> _entries = [];
  bool _busy = false;
  final _files = FileTools();
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _choose() => _run(() async {
    final selected = await const WindowsFilesBridge().chooseFolder();
    if (selected == null) return;
    if (await FileSystemEntity.type(selected, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FileSystemException('Select a regular folder.');
    }
    _root = _path = await Directory(selected).resolveSymbolicLinks();
    await _load();
  });
  Future<void> _load() async {
    final path = _path;
    if (path == null) return;
    final entries = await Directory(path)
        .list(followLinks: false)
        .where((v) => !p.basename(v.path).startsWith('.nexgallery-'))
        .toList();
    entries.sort((a, b) {
      if ((a is Directory) != (b is Directory)) return a is Directory ? -1 : 1;
      return p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase());
    });
    if (mounted) setState(() => _entries = entries);
  }

  Future<String?> _name(String title, String initial) async {
    final text = TextEditingController(text: initial);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: text, autofocus: true, maxLength: 200),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const AppText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, text.text),
            child: const AppText('Save'),
          ),
        ],
      ),
    );
    text.dispose();
    return name == null ? null : safeName(name);
  }

  Future<void> _action(FileSystemEntity entry, String action) => _run(() async {
    final source = entry.path;
    if (await FileSystemEntity.type(source, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException(
        'Linked files are not supported by these operations.',
      );
    }
    if (action == 'open') {
      final result = await Process.run('explorer.exe', [source]);
      if (result.exitCode != 0) {
        throw StateError('Windows could not open this file.');
      }
      return;
    }
    if (action == 'rename') {
      final name = await _name('Rename', p.basename(source));
      if (name == null) return;
      final target = p.join(p.dirname(source), name);
      if (await FileSystemEntity.type(target, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const FileSystemException(
          'An item with that name already exists.',
        );
      }
      await entry.rename(target);
    } else {
      final destination = await const WindowsFilesBridge().chooseFolder();
      if (destination == null || !mounted) return;
      if (action == 'copy' || action == 'move') {
        await _files.copy(
          source,
          p.join(destination, p.basename(source)),
          move: action == 'move',
        );
      } else if (action == 'zip') {
        final name = await _name(
          'ZIP filename',
          '${p.basenameWithoutExtension(source)}.zip',
        );
        if (name == null) return;
        await _files.createZip(source, p.join(destination, name));
      } else {
        final name = await _name(
          'Extract into new folder',
          p.basenameWithoutExtension(source),
        );
        if (name == null) return;
        await _files.extractZip(source, p.join(destination, name));
      }
    }
    await _load();
    await widget.model.refresh();
  });
  Future<void> _newFolder() => _run(() async {
    final name = await _name('New folder', 'New folder');
    if (name == null) return;
    final destination = p.join(_path!, name);
    if (await FileSystemEntity.type(destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FileSystemException('That name already exists.');
    }
    await Directory(destination).create();
    await _load();
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const AppText('Browse folders'),
      actions: [
        IconButton(
          tooltip: context.tr('Choose folder'),
          onPressed: _busy ? null : _choose,
          icon: const Icon(Icons.folder_open),
        ),
        if (_path != null)
          IconButton(
            tooltip: context.tr('Create folder'),
            onPressed: _busy ? null : _newFolder,
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
      ],
    ),
    body: Column(
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_path != null)
          ListTile(
            leading: IconButton(
              tooltip: context.tr('Parent folder'),
              onPressed: _busy || _path == _root
                  ? null
                  : () => _run(() async {
                      _path = p.dirname(_path!);
                      await _load();
                    }),
              icon: const Icon(Icons.arrow_upward),
            ),
            title: SelectableText(_path!),
            trailing: IconButton(
              tooltip: context.tr('Refresh'),
              onPressed: _busy ? null : () => _run(_load),
              icon: const Icon(Icons.refresh),
            ),
          ),
        if (_path == null)
          Padding(
            padding: const EdgeInsets.all(24),
            child: FilledButton.icon(
              onPressed: _busy ? null : _choose,
              icon: const Icon(Icons.folder_open),
              label: const AppText('Choose a folder'),
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: _entries.length,
            itemBuilder: (context, index) {
              final entry = _entries[index];
              final directory = entry is Directory;
              return ListTile(
                leading: Icon(
                  directory ? Icons.folder : Icons.insert_drive_file_outlined,
                ),
                title: Text(p.basename(entry.path)),
                onTap: _busy
                    ? null
                    : () => directory
                          ? _run(() async {
                              _path = entry.path;
                              await _load();
                            })
                          : _action(entry, 'open'),
                trailing: PopupMenuButton<String>(
                  enabled: !_busy && entry is! Link,
                  onSelected: (v) => _action(entry, v),
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'rename',
                      child: AppText('Rename'),
                    ),
                    const PopupMenuItem(
                      value: 'copy',
                      child: AppText('Copy to folder'),
                    ),
                    const PopupMenuItem(
                      value: 'move',
                      child: AppText('Move to folder'),
                    ),
                    const PopupMenuItem(
                      value: 'zip',
                      child: AppText('Create ZIP'),
                    ),
                    if (!directory &&
                        p.extension(entry.path).toLowerCase() == '.zip')
                      const PopupMenuItem(
                        value: 'extract',
                        child: AppText('Extract ZIP'),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}
