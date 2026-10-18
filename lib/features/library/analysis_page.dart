import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/media_item.dart';
import '../../data/device/device_bridge.dart';
import '../../services/intelligence/local_analysis.dart';
import '../../services/intelligence/model_pack.dart';
import '../../services/intelligence/similarity.dart';
import '../../src/gallery_model.dart';
import '../../src/gallery_organizer.dart';
import '../../src/gallery_tools.dart';
import '../common/dialogs.dart';
import '../common/media_tile.dart';
import '../photos/media_viewer.dart';

enum AnalysisKind { people, places, cleanup, search }

class AnalysisPage extends StatefulWidget {
  const AnalysisPage({
    required this.kind,
    required this.model,
    required this.tools,
    this.onSearch,
    super.key,
  });
  final AnalysisKind kind;
  final GalleryModel model;
  final GalleryTools tools;

  /// Shows the timeline filtered by a label, text or place.
  final ValueChanged<String>? onSearch;
  @override
  State<AnalysisPage> createState() => _AnalysisPageState();
}

class _AnalysisPageState extends State<AnalysisPage> {
  LocalAnalysis? _analysis;
  bool _busy = false;
  String? _error;
  String _status = '';
  List<List<MediaItem>> _duplicates = [];
  List<List<MediaItem>> _similar = [];
  bool _labelsInstalled = false, _textInstalled = false;

  @override
  void initState() {
    super.initState();
    _run(() async {
      final directory = await widget.tools.toolsDirectory();
      final analysis = LocalAnalysis(
        Directory('${directory.path}/analysis'),
        widget.tools,
        widget.model,
        pauseCheck: () async =>
            (await DeviceBridge.instance.conditions()).pauseReason(
              requireCharging: widget.model.settings.analyzeOnlyWhileCharging,
            ),
      );
      await analysis.load();
      _analysis = analysis;
      await _refreshPacks();
    });
  }

  Future<void> _refreshPacks() async {
    final analysis = _analysis;
    if (analysis == null) return;
    final labels = await analysis.labels.pack.installed();
    final text = await analysis.text.pack.installed();
    if (mounted) {
      setState(() {
        _labelsInstalled = labels;
        _textInstalled = text;
      });
    }
  }

  @override
  void dispose() {
    if (_analysis != null) _analysis!.cancelled = true;
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on AnalysisPaused catch (paused) {
      if (mounted) {
        setState(
          () => _error =
              'Paused: ${paused.reason} Progress is saved; scan again later.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '';
        });
      }
    }
  }

  void _progress(int done, int total) {
    if (mounted) setState(() => _status = '$done / $total files');
  }

  /// Asks before downloading an optional model pack.
  Future<bool> _ensurePack(
    ModelPack pack,
    String title,
    String description,
  ) async {
    if (await pack.installed()) return true;
    if (!mounted) return false;
    final accepted = await confirmAction(
      context,
      title: title,
      message:
          '$description Download about ${(pack.totalBytes / (1024 * 1024)).round()} MB once. Photos are processed and stored only on this device.',
      action: 'Download',
    );
    if (!accepted) return false;
    final analysis = _analysis!..cancelled = false;
    await pack.install((done, total) {
      if (mounted) {
        setState(
          () => _status =
              'Downloading: ${(done / (1024 * 1024)).toStringAsFixed(1)} of ${(total / (1024 * 1024)).toStringAsFixed(1)} MB',
        );
      }
    }, shouldStop: () => analysis.cancelled);
    await _refreshPacks();
    return true;
  }

  Future<void> _scan() => _run(() async {
    final analysis = _analysis!;
    switch (widget.kind) {
      case AnalysisKind.people:
        analysis.cancelled = false;
        if (!await analysis.engine.installed()) {
          if (!mounted) return;
          final accepted = await confirmAction(
            context,
            title: 'Download face models?',
            message: 'Download about 39 MB of OpenCV face models. Photos and face groups are processed and stored on this device. Groups can be wrong; you can rename, merge or separate them.',
            action: 'Download',
          );
          if (!accepted) return;
          await analysis.engine.install((done, total) {
            if (mounted) {
              setState(
                () => _status = 'Downloading models: $done / $total bytes',
              );
            }
          }, shouldStop: () => analysis.cancelled);
        }
        await analysis.scanPeople(_progress);
      case AnalysisKind.places:
        await analysis.scanPlaces(_progress);
      case AnalysisKind.cleanup:
        _duplicates = await analysis.duplicates(_progress);
      case AnalysisKind.search:
        break;
    }
  });

  Future<void> _scanSimilar() => _run(() async {
    _similar = await _analysis!.similar(_progress);
  });

  Future<void> _scanLabels() => _run(() async {
    final analysis = _analysis!;
    if (!await _ensurePack(
      analysis.labels.pack,
      'Download the objects and scenes pack?',
      'Recognizes things like dogs, food, beaches and documents so you can search for them.',
    )) {
      return;
    }
    await analysis.scanLabels(_progress);
  });

  Future<void> _scanText() => _run(() async {
    final analysis = _analysis!;
    if (!await _ensurePack(
      analysis.text.pack,
      'Download the text recognition pack?',
      'Reads printed English text in photos such as signs, receipts and screenshots so you can search for it.',
    )) {
      return;
    }
    await analysis.scanText(_progress);
  });

  Future<void> _showItems(
    String title,
    List<MediaItem> items, {
    bool cleanup = false,
    String? person,
    MediaItem? best,
  }) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => _AnalysisItems(
          title: title,
          model: widget.model,
          items: items,
          cleanup: cleanup,
          best: best,
          separate: person == null
              ? null
              : (item) async {
                  final faces = _analysis!.faces
                      .where((v) => v.personId == person && v.itemId == item.id)
                      .toList();
                  for (final face in faces) {
                    await _analysis!.split(face);
                  }
                },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _personAction(String id, String action) async {
    if (action == 'rename') {
      final name = await promptText(
        context,
        title: 'Name this person',
        label: 'Name',
        initialValue: _analysis!.names[id] ?? '',
        maxLength: 80,
      );
      if (name != null && mounted) {
        await _run(() => _analysis!.namePerson(id, name));
      }
    } else {
      final available = {for (final item in _analysis!.items) item.id};
      final others = _analysis!.faces
          .where((v) => v.personId != id && available.contains(v.itemId))
          .map((v) => v.personId)
          .toSet();
      final target = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Merge into person'),
          children: [
            for (final other in others)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, other),
                child: Text(
                  _analysis!.names[other]?.isNotEmpty == true
                      ? _analysis!.names[other]!
                      : 'Unnamed ${other.substring(0, 6)}',
                ),
              ),
          ],
        ),
      );
      if (target != null && mounted) {
        await _run(() => _analysis!.merge(id, target));
      }
    }
  }

  Future<void> _keepBest(List<MediaItem> group) async {
    final keep = bestShot(group);
    final others = group.where((item) => item.id != keep.id).toList();
    final confirmed = await confirmAction(
      context,
      title: 'Keep the best shot?',
      message:
          'Keep ${keep.name} and move ${others.length} similar photos to Trash. You can restore them from Trash.',
      action: 'Move to Trash',
    );
    if (!confirmed || !mounted) return;
    await _run(() async {
      final model = widget.model;
      if (model is GalleryOrganizer) {
        await (model as GalleryOrganizer).moveAllToTrash(others);
      } else {
        for (final item in others) {
          await model.moveToTrash(item);
        }
      }
      _similar = _similar.where((g) => !identical(g, group)).toList();
    });
  }

  void _search(String query) {
    final onSearch = widget.onSearch;
    if (onSearch == null) return;
    Navigator.pop(context);
    onSearch(query);
  }

  String get _title => switch (widget.kind) {
    AnalysisKind.people => 'People',
    AnalysisKind.places => 'Places',
    AnalysisKind.cleanup => 'Cleanup',
    AnalysisKind.search => 'Smart search',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_title),
      actions: [
        if (widget.kind == AnalysisKind.people && _analysis != null)
          IconButton(
            tooltip: 'Clear face groups',
            onPressed: _busy
                ? null
                : () async {
                    final accepted = await confirmAction(
                      context,
                      title: 'Clear face groups?',
                      message: 'Remove saved face groups and names. Your photos remain in the gallery.',
                      action: 'Clear',
                    );
                    if (accepted && mounted) {
                      await _run(() => _analysis!.reset());
                    }
                  },
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        if (widget.kind == AnalysisKind.search && _analysis != null)
          PopupMenuButton<String>(
            tooltip: 'Search index options',
            enabled: !_busy,
            onSelected: (value) => _run(() async {
              final analysis = _analysis!;
              if (value == 'clear') {
                await analysis.resetSearchIndex();
              } else {
                await analysis.labels.pack.remove();
                await analysis.text.pack.remove();
                await _refreshPacks();
              }
            }),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'clear',
                child: Text('Clear labels and text index'),
              ),
              PopupMenuItem(
                value: 'remove',
                child: Text('Delete downloaded packs'),
              ),
            ],
          ),
      ],
    ),
    body: AnimatedBuilder(
      animation: widget.model,
      builder: (context, _) {
        final analysis = _analysis;
        final items = analysis?.items ?? <MediaItem>[];
        final byId = {for (final item in items) item.id: item};
        final groups = <String, List<MediaItem>>{};
        if (widget.kind == AnalysisKind.people && analysis != null) {
          for (final face in analysis.faces) {
            final item = byId[face.itemId];
            if (item != null &&
                !(groups[face.personId] ?? []).any((v) => v.id == item.id)) {
              (groups[face.personId] ??= []).add(item);
            }
          }
        } else if (widget.kind == AnalysisKind.places) {
          for (final item in items) {
            final lat = item.metadata.latitude, lon = item.metadata.longitude;
            final place = item.metadata.attributes['analysis.place'];
            if (place != null && place.isNotEmpty) {
              (groups[place] ??= []).add(item);
            } else if (lat != null && lon != null) {
              (groups['${lat.toStringAsFixed(2)}, ${lon.toStringAsFixed(2)}'] ??=
                      [])
                  .add(item);
            }
          }
        }
        final sortedGroups = groups.entries.toList()
          ..sort((a, b) => b.value.length.compareTo(a.value.length));
        final large =
            items
                .where((v) => v.metadata.sizeBytes >= 100 * 1024 * 1024)
                .toList()
              ..sort(
                (a, b) => b.metadata.sizeBytes.compareTo(a.metadata.sizeBytes),
              );
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(switch (widget.kind) {
              AnalysisKind.people => 'Find faces locally, then review and name the groups. Photos are never sent to the model host.',
              AnalysisKind.places => 'Group photos by their embedded GPS coordinates and name the nearest city using a built-in offline map database. Photos without a location are omitted. Android may redact location metadata according to your permissions.',
              AnalysisKind.cleanup => 'Find exact duplicates by file contents, look-alike shots and large files. Choose what to move to Trash.',
              AnalysisKind.search => 'Make photos searchable by what is in them and by the text they contain. Everything is analyzed on this device; results appear in the search bar of your timeline.',
            }),
            const SizedBox(height: 16),
            if (widget.kind != AnalysisKind.search)
              FilledButton.icon(
                onPressed: analysis == null || _busy ? null : _scan,
                icon: const Icon(Icons.search),
                label: Text(
                  widget.kind == AnalysisKind.cleanup
                      ? 'Scan exact duplicates'
                      : 'Scan photos',
                ),
              ),
            if (_busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              Text(_status),
              TextButton(
                onPressed: analysis == null
                    ? null
                    : () {
                        analysis.cancelled = true;
                        setState(
                          () => _status = 'Stopping after the current file…',
                        );
                      },
                child: const Text('Stop scan'),
              ),
            ],
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (widget.kind == AnalysisKind.search && analysis != null)
              ..._searchSection(context, items),
            if ((widget.kind == AnalysisKind.people ||
                    widget.kind == AnalysisKind.places) &&
                !_busy &&
                groups.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No groups yet. Run a scan to find photos.'),
              ),
            for (final entry in sortedGroups)
              Card(
                child: ListTile(
                  leading: SizedBox(
                    width: 56,
                    height: 56,
                    child: MediaThumbnail(
                      item: entry.value.first,
                      model: widget.model,
                    ),
                  ),
                  title: Text(
                    widget.kind == AnalysisKind.people
                        ? (analysis!.names[entry.key]?.isNotEmpty == true
                              ? analysis.names[entry.key]!
                              : 'Unnamed ${entry.key.substring(0, 6)}')
                        : entry.key,
                  ),
                  subtitle: Text('${entry.value.length} photos'),
                  onTap: () => _showItems(
                    widget.kind == AnalysisKind.people
                        ? analysis!.names[entry.key] ?? 'Person'
                        : entry.key,
                    entry.value,
                    person: widget.kind == AnalysisKind.people
                        ? entry.key
                        : null,
                  ),
                  trailing: widget.kind != AnalysisKind.people
                      ? const Icon(Icons.chevron_right)
                      : PopupMenuButton<String>(
                          enabled: !_busy,
                          onSelected: (v) => _personAction(entry.key, v),
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'rename',
                              child: Text('Name person'),
                            ),
                            PopupMenuItem(
                              value: 'merge',
                              child: Text('Merge group'),
                            ),
                          ],
                        ),
                ),
              ),
            if (widget.kind == AnalysisKind.cleanup) ...[
              const SizedBox(height: 16),
              Text(
                'Exact duplicates',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              for (final group in _duplicates)
                if (group.where((v) => byId.containsKey(v.id)).length > 1)
                  ListTile(
                    title: Text('${group.length} copies · ${group.first.name}'),
                    subtitle: Text(
                      '${formatBytes(group.first.metadata.sizeBytes)} each',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showItems(
                      'Review duplicate copies',
                      group.where((v) => byId.containsKey(v.id)).toList(),
                      cleanup: true,
                    ),
                  ),
              if (!_busy && _duplicates.isEmpty)
                const Text('No duplicate results. Run a scan to check.'),
              const SizedBox(height: 24),
              Text(
                'Similar photos',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Text(
                'Bursts and look-alike shots. The suggested best shot is kept.',
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: analysis == null || _busy ? null : _scanSimilar,
                icon: const Icon(Icons.burst_mode_outlined),
                label: const Text('Find similar photos'),
              ),
              for (final group in _similar)
                if (group.where((v) => byId.containsKey(v.id)).length > 1)
                  _SimilarGroupTile(
                    model: widget.model,
                    group: group.where((v) => byId.containsKey(v.id)).toList(),
                    onOpen: (group) => _showItems(
                      'Similar photos',
                      group,
                      cleanup: true,
                      best: bestShot(group),
                    ),
                    onKeepBest: _busy ? null : _keepBest,
                  ),
              const SizedBox(height: 24),
              Text(
                'Large files (100 MB or more)',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              for (final item in large)
                ListTile(
                  title: Text(item.name),
                  subtitle: Text(formatBytes(item.metadata.sizeBytes)),
                  onTap: () =>
                      _showItems('Review large file', [item], cleanup: true),
                ),
              if (large.isEmpty)
                const Text('No large files in the accessible gallery.'),
            ],
          ],
        );
      },
    ),
  );

  List<Widget> _searchSection(BuildContext context, List<MediaItem> items) {
    final counts = <String, int>{};
    var withText = 0;
    for (final item in items) {
      final labels = item.metadata.attributes['analysis.labels'] ?? '';
      for (final label in labels.split(',').map((v) => v.trim())) {
        if (label.isNotEmpty) counts[label] = (counts[label] ?? 0) + 1;
      }
      if ((item.metadata.attributes['analysis.text'] ?? '').isNotEmpty) {
        withText++;
      }
    }
    final top = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      Card(
        child: ListTile(
          leading: const Icon(Icons.category_outlined),
          title: const Text('Objects and scenes'),
          subtitle: Text(
            _labelsInstalled
                ? 'Pack installed · ${counts.isEmpty ? 'not scanned yet' : '${counts.length} kinds found'}'
                : 'Optional 14 MB pack',
          ),
          trailing: FilledButton.tonal(
            onPressed: _busy ? null : _scanLabels,
            child: Text(_labelsInstalled ? 'Scan' : 'Get pack'),
          ),
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.text_fields_rounded),
          title: const Text('Text in photos'),
          subtitle: Text(
            _textInstalled
                ? 'Pack installed · $withText photos with text'
                : 'Optional 11 MB pack, English text',
          ),
          trailing: FilledButton.tonal(
            onPressed: _busy ? null : _scanText,
            child: Text(_textInstalled ? 'Scan' : 'Get pack'),
          ),
        ),
      ),
      if (top.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(
          'Found in your photos',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in top.take(30))
              ActionChip(
                label: Text('${entry.key} · ${entry.value}'),
                onPressed: widget.onSearch == null
                    ? null
                    : () => _search(entry.key),
              ),
          ],
        ),
      ],
      const SizedBox(height: 16),
      const Text(
        'Labels and text can be wrong. They are used only for search on this device and can be cleared from the menu.',
      ),
    ];
  }
}

class _SimilarGroupTile extends StatelessWidget {
  const _SimilarGroupTile({
    required this.model,
    required this.group,
    required this.onOpen,
    required this.onKeepBest,
  });

  final GalleryModel model;
  final List<MediaItem> group;
  final ValueChanged<List<MediaItem>> onOpen;
  final ValueChanged<List<MediaItem>>? onKeepBest;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 72,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final item in group.take(8))
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox.square(
                        dimension: 72,
                        child: MediaThumbnail(item: item, model: model),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Row(
            children: [
              Expanded(child: Text('${group.length} similar photos')),
              TextButton(
                onPressed: () => onOpen(group),
                child: const Text('Review'),
              ),
              TextButton(
                onPressed: onKeepBest == null ? null : () => onKeepBest!(group),
                child: const Text('Keep best'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _AnalysisItems extends StatefulWidget {
  const _AnalysisItems({
    required this.title,
    required this.model,
    required this.items,
    this.cleanup = false,
    this.separate,
    this.best,
  });
  final String title;
  final GalleryModel model;
  final List<MediaItem> items;
  final bool cleanup;
  final Future<void> Function(MediaItem)? separate;
  final MediaItem? best;
  @override
  State<_AnalysisItems> createState() => _AnalysisItemsState();
}

class _AnalysisItemsState extends State<_AnalysisItems> {
  final _removed = <String>{};
  bool _busy = false;
  Future<void> _act(MediaItem item) async {
    if (_busy) return;
    final confirmed = await confirmAction(
      context,
      title: widget.cleanup
          ? 'Move this file to Trash?'
          : 'Separate this face?',
      message: item.name,
      action: widget.cleanup ? 'Move to Trash' : 'Separate',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      if (widget.cleanup) {
        if (await widget.model.moveToTrash(item)) _removed.add(item.id);
      } else {
        await widget.separate!(item);
        _removed.add(item.id);
      }
    } catch (e) {
      if (mounted) showMessage(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: AnimatedBuilder(
      animation: widget.model,
      builder: (context, _) {
        final items = widget.items
            .where(
              (v) => !_removed.contains(v.id) && widget.model.canAccessMedia(v),
            )
            .toList();
        return ListView(
          children: [
            if (_busy) const LinearProgressIndicator(),
            for (final item in items)
              ListTile(
                leading: SizedBox(
                  width: 64,
                  height: 64,
                  child: MediaThumbnail(item: item, model: widget.model),
                ),
                title: Text(item.name),
                subtitle: Text(
                  [
                    if (item.id == widget.best?.id) 'Suggested best shot',
                    item.relativePath,
                    formatBytes(item.metadata.sizeBytes),
                  ].join(' · '),
                ),
                onTap: () =>
                    item.kind == MediaKind.image || item.kind == MediaKind.video
                    ? Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => MediaViewer(
                            model: widget.model,
                            items: items,
                            initialIndex: items.indexOf(item),
                          ),
                        ),
                      )
                    : widget.model.open(item),
                trailing: widget.cleanup || widget.separate != null
                    ? IconButton(
                        tooltip: widget.cleanup
                            ? 'Move to Trash'
                            : 'Separate face',
                        onPressed: _busy ? null : () => _act(item),
                        icon: Icon(
                          widget.cleanup
                              ? Icons.delete_outline
                              : Icons.person_remove_outlined,
                        ),
                      )
                    : null,
              ),
          ],
        );
      },
    ),
  );
}
