import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../data/android_media/android_media_bridge.dart';
import '../../data/device/device_bridge.dart';
import '../../services/files/file_tools.dart';
import '../../services/remote/lan_tools.dart';
import '../../services/remote/nex_gallery_client.dart';
import '../../services/remote/remote_session.dart';
import '../../services/remote/security.dart';
import '../common/dialogs.dart';
import '../common/file_preview.dart';
import 'remote_stream_page.dart';
import 'transfers_sheet.dart';

class RemoteBrowserPage extends StatefulWidget {
  const RemoteBrowserPage({this.session, super.key});

  /// Null until the phone's private storage is ready, and in tests.
  final RemoteSession? session;

  @override
  State<RemoteBrowserPage> createState() => _RemoteBrowserPageState();
}

final _imagePattern = RegExp(
  r'\.(jpg|jpeg|png|webp|gif|bmp|tif|tiff)$',
  caseSensitive: false,
);
final _videoPattern = RegExp(
  r'\.(mp4|mkv|webm|mov|avi|m4v)$',
  caseSensitive: false,
);

class _RemoteBrowserPageState extends State<RemoteBrowserPage> {
  final _address = TextEditingController(text: 'https://'),
      _code = TextEditingController(),
      _name = TextEditingController(text: 'My phone'),
      _fingerprint = TextEditingController(),
      _search = TextEditingController();
  final _thumbnails = _ThumbnailCache();
  List<RemoteRoot> _roots = [];
  List<RemoteEntry> _entries = [];
  List<DiscoveredPc>? _discovered;
  String? _root, _error;
  String _path = '';
  bool _loading = false, _discovering = false;
  Object? _attachedClient;

  RemoteSession? get _session => widget.session;
  NexGalleryRemoteClient? get _client => _session?.client;

  @override
  void initState() {
    super.initState();
    _session?.addListener(_sessionChanged);
  }

  @override
  void didUpdateWidget(covariant RemoteBrowserPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session?.removeListener(_sessionChanged);
      widget.session?.addListener(_sessionChanged);
      _sessionChanged();
    }
  }

  @override
  void dispose() {
    _session?.removeListener(_sessionChanged);
    for (final c in [_address, _code, _name, _fingerprint, _search]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Loads the shared folders once per new connection.
  void _sessionChanged() {
    final client = _client;
    if (!identical(client, _attachedClient)) {
      _attachedClient = client;
      _thumbnails.clear();
      _roots = [];
      _entries = [];
      _root = null;
      _path = '';
      if (client != null) _run(_loadRoots);
    }
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadRoots() async {
    final client = _client;
    if (client == null) return;
    final roots = await client.roots();
    if (roots.isEmpty) {
      throw const FormatException('This PC shares no folders with this phone.');
    }
    _roots = roots;
    _root = roots.first.id;
    await _load();
  }

  Future<void> _load() async {
    final client = _client, root = _root, path = _path;
    final query = _search.text.trim();
    if (client == null || root == null) return;
    final entries = query.isEmpty
        ? await client.list(root: root, path: path)
        : await client.search(root: root, path: path, query: query);
    if (mounted &&
        identical(_client, client) &&
        _root == root &&
        _path == path) {
      setState(() => _entries = entries);
    }
  }

  Future<void> _scan() async {
    try {
      final text = await DeviceBridge.instance.scanQrCode(
        prompt: 'Scan the QR code shown in nexGallery on your PC',
      );
      if (text == null || !mounted) return;
      await _session?.pairWithLink(text, deviceName: _name.text.trim());
    } on UnsupportedError catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _discover() async {
    setState(() {
      _discovering = true;
      _discovered = null;
    });
    try {
      final found = await discoverPcs();
      if (mounted) setState(() => _discovered = found);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  void _choose(DiscoveredPc pc) {
    setState(() {
      _address.text = pc.uri.toString();
      if (pc.fingerprint != null) _fingerprint.text = pc.fingerprint!;
    });
    showMessage(
      context,
      'Check that ${pc.shortFingerprint ?? 'the fingerprint'} matches your PC screen, then enter the pairing code.',
    );
  }

  String _child(String name) =>
      _path.isEmpty ? safeName(name) : '$_path/${safeName(name)}';

  Future<void> _open(RemoteEntry entry) async {
    final client = _client;
    if (client == null) return;
    if (_videoPattern.hasMatch(entry.name)) {
      final quality = await _session?.streamQualityFor(entry);
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              RemoteStreamPage(client: client, entry: entry, quality: quality),
        ),
      );
      return;
    }
    if (_imagePattern.hasMatch(entry.name)) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => _RemotePhotoPage(
            client: client,
            entry: entry,
            onKeepOffline: _session!.allows(DeviceScope.download)
                ? () => _keepOffline(entry)
                : null,
          ),
        ),
      );
      return;
    }
    await _run(() async {
      final cache = Directory(
        p.join(_session!.dataDirectory.path, 'open-cache'),
      );
      if (await cache.exists()) await cache.delete(recursive: true);
      final file = await client.download(
        entry: entry,
        destination: File(p.join(cache.path, safeName(entry.name))),
      );
      await AndroidMediaBridge.instance.openAppFile(file.path);
    });
  }

  Future<void> _keepOffline(RemoteEntry entry) async {
    await _session!.keepOffline(entry);
    if (mounted) showMessage(context, '${entry.name} will be kept offline.');
  }

  Future<void> _upload() async {
    final session = _session, root = _root;
    if (session == null || root == null) return;
    final document = await AndroidMediaBridge.instance.pickDocument();
    if (document.uri == null || !mounted) return;
    await _run(() async {
      final cached = await AndroidMediaBridge.instance.copyDocumentToAppCache(
        document.uri!,
      );
      final name = safeName(document.name ?? cached.name);
      await session.uploadFile(
        File(cached.path),
        name,
        root: root,
        folder: _path,
      );
    });
    if (mounted) showMessage(context, 'Upload added to Transfers.');
  }

  Future<void> _action(RemoteEntry entry, String action) async {
    final client = _client;
    if (client == null) return;
    switch (action) {
      case 'open':
        await _open(entry);
      case 'offline':
        await _keepOffline(entry);
      case 'rename':
        final name = await promptText(
          context,
          title: 'Rename item',
          label: 'Name',
          initialValue: entry.name,
        );
        if (name == null || !mounted) return;
        await _run(() async {
          final parent = p.posix.dirname(entry.path);
          await client.move(
            root: entry.root,
            sourcePath: entry.path,
            destinationPath: parent == '.'
                ? safeName(name)
                : '$parent/${safeName(name)}',
            version: entry.version,
          );
          await _load();
        });
      case 'trash':
        final confirmed = await confirmAction(
          context,
          title: 'Move to PC Trash?',
          message: '${entry.name} can be restored from PC Trash.',
          action: 'Move to Trash',
        );
        if (confirmed && mounted) {
          await _run(() async {
            await client.trash(entry);
            await _load();
          });
        }
    }
  }

  Future<void> _pcTrash() async {
    final client = _client, root = _root;
    if (client == null || root == null) return;
    await _run(() async {
      final entries = await client.trashEntries(root);
      if (!mounted) return;
      final selected = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        builder: (context) => SafeArea(
          child: ListView(
            children: [
              const ListTile(
                title: Text('PC Trash'),
                subtitle: Text('Select an item to restore.'),
              ),
              for (final entry in entries)
                ListTile(
                  title: Text(entry['originalPath'] as String),
                  trailing: const Icon(Icons.restore),
                  onTap: () => Navigator.pop(context, entry),
                ),
              if (entries.isEmpty)
                const ListTile(title: Text('PC Trash is empty.')),
            ],
          ),
        ),
      );
      if (selected != null) {
        await client.restore(
          root: root,
          trashId: selected['trashId'] as String,
        );
        await _load();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final connected = session?.isConnected == true;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'My PC',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              if (session != null) ...[
                IconButton(
                  tooltip: 'Transfers',
                  onPressed: () => showTransfers(context, session.queue),
                  icon: Badge.count(
                    count: session.queue.jobs
                        .where((job) => !job.isFinished)
                        .length,
                    isLabelVisible: session.queue.jobs.any(
                      (job) => !job.isFinished,
                    ),
                    child: const Icon(Icons.swap_vert_rounded),
                  ),
                ),
                IconButton(
                  tooltip: 'Offline files',
                  onPressed: () => showOfflineFiles(context, session),
                  icon: const Icon(Icons.offline_pin_outlined),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          if (!connected) ..._pairing(context) else ..._browser(context),
          if (_loading || session?.isBusy == true) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          if (_error ?? session?.error case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  List<Widget> _pairing(BuildContext context) {
    final session = _session;
    final saved = session?.saved;
    final busy = session == null || session.isBusy;
    return [
      if (saved != null)
        Card(
          child: ListTile(
            leading: const Icon(Icons.computer_rounded),
            title: Text(saved.pcName ?? Uri.parse(saved.address).host),
            subtitle: const Text('Paired PC · not connected'),
            trailing: Wrap(
              spacing: 4,
              children: [
                if (session!.canWake)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () async {
                            await session.wake();
                            await session.reconnect();
                          },
                    child: const Text('Wake PC'),
                  ),
                FilledButton.tonal(
                  onPressed: busy ? null : session.reconnect,
                  child: const Text('Reconnect'),
                ),
              ],
            ),
          ),
        ),
      if (session?.isWaitingForApproval == true)
        Card(
          color: Theme.of(context).colorScheme.tertiaryContainer,
          child: ListTile(
            leading: const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            title: const Text('Waiting for approval on your PC'),
            subtitle: const Text(
              'On the PC, open nexGallery > Server and choose Review.',
            ),
            trailing: TextButton(
              onPressed: session!.cancelPairing,
              child: const Text('Cancel'),
            ),
          ),
        ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Pair with your PC',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              const Text(
                'Start the server in nexGallery on your PC, then scan its QR code.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Device name'),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: busy ? null : _scan,
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    label: const Text('Scan QR code'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _discovering ? null : _discover,
                    icon: const Icon(Icons.wifi_find_rounded),
                    label: const Text('Find PCs on Wi-Fi'),
                  ),
                ],
              ),
              if (_discovering) const LinearProgressIndicator(),
              if (_discovered case final found?) ...[
                if (found.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'No PC answered. Make sure the server uses "Home network" and both devices are on the same Wi-Fi.',
                    ),
                  ),
                for (final pc in found)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.computer_rounded),
                    title: Text(pc.name),
                    subtitle: Text(
                      '${pc.uri.host} · check code ${pc.shortFingerprint ?? '—'}',
                    ),
                    onTap: () => _choose(pc),
                  ),
              ],
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Enter details manually'),
                initiallyExpanded: session == null,
                children: [
                  TextField(
                    controller: _address,
                    decoration: const InputDecoration(
                      labelText: 'PC HTTPS address',
                    ),
                  ),
                  TextField(
                    controller: _fingerprint,
                    decoration: const InputDecoration(
                      labelText: 'PC certificate fingerprint',
                    ),
                  ),
                  TextField(
                    controller: _code,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'One-time pairing code',
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () => session.pairManually(
                            address: _address.text,
                            fingerprint: _fingerprint.text,
                            code: _code.text,
                            deviceName: _name.text,
                          ),
                    child: const Text('Pair and connect'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget> _browser(BuildContext context) {
    final session = _session!;
    final client = session.client!;
    final waiting = session.queue.waitingReason;
    return [
      Row(
        children: [
          const Icon(Icons.check_circle_rounded, color: Colors.green),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              [
                'Connected to ${session.info?.name ?? client.baseUri.host}',
                ?session.connectionLabel,
              ].join(' · '),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Connection options',
            onSelected: (value) =>
                session.disconnect(forget: value == 'forget'),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'disconnect', child: Text('Disconnect')),
              PopupMenuItem(value: 'forget', child: Text('Forget this PC')),
            ],
          ),
        ],
      ),
      if (waiting != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(waiting, style: Theme.of(context).textTheme.bodySmall),
        ),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        key: ValueKey(_root),
        initialValue: _root,
        decoration: const InputDecoration(labelText: 'Shared folder'),
        items: [
          for (final root in _roots)
            DropdownMenuItem(value: root.id, child: Text(root.name)),
        ],
        onChanged: _loading
            ? null
            : (value) {
                setState(() {
                  _root = value;
                  _path = '';
                  _search.clear();
                });
                _run(_load);
              },
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _search,
        decoration: const InputDecoration(
          hintText: 'Search PC files',
          prefixIcon: Icon(Icons.search),
        ),
        onSubmitted: (_) => _run(_load),
      ),
      Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          IconButton(
            tooltip: 'Parent folder',
            onPressed: _loading || _path.isEmpty
                ? null
                : () {
                    setState(
                      () => _path = _path.contains('/')
                          ? _path.substring(0, _path.lastIndexOf('/'))
                          : '',
                    );
                    _run(_load);
                  },
            icon: const Icon(Icons.arrow_upward),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : () => _run(_load),
            icon: const Icon(Icons.refresh),
          ),
          if (session.allows(DeviceScope.upload))
            TextButton.icon(
              onPressed: _loading ? null : _upload,
              icon: const Icon(Icons.upload),
              label: const Text('Upload'),
            ),
          if (session.allows(DeviceScope.organize))
            TextButton.icon(
              onPressed: _loading
                  ? null
                  : () async {
                      final name = await promptText(
                        context,
                        title: 'Create PC folder',
                        label: 'Folder name',
                        action: 'Create',
                      );
                      if (name != null && mounted) {
                        await _run(() async {
                          await client.createFolder(
                            root: _root!,
                            path: _child(name),
                          );
                          await _load();
                        });
                      }
                    },
              icon: const Icon(Icons.create_new_folder),
              label: const Text('New folder'),
            ),
          if (session.allows(DeviceScope.trash))
            TextButton.icon(
              onPressed: _loading ? null : _pcTrash,
              icon: const Icon(Icons.delete_outline),
              label: const Text('PC Trash'),
            ),
        ],
      ),
      Text(_path.isEmpty ? 'Shared folder' : _path),
      for (final entry in _entries)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            entry.isDirectory
                ? 'Folder'
                : [
                    if (entry.size != null) formatBytes(entry.size!),
                    if (entry.modifiedAt != null)
                      MaterialLocalizations.of(context)
                          .formatShortDate(entry.modifiedAt!.toLocal()),
                  ].join(' · '),
          ),
          leading: SizedBox.square(
            dimension: 48,
            child: entry.isDirectory
                ? const Icon(Icons.folder_rounded, size: 36)
                : _imagePattern.hasMatch(entry.name)
                ? _RemoteThumbnail(
                    client: client,
                    entry: entry,
                    cache: _thumbnails,
                  )
                : Icon(
                    _videoPattern.hasMatch(entry.name)
                        ? Icons.movie_rounded
                        : Icons.insert_drive_file_rounded,
                    size: 32,
                  ),
          ),
          onTap: _loading
              ? null
              : entry.isDirectory
              ? () {
                  setState(() => _path = entry.path);
                  _run(_load);
                }
              : () => _open(entry),
          trailing: PopupMenuButton<String>(
            tooltip: 'Actions for ${entry.name}',
            enabled: !_loading,
            onSelected: (value) => _action(entry, value),
            itemBuilder: (_) => [
              if (!entry.isDirectory) ...[
                const PopupMenuItem(
                  value: 'open',
                  child: Text('Open / stream'),
                ),
                if (session.allows(DeviceScope.download))
                  const PopupMenuItem(
                    value: 'offline',
                    child: Text('Keep offline'),
                  ),
              ],
              if (session.allows(DeviceScope.organize))
                const PopupMenuItem(value: 'rename', child: Text('Rename')),
              if (session.allows(DeviceScope.trash))
                const PopupMenuItem(
                  value: 'trash',
                  child: Text('Move to PC Trash'),
                ),
            ],
          ),
        ),
      if (!_loading && _entries.isEmpty)
        const ListTile(title: Text('No files in this view.')),
    ];
  }
}

/// Small LRU of PC photo previews for the current connection.
final class _ThumbnailCache {
  // Map literals keep insertion order, so the first key is the oldest.
  final _entries = <String, Future<Uint8List?>>{};

  Future<Uint8List?> load(NexGalleryRemoteClient client, RemoteEntry entry) {
    final key = '${entry.root}/${entry.path}/${entry.modifiedAt}';
    final existing = _entries.remove(key);
    final future =
        existing ??
        client
            .thumbnail(entry)
            .then<Uint8List?>((bytes) => bytes)
            .catchError((Object _) => null);
    _entries[key] = future;
    while (_entries.length > 200) {
      _entries.remove(_entries.keys.first);
    }
    return future;
  }

  void clear() => _entries.clear();
}

class _RemoteThumbnail extends StatelessWidget {
  const _RemoteThumbnail({
    required this.client,
    required this.entry,
    required this.cache,
  });

  final NexGalleryRemoteClient client;
  final RemoteEntry entry;
  final _ThumbnailCache cache;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: FutureBuilder<Uint8List?>(
      future: cache.load(client, entry),
      builder: (context, snapshot) => snapshot.data == null
          ? ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: const Icon(Icons.image_outlined),
            )
          : Image.memory(
              snapshot.data!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
    ),
  );
}

/// Shows a large PC preview without downloading the original.
class _RemotePhotoPage extends StatelessWidget {
  const _RemotePhotoPage({
    required this.client,
    required this.entry,
    this.onKeepOffline,
  });

  final NexGalleryRemoteClient client;
  final RemoteEntry entry;
  final VoidCallback? onKeepOffline;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: Text(entry.name),
      actions: [
        if (onKeepOffline != null)
          IconButton(
            tooltip: 'Keep original offline',
            onPressed: onKeepOffline,
            icon: const Icon(Icons.download_for_offline_outlined),
          ),
      ],
    ),
    body: FutureBuilder<Uint8List>(
      future: client.thumbnail(entry, size: 1024),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text(
              friendlyError(snapshot.error!),
              style: const TextStyle(color: Colors.white70),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return InteractiveViewer(
          maxScale: 5,
          child: Center(child: Image.memory(snapshot.data!)),
        );
      },
    ),
  );
}

Future<void> showOfflineFiles(
  BuildContext context,
  RemoteSession session,
) async {
  final files = await session.offlineFiles();
  final total = await session.offlineBytes();
  if (!context.mounted) return;
  final selected = await showModalBottomSheet<(File?, String)>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: const Text('Offline files'),
              subtitle: Text(
                '${files.length} files · ${formatBytes(total)} on this phone',
              ),
              trailing: files.isEmpty
                  ? null
                  : TextButton(
                      onPressed: () => Navigator.pop(context, (null, 'clear')),
                      child: const Text('Remove all'),
                    ),
            ),
            for (final file in files)
              ListTile(
                title: Text(p.basename(file.path)),
                onTap: () => Navigator.pop(context, (file, 'open')),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) => Navigator.pop(context, (file, v)),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'share', child: Text('Share')),
                    PopupMenuItem(
                      value: 'export',
                      child: Text('Save to folder'),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('Remove offline copy'),
                    ),
                  ],
                ),
              ),
            if (files.isEmpty)
              const ListTile(
                title: Text(
                  'Use "Keep offline" on a PC file to save a copy here.',
                ),
              ),
          ],
        ),
      ),
    ),
  );
  if (selected == null || !context.mounted) return;
  final (file, action) = selected;
  try {
    switch (action) {
      case 'clear':
        final confirmed = await confirmAction(
          context,
          title: 'Remove all offline files?',
          message: 'The originals stay on your PC.',
          action: 'Remove',
        );
        if (confirmed) await session.clearOffline();
      case 'share':
        await AndroidMediaBridge.instance.shareAppFile(file!.path);
      case 'export':
        final destination = await AndroidMediaBridge.instance.pickDirectory();
        if (destination.uri != null) {
          await AndroidMediaBridge.instance.exportAppFile(
            file!.path,
            destination.uri!,
            name: p.basename(file.path),
          );
        }
      case 'delete':
        await file!.delete();
      default:
        final video = _videoPattern.hasMatch(file!.path);
        if ((video || _imagePattern.hasMatch(file.path)) && context.mounted) {
          await Navigator.push<void>(
            context,
            MaterialPageRoute(
              builder: (_) => FilePreview(
                name: p.basename(file.path),
                file: file,
                isVideo: video,
              ),
            ),
          );
        } else {
          await AndroidMediaBridge.instance.openAppFile(file.path);
        }
    }
  } catch (error) {
    if (context.mounted) showMessage(context, friendlyError(error));
  }
}
