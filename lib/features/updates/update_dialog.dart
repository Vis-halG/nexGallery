import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../services/updates/app_update.dart';

/// Shown once for a newly offered build, with download progress and retry.
Future<void> showUpdateDialog(BuildContext context, AppUpdater updater) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AnimatedBuilder(
        animation: updater,
        builder: (context, _) {
          final busy =
              updater.status == UpdateStatus.downloading ||
              updater.status == UpdateStatus.installing;
          return PopScope(
            canPop: !busy,
            child: AlertDialog(
              title: const AppText('Update available'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('nexGallery ${updater.release?.label ?? ''}'),
                    const SizedBox(height: 12),
                    AppText(
                      updater.isAndroid
                          ? 'Download and install the latest version. Android will ask you to confirm installation.'
                          : 'Download the latest version. nexGallery will close and reopen after the update.',
                    ),
                    if (updater.release?.notes.isNotEmpty == true) ...[
                      const SizedBox(height: 12),
                      Text(
                        updater.release!.notes,
                        maxLines: 8,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (busy) ...[
                      const SizedBox(height: 16),
                      LinearProgressIndicator(
                        value: updater.status == UpdateStatus.downloading
                            ? updater.progress
                            : null,
                      ),
                      Text('${(updater.progress * 100).round()}%'),
                    ],
                    if (updater.error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        updater.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: busy
                      ? null
                      : () {
                          updater.dismiss();
                          Navigator.pop(context);
                        },
                  child: const AppText('Later'),
                ),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () async {
                          await updater.updateNow();
                          if (context.mounted &&
                              updater.status != UpdateStatus.failed) {
                            Navigator.pop(context);
                          }
                        },
                  child: AppText(
                    updater.status == UpdateStatus.failed ? 'Retry' : 'Update',
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
