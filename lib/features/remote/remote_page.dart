import '../../l10n/app_strings.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/windows_files/windows_files_bridge.dart';
import '../../services/remote/nex_gallery_server.dart';
import '../../services/remote/remote_session.dart';
import '../../services/remote/security.dart';
import '../../services/remote/tailscale.dart';
import '../../services/remote/upload_quarantine.dart';
import '../../src/server_controller.dart';
import '../common/dialogs.dart';
import 'qr_view.dart';
import 'remote_browser_page.dart';

class RemotePage extends StatelessWidget {
  const RemotePage({
    required this.isWindows,
    this.controller,
    this.session,
    super.key,
  });

  final bool isWindows;

  /// The phone's PC connection; null on Windows and before storage is ready.
  final RemoteSession? session;

  /// Injected by tests; the app creates its own.
  final DesktopServerController? controller;

  @override
  Widget build(BuildContext context) => isWindows
      ? DesktopServerPage(controller: controller)
      : RemoteBrowserPage(session: session);
}

const _scopeLabels = <String, (String, String)>{
  DeviceScope.browse: ('Browse', 'See folders, names and photo previews'),
  DeviceScope.download: (
    'Open and download',
    'Stream and save copies of files',
  ),
  DeviceScope.upload: ('Upload', 'Send files from the phone to this PC'),
  DeviceScope.organize: ('Organize', 'Create folders, rename and move'),
  DeviceScope.trash: ('Move to Trash', 'Recoverable delete on this PC'),
};

class DesktopServerPage extends StatefulWidget {
  const DesktopServerPage({this.controller, super.key});

  final DesktopServerController? controller;

  @override
  State<DesktopServerPage> createState() => _DesktopServerPageState();
}

class _DesktopServerPageState extends State<DesktopServerPage> {
  late final DesktopServerController _controller;
  late final bool _ownsController;
  final _pathController = TextEditingController();
  final _folders = <String>[];
  ServerNetworkMode _mode = ServerNetworkMode.thisPc;
  bool _allowWrites = false;
  int _shownRequests = 0;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? DesktopServerController();
    _controller.addListener(_onControllerChanged);
    final profile = Platform.environment['USERPROFILE'];
    _controller.load().then((_) {
      if (!mounted) return;
      setState(() {
        if (_controller.sharedPaths.isNotEmpty) {
          _folders
            ..clear()
            ..addAll(_controller.sharedPaths);
        } else if (profile != null && _folders.isEmpty) {
          _folders.addAll([
            '$profile\\Pictures',
            '$profile\\Documents',
            '$profile\\Downloads',
          ]);
        }
        _mode = _controller.mode;
        _allowWrites = _controller.allowWrites;
      });
    });
  }

  /// Brings the PC window's attention to a phone asking to pair.
  void _onControllerChanged() {
    final pending = _controller.pendingPairings.length;
    if (pending > _shownRequests && mounted) {
      showMessage(context, 'A phone is asking to pair. Review it below.');
    }
    _shownRequests = pending;
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _pathController.dispose();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  Future<void> _addFolder() async {
    String? path;
    try {
      path = await const WindowsFilesBridge().chooseFolder();
    } on MissingPluginException {
      path = _pathController.text.trim();
    } on PlatformException {
      path = _pathController.text.trim();
    }
    if (path == null || path.isEmpty) return;
    if (!await Directory(path).exists()) {
      if (mounted) showMessage(context, 'That folder does not exist.');
      return;
    }
    setState(() {
      if (!_folders.any((v) => v.toLowerCase() == path!.toLowerCase())) {
        _folders.add(path!);
      }
      _pathController.clear();
    });
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
            AppText(
              'PC server',
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.6),
            ),
            const SizedBox(height: 4),
            AppText(
              'Share only the folders you approve with phones you approve.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            _statusCard(context),
            if (_controller.pendingPairings.isNotEmpty) ...[
              const SizedBox(height: 16),
              _pendingCard(context),
            ],
            const SizedBox(height: 16),
            _settingsCard(context),
            if (_mode == ServerNetworkMode.privateNetwork) ...[
              const SizedBox(height: 16),
              _TailscaleCard(controller: _controller),
            ],
            if (_controller.devices.isNotEmpty) ...[
              const SizedBox(height: 16),
              _devicesCard(context),
            ],
            if (_controller.quarantined.isNotEmpty) ...[
              const SizedBox(height: 16),
              _quarantineCard(context),
            ],
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
                      child: AppText(
                        'Connections use TLS with this PC\'s pinned certificate. Every phone signs its requests with its own key, and you approve each phone and what it may do. Never forward this port on your router; use Tailscale for access away from home.',
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

  Widget _settingsCard(BuildContext context) {
    final running = _controller.isRunning;
    final starting = _controller.state == DesktopServerState.starting;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppText(
              'Allowed folders',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            const AppText(
              'Only these folders and their contents are visible to phones.',
            ),
            for (final folder in _folders)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.folder_outlined),
                title: Text(
                  folder,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  tooltip: context.tr('Stop sharing this folder'),
                  onPressed: running
                      ? null
                      : () => setState(() => _folders.remove(folder)),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _pathController,
                    enabled: !running,
                    decoration: InputDecoration(
                      labelText: context.tr('Folder path (optional)'),
                      hintText: r'D:\Photos',
                    ),
                    onSubmitted: (_) => _addFolder(),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: running ? null : _addFolder,
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const AppText('Add folder'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            AppText(
              'Who can connect',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            SegmentedButton<ServerNetworkMode>(
              segments: const [
                ButtonSegment(
                  value: ServerNetworkMode.thisPc,
                  icon: Icon(Icons.computer_outlined),
                  label: AppText('This PC'),
                ),
                ButtonSegment(
                  value: ServerNetworkMode.lan,
                  icon: Icon(Icons.wifi_rounded),
                  label: AppText('Home network'),
                ),
                ButtonSegment(
                  value: ServerNetworkMode.privateNetwork,
                  icon: Icon(Icons.vpn_lock_rounded),
                  label: AppText('Anywhere (Tailscale)'),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: running
                  ? null
                  : (value) => setState(() => _mode = value.single),
            ),
            const SizedBox(height: 6),
            Text(switch (_mode) {
              ServerNetworkMode.thisPc =>
                'Only apps on this PC can connect. Useful for testing.',
              ServerNetworkMode.lan =>
                'Phones on your trusted Wi-Fi can find and connect to this PC.',
              ServerNetworkMode.privateNetwork => 'Phones signed in to your Tailscale network can connect from anywhere. Nothing is exposed to the public internet.',
            }, style: Theme.of(context).textTheme.bodySmall),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _allowWrites,
              onChanged: running
                  ? null
                  : (value) => setState(() => _allowWrites = value),
              title: const AppText('Allow changes from paired phones'),
              subtitle: const AppText(
                'Needed for uploads, camera backup, folders, rename and Trash. Each phone also needs your permission.',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _controller.autoStart,
              onChanged: _controller.runsInBackground
                  ? null
                  : (value) => _controller.setAutoStart(value),
              title: const AppText('Start the server when nexGallery opens'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _controller.runsInBackground,
              onChanged: !_controller.agentAvailable || starting
                  ? null
                  : (value) async {
                      // Keep the folders and options chosen on this page.
                      if (!running) {
                        await _controller.start(
                          sharedPaths: List.of(_folders),
                          mode: _mode,
                          allowWrites: _allowWrites,
                        );
                      }
                      await _controller.setRunInBackground(value);
                    },
              title: const AppText('Keep running when nexGallery is closed'),
              subtitle: Text(
                _controller.agentAvailable
                    ? 'Starts when you sign in to Windows and runs with your account\'s permissions only.'
                    : 'The background server is installed by the nexGallery installer.',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _controller.keepAwake,
              onChanged: starting
                  ? null
                  : (value) => _controller.setKeepAwake(value),
              title: const AppText('Keep this PC available'),
              subtitle: const AppText(
                'Windows does not sleep while the server runs. The screen can still turn off. Streams and transfers always keep the PC awake until they finish.',
              ),
            ),
            const SizedBox(height: 10),
            if (running)
              OutlinedButton.icon(
                onPressed: _controller.stop,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const AppText('Stop server'),
              )
            else
              FilledButton.icon(
                onPressed: starting
                    ? null
                    : () => _controller.start(
                        sharedPaths: List.of(_folders),
                        mode: _mode,
                        allowWrites: _allowWrites,
                      ),
                icon: starting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow_rounded),
                label: const AppText('Start server'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = _controller.isRunning;
    final link = _controller.pairingLink;
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
                  TextButton.icon(
                    onPressed: () => _showActivity(context),
                    icon: const Icon(Icons.history_rounded),
                    label: const AppText('Activity'),
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
                    child: const AppText('ONLINE'),
                  ),
              ],
            ),
            if (_controller.error case final error?) ...[
              const SizedBox(height: 10),
              Text(error, style: TextStyle(color: scheme.error)),
            ],
            if (running) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 24,
                runSpacing: 16,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (link != null)
                    Column(
                      children: [
                        QrView(data: link),
                        const SizedBox(height: 8),
                        const AppText('Scan in nexGallery on your phone'),
                      ],
                    ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: _pairingDetails(context),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _pairingDetails(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final code = _controller.pairingCode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (code != null)
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
                      const AppText('One-time pairing code'),
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
                  tooltip: context.tr('Generate a new code'),
                  onPressed: _controller.createPairingCode,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
        if (_controller.fingerprint != null)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const AppText('PC certificate fingerprint'),
            subtitle: SelectableText(_controller.fingerprint!),
            trailing: IconButton(
              tooltip: context.tr('Copy fingerprint'),
              icon: const Icon(Icons.copy),
              onPressed: () => Clipboard.setData(
                ClipboardData(text: _controller.fingerprint!),
              ),
            ),
          ),
        for (final url in _controller.urls)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.link_rounded),
            title: SelectableText(url),
            trailing: IconButton(
              tooltip: context.tr('Copy address'),
              onPressed: () => Clipboard.setData(ClipboardData(text: url)),
              icon: const Icon(Icons.copy_rounded),
            ),
          ),
      ],
    );
  }

  Widget _pendingCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppText(
              'Waiting for your approval',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            for (final request in _controller.pendingPairings)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.phone_android_rounded),
                title: Text(request.deviceName),
                subtitle: Text(
                  'From ${request.remoteAddress} · '
                  '${request.signedRequests ? 'signed requests' : 'no device key'}',
                ),
                trailing: Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => _controller.deny(request.requestId),
                      child: const AppText('Decline'),
                    ),
                    FilledButton(
                      onPressed: () => _approve(request),
                      child: const AppText('Review'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _approve(PairingRequest request) async {
    final choice = await showDialog<(Set<String>, List<String>?)>(
      context: context,
      builder: (_) => _PermissionsDialog(
        title: 'Allow "${request.deviceName}"?',
        roots: _controller.roots,
        scopes: DeviceScope.readOnly,
        allowWrites: _controller.allowWrites,
        action: 'Approve',
      ),
    );
    if (choice == null || !mounted) return;
    try {
      await _controller.approve(
        request.requestId,
        scopes: choice.$1,
        roots: choice.$2,
      );
      if (mounted) showMessage(context, '${request.deviceName} is paired.');
    } catch (error) {
      if (mounted) showMessage(context, friendlyError(error));
    }
  }

  Widget _quarantineCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppText(
              'Uploads held for a security check',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            AppText(
              'Programs, scripts, archives and macro documents from phones stay out of your folders until they are scanned.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            for (final item in _controller.quarantined)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  switch (item.status) {
                    QuarantineStatus.scanning => Icons.hourglass_top_rounded,
                    QuarantineStatus.held => Icons.pause_circle_outline_rounded,
                    QuarantineStatus.blocked => Icons.gpp_bad_rounded,
                  },
                  color: item.status == QuarantineStatus.blocked
                      ? scheme.error
                      : null,
                ),
                title: Text(item.name),
                subtitle: Text(
                  [
                    switch (item.status) {
                      QuarantineStatus.scanning =>
                        'Scanning with ${item.scanner ?? 'the scanner'}',
                      QuarantineStatus.held =>
                        'Not scanned: no antivirus scanner answered',
                      QuarantineStatus.blocked =>
                        '${item.scanner ?? 'The scanner'} found a threat',
                    },
                    formatBytes(item.size),
                    if (item.deviceName != null) 'from ${item.deviceName}',
                  ].join(' · '),
                ),
                trailing: item.status == QuarantineStatus.scanning
                    ? null
                    : PopupMenuButton<String>(
                        tooltip: 'Manage ${item.name}',
                        onSelected: (action) => action == 'release'
                            ? _release(item)
                            : _discard(item),
                        itemBuilder: (_) => [
                          if (item.status == QuarantineStatus.held)
                            const PopupMenuItem(
                              value: 'release',
                              child: AppText('Release to folder'),
                            ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: AppText('Delete'),
                          ),
                        ],
                      ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _release(QuarantinedUpload item) async {
    final confirmed = await confirmAction(
      context,
      title: 'Release ${item.name}?',
      message: 'No antivirus scanner checked this file. Release it only if you trust the phone and the file. Windows still warns before it runs.',
      action: 'Release',
    );
    if (!confirmed) return;
    try {
      final path = await _controller.releaseUpload(item);
      if (mounted && path != null) showMessage(context, 'Moved to $path.');
    } on Object catch (error) {
      if (mounted) showMessage(context, friendlyError(error));
    }
  }

  Future<void> _discard(QuarantinedUpload item) async {
    final confirmed = await confirmAction(
      context,
      title: 'Delete ${item.name}?',
      message: 'The held upload is deleted from this PC.',
      action: 'Delete',
    );
    if (!confirmed) return;
    try {
      await _controller.discardUpload(item);
    } on Object catch (error) {
      if (mounted) showMessage(context, friendlyError(error));
    }
  }

  Widget _devicesCard(BuildContext context) {
    final tailscale = _controller.tailscale;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppText(
              'Paired phones',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            for (final device in _controller.devices)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.smartphone_rounded),
                title: Text(device.name),
                subtitle: Text(
                  [
                    device.scopes
                        .map((scope) => _scopeLabels[scope]?.$1 ?? scope)
                        .join(', '),
                    if (device.roots != null)
                      '${device.roots!.length} of ${_controller.roots.length} folders',
                    if (device.lastUsedAt != null)
                      'Last seen ${_relative(device.lastUsedAt!)}',
                    ?_connection(device, tailscale),
                  ].join(' · '),
                ),
                trailing: PopupMenuButton<String>(
                  tooltip: 'Manage ${device.name}',
                  onSelected: (action) => action == 'remove'
                      ? _remove(device)
                      : _editPermissions(device),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'permissions',
                      child: AppText('Change permissions'),
                    ),
                    PopupMenuItem(
                      value: 'remove',
                      child: AppText('Remove phone'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String? _connection(DeviceIdentity device, TailscaleStatus? tailscale) {
    final address = device.lastAddress;
    if (address == null) return null;
    if (!isTailnetAddress(address)) {
      return address == '127.0.0.1' ? 'On this PC' : 'Home network';
    }
    final peer = tailscale?.peerFor(address);
    return switch (peer?.connection) {
      'direct' => 'Tailscale, direct',
      'relay' => 'Tailscale, relayed via ${peer!.relay}',
      _ => 'Tailscale',
    };
  }

  Future<void> _editPermissions(DeviceIdentity device) async {
    final choice = await showDialog<(Set<String>, List<String>?)>(
      context: context,
      builder: (_) => _PermissionsDialog(
        title: 'Permissions for ${device.name}',
        roots: _controller.roots,
        scopes: device.scopes,
        selectedRoots: device.roots,
        allowWrites: _controller.allowWrites,
        action: 'Save',
      ),
    );
    if (choice == null) return;
    await _controller.updatePermissions(
      device.tokenId,
      scopes: choice.$1,
      roots: choice.$2,
    );
  }

  Future<void> _remove(DeviceIdentity device) async {
    final confirmed = await confirmAction(
      context,
      title: 'Remove ${device.name}?',
      message: 'The phone loses access immediately. It can pair again only with a new code and your approval.',
      action: 'Remove',
    );
    if (confirmed) await _controller.revoke(device.tokenId);
  }

  Future<void> _showActivity(BuildContext context) async {
    final entries = await _controller.readAudit();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const AppText('Server activity'),
        content: SizedBox(
          width: 560,
          height: 480,
          child: entries.isEmpty
              ? const Center(child: AppText('No activity yet.'))
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final time = DateTime.tryParse('${entry['timestamp']}');
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        entry['outcome'] == 'success'
                            ? Icons.check_rounded
                            : Icons.block_rounded,
                        size: 18,
                      ),
                      title: Text('${entry['action']} · ${entry['outcome']}'),
                      subtitle: Text(
                        [
                          if (time != null)
                            time.toLocal().toString().split('.').first,
                          if (entry['path'] != null) '${entry['path']}',
                          if (entry['remoteAddress'] != null)
                            '${entry['remoteAddress']}',
                        ].join(' · '),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const AppText('Close'),
          ),
        ],
      ),
    );
  }

  double _padding(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 600 ? 16 : 24;
}

class _PermissionsDialog extends StatefulWidget {
  const _PermissionsDialog({
    required this.title,
    required this.roots,
    required this.scopes,
    required this.allowWrites,
    required this.action,
    this.selectedRoots,
  });

  final String title;
  final Map<String, String> roots;
  final Set<String> scopes;
  final List<String>? selectedRoots;
  final bool allowWrites;
  final String action;

  @override
  State<_PermissionsDialog> createState() => _PermissionsDialogState();
}

class _PermissionsDialogState extends State<_PermissionsDialog> {
  late final Set<String> _scopes = {...widget.scopes};
  late final Set<String> _roots = {
    ...(widget.selectedRoots ?? widget.roots.keys),
  };

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 480,
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final entry in _scopeLabels.entries)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _scopes.contains(entry.key),
              title: Text(entry.value.$1),
              subtitle: Text(
                !widget.allowWrites && !DeviceScope.readOnly.contains(entry.key)
                    ? '${entry.value.$2}. Turn on "Allow changes" to use it.'
                    : entry.value.$2,
              ),
              onChanged: (value) => setState(
                () => value == true
                    ? _scopes.add(entry.key)
                    : _scopes.remove(entry.key),
              ),
            ),
          const Divider(),
          const AppText('Folders this phone may open'),
          for (final root in widget.roots.entries)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _roots.contains(root.key),
              title: Text(
                root.value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onChanged: (value) => setState(
                () => value == true
                    ? _roots.add(root.key)
                    : _roots.remove(root.key),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const AppText('Cancel'),
      ),
      FilledButton(
        onPressed: _scopes.isEmpty || _roots.isEmpty
            ? null
            : () => Navigator.pop(context, (
                Set<String>.of(_scopes),
                _roots.length == widget.roots.length
                    ? null
                    : widget.roots.keys.where(_roots.contains).toList(),
              )),
        child: Text(widget.action),
      ),
    ],
  );
}

/// Guides the owner through Tailscale: install, sign in, then pair over the
/// private address shown in the QR code.
class _TailscaleCard extends StatefulWidget {
  const _TailscaleCard({required this.controller});

  final DesktopServerController controller;

  @override
  State<_TailscaleCard> createState() => _TailscaleCardState();
}

class _TailscaleCardState extends State<_TailscaleCard> {
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    if (widget.controller.tailscale == null) _check();
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    try {
      await widget.controller.refreshTailscale();
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.controller.tailscale;
    final installed = status?.installed == true;
    final running = status?.running == true;
    Widget step(bool done, String title, String detail) => ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        done ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
        color: done ? Colors.green : null,
      ),
      title: Text(title),
      subtitle: Text(detail),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: AppText(
                    'Private network setup',
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton(
                  tooltip: context.tr('Check Tailscale again'),
                  onPressed: _checking ? null : _check,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            if (_checking) const LinearProgressIndicator(),
            step(
              installed,
              'Install Tailscale on this PC',
              'Download the official client from tailscale.com/download.',
            ),
            step(
              running,
              'Sign in on this PC',
              running
                  ? 'Connected as ${status!.selfName ?? 'this PC'} · ${status.ipv4.join(', ')}'
                  : status?.state == 'NeedsLogin'
                  ? 'Open Tailscale and sign in.'
                  : 'Open Tailscale and connect.',
            ),
            step(
              running && status!.peers.any((peer) => peer.online),
              'Install Tailscale on your phone and use the same account',
              running
                  ? '${status!.peers.where((peer) => peer.online).length} other devices online in your network'
                  : 'Your phone joins the same private network.',
            ),
            step(
              widget.controller.isRunning &&
                  widget.controller.mode == ServerNetworkMode.privateNetwork,
              'Start the server and scan the QR code',
              'The phone connects to this PC\'s private address, directly when possible or through an encrypted relay.',
            ),
          ],
        ),
      ),
    );
  }
}

String _relative(DateTime value) {
  final difference = DateTime.now().toUtc().difference(value.toUtc());
  if (difference.inMinutes < 2) return 'just now';
  if (difference.inHours < 1) return '${difference.inMinutes} min ago';
  if (difference.inDays < 1) return '${difference.inHours} h ago';
  return '${difference.inDays} days ago';
}

String _time(DateTime value) {
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${value.hour >= 12 ? 'PM' : 'AM'}';
}
