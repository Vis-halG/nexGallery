import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/android_media/android_media_bridge.dart';

class AndroidSafBrowser extends StatefulWidget {
  const AndroidSafBrowser({super.key});

  @override
  State<AndroidSafBrowser> createState() => _AndroidSafBrowserState();
}

class _AndroidSafBrowserState extends State<AndroidSafBrowser> {
  final _bridge = AndroidMediaBridge.instance;
  final List<_FolderLevel> _stack = <_FolderLevel>[];
  List<AndroidSafDirectory> _roots = const <AndroidSafDirectory>[];
  List<AndroidDocumentItem> _items = const <AndroidDocumentItem>[];
  bool _loading = true;
  String? _error;

  _FolderLevel? get _current => _stack.isEmpty ? null : _stack.last;

  @override
  void initState() {
    super.initState();
    _loadRoots();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _current?.name ?? 'Device folders',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            if (_current != null)
              IconButton(
                tooltip: context.tr('Create folder'),
                onPressed: _loading ? null : _createFolder,
                icon: const Icon(Icons.create_new_folder_outlined),
              ),
            FilledButton.tonalIcon(
              onPressed: _loading ? null : _chooseFolder,
              icon: const Icon(Icons.add_rounded),
              label: const AppText('Choose folder'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const AppText(
          'Android lets nexGallery access only folders you choose. Access remains on this device.',
        ),
        const SizedBox(height: 12),
        if (_current != null)
          Row(
            children: [
              IconButton(
                tooltip: context.tr('Back'),
                onPressed: _loading ? null : _goBack,
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              Expanded(
                child: Text(
                  _stack.map((level) => level.name).join(' / '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: context.tr('Refresh folder'),
                onPressed: _loading ? null : _loadCurrent,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_error!)),
                  TextButton(onPressed: _reload, child: const AppText('Retry')),
                ],
              ),
            ),
          )
        else if (_current == null)
          _rootList(context)
        else
          _documentList(context),
      ],
    );
  }

  Widget _rootList(BuildContext context) {
    if (_roots.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const Icon(Icons.folder_open_rounded, size: 42),
              const SizedBox(height: 10),
              const AppText('No device folder selected yet.'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _chooseFolder,
                child: const AppText('Choose a folder'),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final root in _roots)
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              onTap: root.uri == null ? null : () => _openRoot(root),
              leading: const CircleAvatar(child: Icon(Icons.folder_rounded)),
              title: Text(root.name ?? 'Selected folder'),
              subtitle: Text(
                root.canWrite ? 'Read and write access' : 'Read-only access',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
            ),
          ),
      ],
    );
  }

  Widget _documentList(BuildContext context) {
    if (_items.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(22),
          child: Center(child: AppText('This folder is empty.')),
        ),
      );
    }
    return Column(
      children: [
        for (final item in _items)
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              onTap: item.isDirectory
                  ? () => _openChild(item)
                  : () => _bridge.openMedia(item.uri, mimeType: item.mimeType),
              leading: CircleAvatar(
                child: Icon(
                  item.isDirectory
                      ? Icons.folder_rounded
                      : _mimeIcon(item.mimeType),
                ),
              ),
              title: Text(
                item.name ?? 'Unnamed item',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                item.isDirectory
                    ? 'Folder'
                    : '${_bytes(item.sizeBytes ?? 0)} • ${item.mimeType ?? 'File'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: PopupMenuButton<_DocumentAction>(
                onSelected: (action) => _act(item, action),
                itemBuilder: (context) => [
                  if (!item.isDirectory)
                    const PopupMenuItem(
                      value: _DocumentAction.open,
                      child: AppText('Open'),
                    ),
                  if (!item.isDirectory)
                    const PopupMenuItem(
                      value: _DocumentAction.share,
                      child: AppText('Share'),
                    ),
                  const PopupMenuItem(
                    value: _DocumentAction.copy,
                    child: AppText('Copy to folder'),
                  ),
                  if (item.canDelete)
                    const PopupMenuItem(
                      value: _DocumentAction.move,
                      child: AppText('Move to folder'),
                    ),
                  const PopupMenuItem(
                    value: _DocumentAction.zip,
                    child: AppText('Create ZIP'),
                  ),
                  if (!item.isDirectory &&
                      (item.name ?? '').toLowerCase().endsWith('.zip'))
                    const PopupMenuItem(
                      value: _DocumentAction.extract,
                      child: AppText('Extract ZIP'),
                    ),
                  if (item.canRename)
                    const PopupMenuItem(
                      value: _DocumentAction.rename,
                      child: AppText('Rename'),
                    ),
                  if (item.canDelete)
                    const PopupMenuItem(
                      value: _DocumentAction.delete,
                      child: AppText('Delete'),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _loadRoots() async {
    if (!_bridge.isSupported) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Folder access is available in the Android app.';
        });
      }
      return;
    }
    try {
      final roots = await _bridge.getPersistedDirectories();
      if (mounted) {
        setState(() {
          _roots = roots;
          _loading = false;
          _error = null;
        });
      }
    } catch (error) {
      _setError(error);
    }
  }

  Future<void> _chooseFolder() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final selected = await _bridge.pickDirectory();
      if (selected.status == 'selected' && selected.uri != null) {
        await _loadRoots();
        await _openRoot(selected);
      } else if (mounted) {
        setState(() => _loading = false);
      }
    } catch (error) {
      _setError(error);
    }
  }

  Future<void> _openRoot(AndroidSafDirectory root) async {
    final uri = root.uri;
    if (uri == null) return;
    _stack
      ..clear()
      ..add(_FolderLevel(uri, root.name ?? 'Selected folder'));
    await _loadCurrent();
  }

  Future<void> _openChild(AndroidDocumentItem item) async {
    _stack.add(_FolderLevel(item.uri, item.name ?? 'Folder'));
    await _loadCurrent();
  }

  Future<void> _goBack() async {
    if (_stack.length > 1) {
      _stack.removeLast();
      await _loadCurrent();
    } else {
      setState(() {
        _stack.clear();
        _items = const <AndroidDocumentItem>[];
      });
    }
  }

  Future<void> _loadCurrent() async {
    final current = _current;
    if (current == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final all = <AndroidDocumentItem>[];
      var offset = 0;
      while (true) {
        final page = await _bridge.listDirectory(
          current.uri,
          limit: 500,
          offset: offset,
        );
        all.addAll(page.items);
        if (!page.hasMore || page.nextOffset == null) break;
        offset = page.nextOffset!;
      }
      all.sort((left, right) {
        if (left.isDirectory != right.isDirectory) {
          return left.isDirectory ? -1 : 1;
        }
        return (left.name ?? '').toLowerCase().compareTo(
          (right.name ?? '').toLowerCase(),
        );
      });
      if (mounted) {
        setState(() {
          _items = all;
          _loading = false;
        });
      }
    } catch (error) {
      _setError(error);
    }
  }

  Future<void> _createFolder() async {
    final current = _current;
    if (current == null) return;
    final name = await _askName('Create folder', 'Folder name');
    if (name == null) return;
    try {
      await _bridge.createDirectory(current.uri, name);
      await _loadCurrent();
    } catch (error) {
      _setError(error);
    }
  }

  Future<void> _act(AndroidDocumentItem item, _DocumentAction action) async {
    try {
      switch (action) {
        case _DocumentAction.open:
          await _bridge.openMedia(item.uri, mimeType: item.mimeType);
        case _DocumentAction.share:
          await _bridge.shareMedia(<Uri>[item.uri], mimeType: item.mimeType);
        case _DocumentAction.copy:
        case _DocumentAction.move:
        case _DocumentAction.zip:
        case _DocumentAction.extract:
          final destination = await _bridge.pickDirectory();
          if (destination.uri == null || !mounted) return;
          setState(() => _loading = true);
          if (action == _DocumentAction.copy ||
              action == _DocumentAction.move) {
            await _bridge.copyDocument(
              item.uri,
              destination.uri!,
              move: action == _DocumentAction.move,
            );
          } else {
            final extract = action == _DocumentAction.extract;
            final name = await _askName(
              extract ? 'Extract into new folder' : 'ZIP filename',
              'Name',
              extract
                  ? (item.name ?? 'Archive').replaceFirst(
                      RegExp(r'\.zip$', caseSensitive: false),
                      '',
                    )
                  : '${item.name ?? 'Archive'}.zip',
            );
            if (name != null) {
              await _bridge.archiveDocument(
                item.uri,
                destination.uri!,
                name,
                extract: extract,
              );
            }
          }
          await _loadCurrent();
        case _DocumentAction.rename:
          final name = await _askName('Rename item', 'New name', item.name);
          if (name == null) return;
          await _bridge.renameDocument(item.uri, name);
          await _loadCurrent();
        case _DocumentAction.delete:
          if (!mounted) return;
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const AppText('Delete this item?'),
              content: Text(
                '${item.name ?? 'This item'} may be deleted immediately by its document provider.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const AppText('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const AppText('Delete'),
                ),
              ],
            ),
          );
          if (confirmed == true) {
            await _bridge.deleteDocument(item.uri);
            await _loadCurrent();
          }
      }
    } on PlatformException catch (error) {
      _setError(error.message ?? error.code);
    } catch (error) {
      _setError(error);
    }
  }

  Future<String?> _askName(
    String title,
    String label, [
    String? initial,
  ]) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const AppText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const AppText('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  void _reload() {
    if (_current == null) {
      _loadRoots();
    } else {
      _loadCurrent();
    }
  }

  void _setError(Object error) {
    if (!mounted) return;
    setState(() {
      _error = error.toString().replaceFirst('PlatformException', 'Android');
      _loading = false;
    });
  }
}

enum _DocumentAction { open, share, rename, delete, copy, move, zip, extract }

final class _FolderLevel {
  const _FolderLevel(this.uri, this.name);

  final Uri uri;
  final String name;
}

IconData _mimeIcon(String? mimeType) {
  if (mimeType?.startsWith('image/') == true) return Icons.image_rounded;
  if (mimeType?.startsWith('video/') == true) return Icons.movie_rounded;
  if (mimeType?.startsWith('audio/') == true) return Icons.audio_file_rounded;
  if (mimeType == 'application/vnd.android.package-archive') {
    return Icons.android_rounded;
  }
  if (mimeType?.contains('zip') == true ||
      mimeType?.contains('archive') == true) {
    return Icons.folder_zip_rounded;
  }
  return Icons.insert_drive_file_rounded;
}

String _bytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
