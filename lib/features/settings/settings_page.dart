import '../../l10n/app_strings.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/gallery_settings.dart';
import '../../services/files/file_tools.dart';
import '../../src/gallery_model.dart';
import '../../src/gallery_organizer.dart';
import '../../src/gallery_tools.dart';
import '../../src/catalog_security.dart';
import '../../services/updates/app_update.dart';
import '../common/dialogs.dart';
import '../common/file_exchange.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({required this.model, required this.isWindows, super.key});
  final GalleryModel model;
  final bool isWindows;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const AppText('Settings')),
    body: AnimatedBuilder(
      animation: model,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          AppText('Appearance', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          DropdownButtonFormField<GalleryAppearance>(
            initialValue: model.settings.appearance,
            decoration: InputDecoration(
              labelText: context.tr('Theme'),
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: GalleryAppearance.system,
                child: AppText('Use device theme'),
              ),
              DropdownMenuItem(
                value: GalleryAppearance.light,
                child: AppText('Light'),
              ),
              DropdownMenuItem(
                value: GalleryAppearance.dark,
                child: AppText('Dark'),
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
          DropdownButtonFormField<String>(
            initialValue: model.settings.language,
            decoration: InputDecoration(
              labelText: context.tr('Language'),
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: 'system',
                child: AppText('Use device language'),
              ),
              DropdownMenuItem(value: 'en', child: AppText('English')),
              DropdownMenuItem(value: 'hi', child: AppText('हिन्दी')),
            ],
            onChanged: (value) {
              if (value != null) {
                model.updateSettings(model.settings.copyWith(language: value));
              }
            },
          ),
          const SizedBox(height: 24),
          AppText('Library', style: Theme.of(context).textTheme.titleLarge),
          if (isWindows) ...[
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const AppText('Refresh PC folders automatically'),
              subtitle: const AppText(
                'Keep selected folders up to date when files change or drives reconnect.',
              ),
              value: model.settings.autoRefresh,
              onChanged: (value) => model.updateSettings(
                model.settings.copyWith(autoRefresh: value),
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const AppText('Include hidden files'),
              subtitle: const AppText(
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
              title: const AppText('Choose photos and videos'),
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
              title: const AppText('Android app permissions'),
              onTap: model.openAccessSettings,
            ),
          ],
          const SizedBox(height: 24),
          AppText(
            'On-device intelligence',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const AppText('Analyze only while charging'),
            subtitle: const AppText(
              'Faces, objects and text are found on this device. Scans also pause when the device is hot, low on memory or in battery saver.',
            ),
            value: model.settings.analyzeOnlyWhileCharging,
            onChanged: (value) => model.updateSettings(
              model.settings.copyWith(analyzeOnlyWhileCharging: value),
            ),
          ),
          if (!isWindows) ...[
            const SizedBox(height: 24),
            AppText(
              'Phone and PC transfers',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const AppText('Transfer on Wi-Fi only'),
              subtitle: const AppText(
                'Pause uploads and downloads on mobile data or metered networks.',
              ),
              value: model.settings.transfersOnWifiOnly,
              onChanged: (value) => model.updateSettings(
                model.settings.copyWith(transfersOnWifiOnly: value),
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const AppText('Back up camera photos to my PC'),
              subtitle: const AppText(
                'When nexGallery is open and connected, new camera photos and videos are copied to the paired PC.',
              ),
              value: model.settings.cameraBackup,
              onChanged: (value) => model.updateSettings(
                model.settings.copyWith(cameraBackup: value),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const AppText('PC videos on mobile data'),
              subtitle: const AppText(
                'Plays a smaller copy made by your PC. Needs FFmpeg on the PC; Wi-Fi always plays the original.',
              ),
              trailing: DropdownButton<int>(
                value: model.settings.mobileVideoQuality,
                onChanged: (value) => model.updateSettings(
                  model.settings.copyWith(mobileVideoQuality: value),
                ),
                items: const [
                  DropdownMenuItem(value: 360, child: AppText('360p')),
                  DropdownMenuItem(value: 720, child: AppText('720p')),
                  DropdownMenuItem(value: 0, child: AppText('Original')),
                ],
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const AppText('Continue transfers when the app is closed'),
              subtitle: const AppText(
                'Android schedules the remaining transfers and shows a notification while they run.',
              ),
              value: model.settings.backgroundTransfers,
              onChanged: (value) => model.updateSettings(
                model.settings.copyWith(backgroundTransfers: value),
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const AppText('Back up the camera in the background'),
              subtitle: const AppText(
                'Uses your paired PC and existing folder permissions. Android may delay work to save battery.',
              ),
              value: model.settings.backgroundBackup,
              onChanged: !model.settings.cameraBackup
                  ? null
                  : (value) => model.updateSettings(
                      model.settings.copyWith(backgroundBackup: value),
                    ),
            ),
            if (model.settings.backgroundBackup ||
                model.settings.backgroundTransfers)
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const AppText('Background work only while charging'),
                value: model.settings.backupOnlyWhileCharging,
                onChanged: (value) => model.updateSettings(
                  model.settings.copyWith(backupOnlyWhileCharging: value),
                ),
              ),
            if (model.settings.backgroundBackup)
              DropdownButtonFormField<int>(
                initialValue: model.settings.backupIntervalMinutes,
                decoration: InputDecoration(
                  labelText: context.tr('Background backup frequency'),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 15,
                    child: AppText('About every 15 minutes'),
                  ),
                  DropdownMenuItem(
                    value: 60,
                    child: AppText('About every hour'),
                  ),
                  DropdownMenuItem(
                    value: 360,
                    child: AppText('About every 6 hours'),
                  ),
                ],
                onChanged: (value) => model.updateSettings(
                  model.settings.copyWith(backupIntervalMinutes: value),
                ),
              ),
          ],
          if (model is GalleryOrganizer) ...[
            const SizedBox(height: 24),
            AppText(
              'Backup and restore',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            _OrganizationBackup(organizer: model as GalleryOrganizer),
          ],
          const SizedBox(height: 24),
          AppText('App updates', style: Theme.of(context).textTheme.titleLarge),
          _AppUpdates(model: model),
          const SizedBox(height: 24),
          AppText('Privacy', style: Theme.of(context).textTheme.titleLarge),
          if (model case final CatalogSecurity security)
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const AppText('Encrypt catalogue on this device'),
              subtitle: const AppText(
                'Encrypts photo metadata and albums with a key protected by your device. Originals, thumbnails and separate analysis caches keep their existing protection. Back up your organization before clearing app data.',
              ),
              value: security.catalogueEncrypted,
              onChanged: (enabled) async {
                try {
                  await security.setCatalogueEncryption(enabled);
                } catch (error) {
                  if (context.mounted) {
                    showMessage(context, friendlyError(error));
                  }
                }
              },
            ),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.shield_outlined),
            title: AppText('Local library'),
            subtitle: AppText(
              'Your library, albums, settings and playback positions stay on this device. Remote access is configured separately.',
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.article_outlined),
            title: const AppText('Open-source licenses and data sources'),
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
        title: const AppText('Export albums and favorites'),
        subtitle: const AppText('Encrypted with your password'),
        onTap: () => _run(_export),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        enabled: !_busy,
        leading: const Icon(Icons.settings_backup_restore_rounded),
        title: const AppText('Restore from a backup'),
        subtitle: const AppText('Matches items that are still on this device'),
        onTap: () => _run(_import),
      ),
      if (_busy) const LinearProgressIndicator(),
    ],
  );
}

/// The installed build, automatic checks and a manual check.
class _AppUpdates extends StatelessWidget {
  const _AppUpdates({required this.model});

  final GalleryModel model;

  @override
  Widget build(BuildContext context) {
    final updater = AppUpdater.instance;
    final version = appBuild == 0
        ? 'nexGallery $appVersion · development build'
        : 'nexGallery $appVersion (build $appBuild)';
    if (updater == null) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.info_outline_rounded),
        title: Text(version),
        subtitle: const AppText(
          'Builds published on GitHub update themselves. This build does not check for updates.',
        ),
      );
    }
    return AnimatedBuilder(
      animation: updater,
      builder: (context, _) {
        final release = updater.release;
        final status = switch (updater.status) {
          UpdateStatus.checking => 'Checking GitHub…',
          UpdateStatus.upToDate => 'You have the latest build.',
          UpdateStatus.available => '${release!.label} is available.',
          UpdateStatus.downloading =>
            'Downloading ${(updater.progress * 100).round()}%',
          UpdateStatus.ready => '${release!.label} is ready to install.',
          UpdateStatus.installing => 'Installing…',
          UpdateStatus.failed => updater.error ?? 'The check failed.',
          UpdateStatus.idle => 'Not checked yet.',
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.system_update_rounded),
              title: Text(version),
              subtitle: Text(status),
              trailing: switch (updater.status) {
                UpdateStatus.available || UpdateStatus.failed
                    when updater.release != null &&
                        updater.release!.build > appBuild =>
                  FilledButton(
                    onPressed: updater.download,
                    child: const AppText('Download'),
                  ),
                UpdateStatus.ready => FilledButton(
                  onPressed: updater.install,
                  child: const AppText('Install'),
                ),
                UpdateStatus.checking ||
                UpdateStatus.downloading ||
                UpdateStatus.installing => const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                _ => OutlinedButton(
                  onPressed: () => updater.check(userInitiated: true),
                  child: const AppText('Check now'),
                ),
              },
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const AppText('Check for updates automatically'),
              subtitle: const AppText(
                'When nexGallery starts, it asks GitHub for a newer build. Nothing about your photos is sent.',
              ),
              value: model.settings.checkForUpdates,
              onChanged: (value) => model.updateSettings(
                model.settings.copyWith(checkForUpdates: value),
              ),
            ),
          ],
        );
      },
    );
  }
}
