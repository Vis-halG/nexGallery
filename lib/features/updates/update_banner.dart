import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../../services/updates/app_update.dart';
import '../common/dialogs.dart';

/// Offers a newer build above every tab, from download to install.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({required this.updater, super.key});

  final AppUpdater updater;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: updater,
      builder: (context, _) {
        final release = updater.release;
        if (!updater.offering || release == null) {
          return const SizedBox.shrink();
        }
        final scheme = Theme.of(context).colorScheme;
        final (message, action, onAction) = switch (updater.status) {
          UpdateStatus.downloading => (
            'Downloading nexGallery ${release.label} · '
                '${(updater.progress * 100).round()}%',
            null,
            null,
          ),
          UpdateStatus.ready => (
            'nexGallery ${release.label} is ready to install.',
            updater.isAndroid ? 'Install' : 'Restart and update',
            updater.install,
          ),
          UpdateStatus.installing => (
            updater.isAndroid
                ? 'Finish the update in Android\'s installer.'
                : 'Updating nexGallery…',
            updater.isAndroid ? 'Install' : null,
            updater.isAndroid ? updater.install : null,
          ),
          UpdateStatus.failed => (
            'Update failed: ${updater.error ?? 'try again'}',
            'Retry',
            updater.updateNow,
          ),
          _ => (
            'nexGallery ${release.label} is available.',
            'Update',
            updater.updateNow,
          ),
        };
        return SafeArea(
          bottom: false,
          child: Material(
            color: scheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.system_update_rounded,
                        color: scheme.onPrimaryContainer,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          message,
                          style: TextStyle(color: scheme.onPrimaryContainer),
                        ),
                      ),
                      if (release.notes.isNotEmpty)
                        IconButton(
                          tooltip: context.tr('What\'s new'),
                          icon: const Icon(Icons.notes_rounded),
                          color: scheme.onPrimaryContainer,
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text('What\'s new in ${release.label}'),
                              content: SingleChildScrollView(
                                child: Text(release.notes),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const AppText('Close'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (updater.status != UpdateStatus.downloading &&
                          updater.status != UpdateStatus.installing)
                        TextButton(
                          onPressed: updater.dismiss,
                          child: const AppText('Later'),
                        ),
                      if (action != null)
                        FilledButton(
                          onPressed: () async {
                            await onAction!();
                            if (context.mounted &&
                                updater.status == UpdateStatus.failed &&
                                updater.error != null) {
                              showMessage(context, updater.error!);
                            }
                          },
                          child: AppText(action),
                        ),
                    ],
                  ),
                  if (updater.status == UpdateStatus.downloading)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, right: 8),
                      child: LinearProgressIndicator(value: updater.progress),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
