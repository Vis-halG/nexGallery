import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/remote/nex_gallery_client.dart';
import '../../src/server_controller.dart';

class RemotePage extends StatelessWidget {
  const RemotePage({required this.isWindows, super.key});

  final bool isWindows;

  @override
  Widget build(BuildContext context) =>
      isWindows ? const _DesktopServerPage() : const _PhoneRemotePage();
}

class _DesktopServerPage extends StatefulWidget {
  const _DesktopServerPage();

  @override
  State<_DesktopServerPage> createState() => _DesktopServerPageState();
}

class _DesktopServerPageState extends State<_DesktopServerPage> {
  final _controller = DesktopServerController();
  final _folderController = TextEditingController();
  bool _lan = false;

  @override
  void initState() {
    super.initState();
    final profile = Platform.environment['USERPROFILE'];
    if (profile != null) {
      _folderController.text = [
        '$profile\\Pictures',
        '$profile\\Documents',
        '$profile\\Downloads',
      ].join('\n');
    }
  }

  @override
  void dispose() {
    _folderController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            _padding(context),
            20,
            _padding(context),
            80,
          ),
          children: [
            Text(
              'PC server',
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.6),
            ),
            const SizedBox(height: 4),
            Text(
              'Share only the folders you approve with paired phones.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            _statusCard(context),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Allowed folders',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Enter one folder per line. Only these roots and their children are exposed.',
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _folderController,
                      enabled: !_controller.isRunning,
                      minLines: 3,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: 'Folder paths',
                        hintText: 'D:\\Photos\nD:\\Documents',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _lan,
                      onChanged: _controller.isRunning
                          ? null
                          : (value) => setState(() => _lan = value),
                      title: const Text('Trusted LAN / private VPN access'),
                      subtitle: const Text(
                        'Required for a phone. Never port-forward this HTTP port.',
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_controller.isRunning)
                      OutlinedButton.icon(
                        onPressed: _controller.stop,
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text('Stop server'),
                      )
                    else
                      FilledButton.icon(
                        onPressed:
                            _controller.state == DesktopServerState.starting
                            ? null
                            : () => _controller.start(
                                sharedPaths: _folderController.text.split(
                                  RegExp(r'[\r\n]+'),
                                ),
                                listenOnLan: _lan,
                              ),
                        icon: _controller.state == DesktopServerState.starting
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.play_arrow_rounded),
                        label: const Text('Start server'),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: const Padding(
                padding: EdgeInsets.all(18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.security_rounded),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Anywhere access requires your own encrypted Tailscale or WireGuard connection. The current server intentionally starts on loopback unless LAN access is enabled.',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = _controller.isRunning;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  running
                      ? Icons.check_circle_rounded
                      : Icons.pause_circle_outline,
                  color: running ? Colors.green : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    running ? 'Server running' : 'Server stopped',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                if (running)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text('ONLINE'),
                  ),
              ],
            ),
            if (_controller.error case final error?) ...[
              const SizedBox(height: 10),
              Text(error, style: TextStyle(color: scheme.error)),
            ],
            if (running) ...[
              const SizedBox(height: 16),
              for (final url in _controller.urls)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.link_rounded),
                  title: SelectableText(url),
                  trailing: IconButton(
                    tooltip: 'Copy address',
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: url)),
                    icon: const Icon(Icons.copy_rounded),
                  ),
                ),
              if (_controller.pairingCode case final code?)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('One-time pairing code'),
                            SelectableText(
                              code.code,
                              style: Theme.of(context).textTheme.headlineMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 3,
                                  ),
                            ),
                            Text('Expires ${_time(code.expiresAt.toLocal())}'),
                          ],
                        ),
                      ),
                      IconButton.filledTonal(
                        tooltip: 'Generate a new code',
                        onPressed: _controller.createPairingCode,
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  double _padding(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 600 ? 16 : 24;
}

class _PhoneRemotePage extends StatefulWidget {
  const _PhoneRemotePage();

  @override
  State<_PhoneRemotePage> createState() => _PhoneRemotePageState();
}

class _PhoneRemotePageState extends State<_PhoneRemotePage> {
  final _address = TextEditingController(text: 'http://');
  final _code = TextEditingController();
  final _deviceName = TextEditingController(text: 'My phone');
  NexGalleryRemoteClient? _client;
  List<RemoteRoot> _roots = const <RemoteRoot>[];
  List<RemoteEntry> _entries = const <RemoteEntry>[];
  String? _selectedRoot;
  String _path = '';
  String? _error;
  bool _loading = false;

  @override
  void dispose() {
    _address.dispose();
    _code.dispose();
    _deviceName.dispose();
    _client?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          _padding(context),
          20,
          _padding(context),
          96,
        ),
        children: [
          Text(
            'My PC',
            style: Theme.of(context).textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.6),
          ),
          const SizedBox(height: 4),
          Text(
            _client == null
                ? 'Pair with your private nexGallery PC server'
                : 'Connected to ${_client!.baseUri.host}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          if (_client == null) _pairingCard(context) else _browser(context),
          if (_error case final error?) ...[
            const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline_rounded),
                    const SizedBox(width: 10),
                    Expanded(child: Text(error)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _pairingCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Connect securely',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
            ),
            const SizedBox(height: 6),
            const Text(
              'Use the address and one-time code displayed by nexGallery on your PC.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _address,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'PC address',
                hintText: 'http://100.x.x.x:8732',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              maxLength: 32,
              decoration: const InputDecoration(
                labelText: 'Pairing code',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _deviceName,
              decoration: const InputDecoration(
                labelText: 'Device name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loading ? null : _pair,
              icon: _loading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link_rounded),
              label: const Text('Pair and connect'),
            ),
            const SizedBox(height: 12),
            const Text(
              'For access away from home, use an encrypted private network such as Tailscale. Do not expose port 8732 directly to the public internet.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _browser(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.cloud_done_rounded, color: Colors.green),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Paired for this session',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    TextButton(
                      onPressed: _disconnect,
                      child: const Text('Disconnect'),
                    ),
                  ],
                ),
                if (_roots.isNotEmpty)
                  DropdownButtonFormField<String>(
                    initialValue: _selectedRoot,
                    decoration: const InputDecoration(
                      labelText: 'Shared folder',
                    ),
                    items: [
                      for (final root in _roots)
                        DropdownMenuItem(
                          value: root.id,
                          child: Text(root.name),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      _selectedRoot = value;
                      _path = '';
                      _loadDirectory();
                    },
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            IconButton(
              tooltip: 'Parent folder',
              onPressed: _path.isEmpty || _loading ? null : _goUp,
              icon: const Icon(Icons.arrow_upward_rounded),
            ),
            Expanded(
              child: Text(
                _path.isEmpty ? 'Shared folder' : _path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _loading ? null : _loadDirectory,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        if (_loading)
          const LinearProgressIndicator()
        else if (_entries.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('This folder is empty.')),
            ),
          )
        else
          for (final entry in _entries)
            Card(
              margin: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                onTap: entry.isDirectory ? () => _openDirectory(entry) : null,
                leading: CircleAvatar(
                  child: Icon(
                    entry.isDirectory
                        ? Icons.folder_rounded
                        : Icons.insert_drive_file_rounded,
                  ),
                ),
                title: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  entry.isDirectory ? 'Folder' : _bytes(entry.size ?? 0),
                ),
                trailing: entry.isDirectory
                    ? const Icon(Icons.chevron_right_rounded)
                    : const Tooltip(
                        message: 'Streaming and offline download UI is being connected',
                        child: Icon(Icons.download_outlined),
                      ),
              ),
            ),
      ],
    );
  }

  Future<void> _pair() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    NexGalleryRemoteClient? candidate;
    try {
      final uri = Uri.parse(_address.text.trim());
      candidate = NexGalleryRemoteClient(baseUri: uri);
      await candidate.health();
      await candidate.pair(
        code: _code.text.trim(),
        deviceName: _deviceName.text.trim().isEmpty
            ? 'Android phone'
            : _deviceName.text.trim(),
      );
      final roots = await candidate.roots();
      if (roots.isEmpty) {
        throw const FormatException('The PC shares no folders.');
      }
      _client?.close();
      _client = candidate;
      candidate = null;
      _roots = roots;
      _selectedRoot = roots.first.id;
      _path = '';
      await _loadDirectory(setLoading: false);
    } catch (error) {
      candidate?.close();
      _error = error.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadDirectory({bool setLoading = true}) async {
    final client = _client;
    final root = _selectedRoot;
    if (client == null || root == null) return;
    if (setLoading && mounted) setState(() => _loading = true);
    try {
      final entries = await client.list(root: root, path: _path);
      if (mounted) {
        setState(() {
          _entries = entries;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (setLoading && mounted) setState(() => _loading = false);
    }
  }

  void _openDirectory(RemoteEntry entry) {
    _path = entry.path;
    _loadDirectory();
  }

  void _goUp() {
    final normalized = _path.replaceAll('\\', '/');
    final separator = normalized.lastIndexOf('/');
    _path = separator < 0 ? '' : normalized.substring(0, separator);
    _loadDirectory();
  }

  void _disconnect() {
    _client?.close();
    setState(() {
      _client = null;
      _roots = const <RemoteRoot>[];
      _entries = const <RemoteEntry>[];
      _selectedRoot = null;
      _path = '';
    });
  }

  double _padding(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 600 ? 16 : 24;
}

String _time(DateTime value) {
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${value.hour >= 12 ? 'PM' : 'AM'}';
}

String _bytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
