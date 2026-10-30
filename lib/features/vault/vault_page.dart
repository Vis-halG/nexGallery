import '../../l10n/app_strings.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/media_item.dart';
import '../../data/android_media/android_media_bridge.dart';
import '../../data/windows_files/windows_files_bridge.dart';
import '../../services/files/file_tools.dart';
import '../../services/vault/vault_store.dart';
import '../../src/gallery_model.dart';
import '../../src/gallery_tools.dart';
import '../common/dialogs.dart';
import '../common/file_exchange.dart';
import '../common/file_preview.dart';

class VaultPage extends StatefulWidget {
  const VaultPage({required this.tools, this.model, super.key});
  final GalleryTools tools;

  /// When present, the original can be moved to Trash after encryption.
  final GalleryModel? model;
  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> with WidgetsBindingObserver {
  VaultStore? _vault;
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _exists = false;
  bool _busy = false;
  String? _error;
  Directory? _preview;
  Route<void>? _previewRoute;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _privacy(bool enabled) async {
    if (Platform.isAndroid) {
      await AndroidMediaBridge.instance.setPrivacyScreen(enabled);
    } else if (Platform.isWindows) {
      await const WindowsFilesBridge().channel.invokeMethod<void>(
        'setPrivacyScreen',
        {'enabled': enabled},
      );
    }
  }

  Future<void> _initialize() async {
    try {
      final dir = await widget.tools.toolsDirectory();
      final vault = VaultStore(Directory(p.join(dir.path, 'vault')));
      final exists = await vault.exists();
      _preview = Directory(p.join(dir.path, 'vault-preview'));
      if (await _preview!.exists()) await _preview!.delete(recursive: true);
      // Remove leftovers of an interrupted backup import or export.
      final staging = Directory(p.join(dir.path, 'vault-staging'));
      if (await staging.exists()) await staging.delete(recursive: true);
      await _privacy(true);
      if (mounted) {
        setState(() {
          _vault = vault;
          _exists = exists;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _lock();
  }

  void _lock() {
    _vault?.lock();
    _password.clear();
    _confirmation.clear();
    final route = _previewRoute;
    if (route != null && route.isActive && mounted) {
      Navigator.of(context).removeRoute(route);
    }
    _previewRoute = null;
    if (mounted) setState(() {});
    _clearPreview();
  }

  Future<void> _clearPreview() async {
    try {
      if (_preview != null && await _preview!.exists()) {
        await _preview!.delete(recursive: true);
      }
    } on FileSystemException {
      /* a player may still be releasing the file */
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _vault?.lock();
    _password.dispose();
    _confirmation.dispose();
    _clearPreview();
    _privacy(false).catchError((Object _) {});
    super.dispose();
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              _error = e is StateError || e is FormatException ? e.toString() : 'Vault operation failed. Check your password and available storage.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlock() => _run(() async {
    if (!_exists && _password.text != _confirmation.text) {
      throw const FormatException('Passwords do not match.');
    }
    await _vault!.unlock(_password.text, create: !_exists);
    _password.clear();
    _confirmation.clear();
    _exists = true;
  });
  Future<void> _add() async {
    final items = widget.tools.localItems
        .where((v) => v.isAvailable && v.section != MediaSection.trash)
        .toList();
    final item = await showModalBottomSheet<MediaItem>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.75,
          child: ListView(
            children: [
              const ListTile(title: AppText('Add an encrypted copy')),
              for (final item in items)
                ListTile(
                  title: Text(item.name),
                  subtitle: Text(item.relativePath),
                  onTap: () => Navigator.pop(context, item),
                ),
            ],
          ),
        ),
      ),
    );
    if (item == null || !mounted) return;
    var added = false;
    await _run(() async {
      final source = await widget.tools.materialize(item);
      try {
        await _vault!.add(source, item.name);
        added = true;
      } finally {
        if (Platform.isAndroid && await source.exists()) await source.delete();
      }
    });
    final model = widget.model;
    if (!added || model == null || !mounted) return;
    // A copy only becomes private once the visible original is gone.
    final remove = await confirmAction(
      context,
      title: 'Hide the original too?',
      message:
          '${item.name} is now encrypted in your Locked Folder. Move the visible original to Trash so other apps no longer show it?',
      action: 'Move to Trash',
    );
    if (remove && mounted) {
      final moved = await model.moveToTrash(item);
      if (mounted) {
        showMessage(
          context,
          moved
              ? 'Original moved to Trash. Empty Trash to remove it completely.'
              : 'The original was kept.',
        );
      }
    }
  }

  /// Staging outside the preview folder, which is wiped whenever the vault
  /// locks (including while a system file picker is open).
  Future<Directory> _staging() async {
    final directory = Directory(
      p.join((await widget.tools.toolsDirectory()).path, 'vault-staging'),
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> _exportBackup() async {
    final vault = _vault!;
    final stage = File(p.join((await _staging()).path, '${uniqueId()}.zip'));
    await _run(() => vault.exportBackup(stage));
    try {
      if (!await stage.exists() || !mounted) return;
      // The system folder picker backgrounds the app and locks the vault;
      // the backup is already encrypted, so it can still be saved.
      final saved = await exportToUserFolder(
        stage,
        'nexGallery-locked-folder-${DateTime.now().millisecondsSinceEpoch}.nexvault',
      );
      if (saved != null && mounted) {
        showMessage(
          context,
          'Encrypted backup saved. Restoring it needs this vault password.',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (await stage.exists()) await stage.delete();
    }
  }

  Future<void> _importBackup() async {
    final file = await pickImportFile(description: 'Locked Folder backup');
    if (file == null || !mounted) return;
    try {
      if (!_vault!.unlocked && !await _reauthenticate()) return;
      if (!mounted) return;
      final password = await promptPassword(
        context,
        title: 'Backup password',
        message: 'Enter the password of the vault that made this backup.',
      );
      if (password == null || !mounted) return;
      var imported = 0;
      await _run(() async {
        imported = await _vault!.importBackup(
          file,
          password,
          workspace: await _staging(),
        );
      });
      if (mounted && _error == null) {
        showMessage(context, 'Restored $imported encrypted files.');
      }
    } finally {
      if (Platform.isAndroid && await file.exists()) await file.delete();
    }
  }

  Future<void> _open(VaultEntry entry) => _run(() async {
    final destination = File(
      p.join(_preview!.path, '${uniqueId()}${p.extension(entry.name)}'),
    );
    final file = await _vault!.decrypt(entry, destination);
    if (!mounted || !_vault!.unlocked) {
      if (await file.exists()) await file.delete();
      return;
    }
    final video = RegExp(
      r'\.(mp4|mkv|webm|avi|mov)$',
      caseSensitive: false,
    ).hasMatch(entry.name);
    final route = MaterialPageRoute<void>(
      builder: (_) => FilePreview(name: entry.name, file: file, isVideo: video),
    );
    _previewRoute = route;
    await Navigator.push<void>(context, route);
    _previewRoute = null;
    if (await file.exists()) await file.delete();
  });
  Future<void> _export(VaultEntry entry) async {
    String? folder;
    Uri? uri;
    if (Platform.isAndroid) {
      uri = (await AndroidMediaBridge.instance.pickDirectory()).uri;
      if (uri == null) return;
    } else {
      folder = await const WindowsFilesBridge().chooseFolder();
      if (folder == null) return;
    }
    if (!mounted) return;
    // A system folder picker backgrounds the app and locks the vault.
    if (!_vault!.unlocked && !await _reauthenticate()) return;
    if (!mounted) return;
    await _run(() async {
      final file = await _vault!.decrypt(
        entry,
        File(p.join(_preview!.path, '${uniqueId()}${p.extension(entry.name)}')),
      );
      try {
        if (uri != null) {
          await AndroidMediaBridge.instance.exportAppFile(
            file.path,
            uri,
            name: entry.name,
          );
        } else {
          await FileTools().copy(file.path, p.join(folder!, entry.name));
        }
      } finally {
        if (await file.exists()) await file.delete();
      }
    });
  }

  Future<bool> _reauthenticate() async {
    final password = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const AppText('Unlock to export'),
        content: TextField(
          controller: password,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: InputDecoration(labelText: context.tr('Vault password')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const AppText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, password.text),
            child: const AppText('Unlock'),
          ),
        ],
      ),
    );
    password.dispose();
    if (value == null || !mounted) return false;
    await _run(() => _vault!.unlock(value));
    return _vault!.unlocked;
  }

  Future<void> _remove(VaultEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const AppText('Delete encrypted copy?'),
        content: Text(
          '${entry.name} will be permanently removed from this vault.',
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
    if (confirmed == true && mounted) await _run(() => _vault!.remove(entry));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const AppText('Locked Folder'),
      actions: [
        if (_vault?.unlocked == true) ...[
          IconButton(
            tooltip: context.tr('Lock now'),
            onPressed: _lock,
            icon: const Icon(Icons.lock),
          ),
          PopupMenuButton<String>(
            tooltip: context.tr('Backup options'),
            enabled: !_busy,
            onSelected: (value) =>
                value == 'export' ? _exportBackup() : _importBackup(),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'export',
                child: AppText('Export encrypted backup'),
              ),
              PopupMenuItem(
                value: 'import',
                child: AppText('Restore from backup'),
              ),
            ],
          ),
        ],
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_vault == null)
          const AppText('Opening vault…')
        else if (!_vault!.unlocked) ...[
          Text(
            _exists ? 'Unlock your folder' : 'Create a private folder',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const AppText(
            'Files and names are encrypted on this device. Keep your password safe; a forgotten password cannot be recovered.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _password,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(labelText: context.tr('Password')),
          ),
          if (!_exists)
            TextField(
              controller: _confirmation,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: context.tr('Confirm password'),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _unlock,
            child: Text(_exists ? 'Unlock' : 'Create vault'),
          ),
        ] else ...[
          const AppText(
            'Adding creates an encrypted copy. The original remains in your gallery until you remove it there.',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _add,
            icon: const Icon(Icons.add),
            label: const AppText('Add encrypted copy'),
          ),
          if (_vault!.entries.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: AppText('Your Locked Folder is empty.'),
            ),
          for (final entry in _vault!.entries)
            ListTile(
              title: Text(entry.name),
              subtitle: Text('${entry.bytes} bytes'),
              onTap: _busy ? null : () => _open(entry),
              trailing: PopupMenuButton<String>(
                enabled: !_busy,
                onSelected: (v) =>
                    v == 'export' ? _export(entry) : _remove(entry),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'export',
                    child: AppText('Export decrypted copy'),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: AppText('Delete encrypted copy'),
                  ),
                ],
              ),
            ),
        ],
      ],
    ),
  );
}
