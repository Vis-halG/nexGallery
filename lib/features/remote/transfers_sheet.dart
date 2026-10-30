import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../../services/remote/transfer_queue.dart';
import '../common/dialogs.dart';

Future<void> showTransfers(BuildContext context, TransferQueue queue) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => TransfersSheet(queue: queue),
    );

/// Live list of uploads and downloads with pause, resume, cancel and
/// conflict choices.
class TransfersSheet extends StatelessWidget {
  const TransfersSheet({required this.queue, super.key});

  final TransferQueue queue;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      child: AnimatedBuilder(
        animation: queue,
        builder: (context, _) {
          final jobs = queue.jobs.reversed.toList();
          final active = jobs.where((job) => !job.isFinished).length;
          return ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: AppText(
                      'Transfers',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (active > 0) ...[
                    TextButton(
                      onPressed: queue.canMutate ? queue.pauseAll : null,
                      child: const AppText('Pause all'),
                    ),
                    TextButton(
                      onPressed: queue.canMutate ? queue.resumeAll : null,
                      child: const AppText('Resume all'),
                    ),
                  ],
                  if (jobs.any((job) => job.isFinished))
                    TextButton(
                      onPressed: queue.canMutate ? queue.clearFinished : null,
                      child: const AppText('Clear finished'),
                    ),
                ],
              ),
              if (queue.waitingReason case final reason?)
                Card(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.wifi_off_rounded),
                    title: Text(reason),
                  ),
                ),
              if (jobs.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: AppText(
                    'No transfers. Uploads, camera backup and offline copies appear here and resume automatically after interruptions.',
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final job in jobs) _TransferTile(queue: queue, job: job),
            ],
          );
        },
      ),
    ),
  );
}

class _TransferTile extends StatelessWidget {
  const _TransferTile({required this.queue, required this.job});

  final TransferQueue queue;
  final TransferJob job;

  @override
  Widget build(BuildContext context) {
    final upload = job.kind == TransferKind.upload;
    final scheme = Theme.of(context).colorScheme;
    final status = switch (job.status) {
      TransferStatus.queued => job.error ?? 'Waiting',
      TransferStatus.running =>
        '${formatBytes(job.done)}${job.total == null ? '' : ' of ${formatBytes(job.total!)}'}',
      TransferStatus.paused => 'Paused at ${formatBytes(job.done)}',
      TransferStatus.conflict => job.error ?? 'Already on the PC',
      TransferStatus.failed => job.error ?? 'Failed',
      TransferStatus.done => job.note ?? (upload ? 'Uploaded' : 'Downloaded'),
      TransferStatus.skipped => 'Skipped; already on the PC',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  upload ? Icons.upload_rounded : Icons.download_rounded,
                  color: job.status == TransferStatus.failed
                      ? scheme.error
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        job.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        upload ? 'To PC: ${job.remotePath}' : 'From PC',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Text(
                        status,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (job.status == TransferStatus.running ||
                    job.status == TransferStatus.queued)
                  IconButton(
                    tooltip: context.tr('Pause'),
                    onPressed: queue.canMutate
                        ? () => queue.pause(job.id)
                        : null,
                    icon: const Icon(Icons.pause_rounded),
                  ),
                if (job.status == TransferStatus.paused ||
                    job.status == TransferStatus.failed)
                  IconButton(
                    tooltip: job.status == TransferStatus.failed
                        ? 'Retry'
                        : 'Resume',
                    onPressed: queue.canMutate
                        ? () => queue.resume(job.id)
                        : null,
                    icon: Icon(
                      job.status == TransferStatus.failed
                          ? Icons.refresh_rounded
                          : Icons.play_arrow_rounded,
                    ),
                  ),
                if (!job.isFinished)
                  IconButton(
                    tooltip: context.tr('Cancel'),
                    onPressed: queue.canMutate
                        ? () => queue.cancel(job.id)
                        : null,
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
            if (job.status == TransferStatus.running ||
                job.status == TransferStatus.paused)
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: LinearProgressIndicator(value: job.progress),
              ),
            if (job.status == TransferStatus.conflict)
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: queue.canMutate
                        ? () => queue.resolveConflict(
                            job.id,
                            ConflictPolicy.keepBoth,
                          )
                        : null,
                    child: const AppText('Keep both'),
                  ),
                  TextButton(
                    onPressed: queue.canMutate
                        ? () => queue.resolveConflict(
                            job.id,
                            ConflictPolicy.replace,
                          )
                        : null,
                    child: const AppText('Replace'),
                  ),
                  TextButton(
                    onPressed: queue.canMutate
                        ? () =>
                              queue.resolveConflict(job.id, ConflictPolicy.skip)
                        : null,
                    child: const AppText('Skip'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
