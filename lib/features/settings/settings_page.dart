import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/gallery_settings.dart';
import '../../services/files/file_tools.dart';
import '../../src/gallery_model.dart';
import '../../src/gallery_organizer.dart';
import '../../src/gallery_tools.dart';
import '../common/dialogs.dart';
import '../common/file_exchange.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({required this.model, required this.isWindows, super.key});
  final GalleryModel model;
  final bool isWindows;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: AnimatedBuilder(
      animation: model,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Appearance', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          DropdownButtonFormField<GalleryAppearance>(
            initialValue: model.settings.appearance,
            decoration: const InputDecoration(
              labelText: 'Theme',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: GalleryAppearance.system,
                child: Text('Use device theme'),
              ),
              DropdownMenuItem(
                value: GalleryAppearance.light,
                child: Text('Light'),
              ),
              DropdownMenuItem(
                value: GalleryAppearance.dark,
                child: Text('Dark'),
              ),
            ],
            onChanged: (value) {
              if (value != null) {
                model.updateSettings(
                  model.settings.copyWith(appearance: value),
                );
              }
            },
          ),
          const SizedBox(height: 24),
          Text('Library', style: Theme.of(context).textTheme.titleLarge),
          if (isWindows) ...[
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Refresh PC folders automatically'),
              subtitle: const Text(
                'Keep selected folders up to date when files change or drives reconnect.',
              ),
              value: model.settings.autoRefresh,
              onChanged: (value) => model.updateSettings(
                model.settings.copyWith(autoRefresh: value),
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Include hidden files'),
              subtitle: const Text(
                'Show hidden files inside the folders you selected.',
              ),
              value: model.settings.includeHiddenFiles,
              onChanged: (value) => model.updateSettings(
                model.settings.copyWith(includeHiddenFiles: value),
              ),
            ),
          ] else ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose photos and videos'),
              subtitle: Text(
                model.hasLimitedAccess
                    ? 'Access is limited to selected media.'
                    : 'Choose which media nexGallery may read.',
              ),
              onTap: model.requestAccessAndRefresh,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.manage_accounts_outlined),
              title: const Text('Android app permissions'),
              onTap: model.openAccessSettings,
            ),
          ],
          const SizedBox(height: 24),
          Text(
            'On-device intelligence',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Analyze only while charging'),
            subtitle: const Text(
              'Faces, objects and text are found on this device. Scans also pause when the device is hot, low on memory or in battery saver.',
            ),
            value: model.settings.analyzeOnlyWhileCharging,
            onChanged: (value) => model.updateSettings(
              model.settings.copyWith(analyzeOnlyWhileCharging: value),
            ),
          ),
          if (!isWindows) ...[
            const SizedBox(height: 24),
            Text(
              'Phone and PC transfers',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Transfer on Wi-Fi only'),
              subtitle: const Text(
                'Pause uploads and downloads on mobile data or metered networks.',
              ),
              value: model.settings.transfersOnWifiOnly,
              onChanged: (value) => model.updateSettings(
                model.settings.copyWith(transfersOnWifiOnly: value),
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Back up camera photos to my PC'),
              subtitle: const Text(
                'When nexGallery is open and connected, new camera photos and videos are copied to the paired PC.',
              ),
              value: model.settings.cameraBackup,
              onChanged: (value) => model.updateSettings(
                model.settings.copyWith(cameraBackup: value),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('PC videos on mobile data'),
              subtitle: const Text(
                'Plays a smaller copy made by your PC. Needs FFmpeg on the PC; Wi-Fi always plays the original.',
              ),
              trailing: DropdownButton<int>(
                value: model.settings.mobileVideoQuality,
                onChanged: (value) => model.updateSettings(
                  model.settings.copyWith(mobileVideoQuality: value),
                ),
                items: const [
                  DropdownMenuItem(value: 360, child: Text('360p')),
                  DropdownMenuItem(value: 720, child: Text('720p')),
                  DropdownMenuItem(value: 0, child: Text('Original')),
                ],
              ),
            ),
          ],
          if (model is GalleryOrganizer) ...[
            const SizedBox(height: 24),
            Text(
              'Backup and restore',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            _OrganizationBackup(organizer: model as GalleryOrganizer),
          ],
          const SizedBox(height: 24),
          Text('Privacy', style: Theme.of(context).textTheme.titleLarge),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.shield_outlined),
            title: Text('Local library'),
            subtitle: Text(
              'Your library, albums, settings and playback positions stay on this device. Remote access is configured separately.',
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.article_outlined),
            title: const Text('Open-source licenses and data sources'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'nexGallery',
            ),
          ),
          if (model.errorMessage != null)
            Text(
              model.errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
  );
}

class _OrganizationBackup extends StatefulWidget {
  const _OrganizationBackup({required this.organizer});

  final GalleryOrganizer organizer;

  @override
  State<_OrganizationBackup> createState() => _OrganizationBackupState();
}

class _OrganizationBackupState extends State<_OrganizationBackup> {
  bool _busy = false;

  Future<void> _run(Future<String?> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final message = await action();
      if (message != null && mounted) showMessage(context, message);
    } catch (error) {
      if (mounted) showMessage(context, friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _export() async {
    final password = await promptPassword(
      context,
      title: 'Protect the backup',
      message: 'Albums, favorites, archive and corrections are encrypted with this password. Photos are not included.',
      confirm: true,
    );
    if (password == null) return null;
    final bytes = await widget.organizer.exportOrganization(password);
    final tools = widget.organizer as GalleryTools;
    final staged = File(
      p.join((await tools.toolsDirectory()).path, '${uniqueId()}.part'),
    );
    try {
      await staged.writeAsBytes(bytes, flush: true);
      final now = DateTime.now();
      final saved = await exportToUserFolder(
        staged,
        'nexGallery-organization-${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}.nexbackup',
      );
      return saved == null ? null : 'Backup saved: $saved';
    } finally {
      if (await staged.exists()) await staged.delete();
    }
  }

  Future<String?> _import() async {
    final file = await pickImportFile();
    if (file == null || !mounted) return null;
    try {
      if (await file.length() > 64 << 20) {
        throw const FormatException('The backup is too large.');
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return null;
      final password = await promptPassword(
        context,
        title: 'Unlock the backup',
      );
      if (password == null) return null;
      final restored = await widget.organizer.importOrganization(
        bytes,
        password,
      );
      return 'Restored organization for $restored items. Albums were merged.';
    } finally {
      if (Platform.isAndroid && await file.exists()) await file.delete();
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ListTile(
        contentPadding: EdgeInsets.zero,
        enabled: !_busy,
        leading: const Icon(Icons.backup_outlined),
        title: const Text('Export albums and favorites'),
        subtitle: const Text('Encrypted with your password'),
        onTap: () => _run(_export),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        enabled: !_busy,
        leading: const Icon(Icons.settings_backup_restore_rounded),
        title: const Text('Restore from a backup'),
        subtitle: const Text('Matches items that are still on this device'),
        onTap: () => _run(_import),
      ),
      if (_busy) const LinearProgressIndicator(),
    ],
  );
}
