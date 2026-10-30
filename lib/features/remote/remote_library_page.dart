import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../../services/remote/nex_gallery_client.dart';
import '../common/dialogs.dart';

/// The PC catalogue complements folder browsing. Pagination is explicit so a
/// phone never downloads a 100,000-item library just to show its first screen.
class RemoteLibraryPage extends StatefulWidget {
  const RemoteLibraryPage({
    required this.client,
    required this.onOpen,
    this.album,
    this.person,
    this.title = 'PC library',
    super.key,
  });
  final NexGalleryRemoteClient client;
  final Future<void> Function(RemoteEntry) onOpen;
  final String? album, person;
  final String title;
  @override
  State<RemoteLibraryPage> createState() => _RemoteLibraryPageState();
}

class _RemoteLibraryPageState extends State<RemoteLibraryPage> {
  final _search = TextEditingController();
  final _rows = <Map<String, dynamic>>[];
  String _collection = 'timeline';
  String? _cursor, _error;
  bool _busy = false;
  int _total = 0;
  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({required bool reset}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = await widget.client.catalog(
        collection: _collection,
        cursor: reset ? null : _cursor,
        query: _search.text.trim(),
        album: widget.album,
        person: widget.person,
      );
      if (!mounted) return;
      setState(() {
        if (reset) _rows.clear();
        _rows.addAll(page.items);
        _cursor = page.nextCursor;
        _total = page.total;
      });
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(Map<String, dynamic> row) async {
    if (_collection == 'timeline') {
      try {
        await widget.onOpen(RemoteEntry.fromJson(row));
      } catch (error) {
        if (mounted) showMessage(context, friendlyError(error));
      }
    } else {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => RemoteLibraryPage(
            client: widget.client,
            onOpen: widget.onOpen,
            title: row['name'] as String,
            album: _collection == 'albums' ? row['id'] as String : null,
            person: _collection == 'people' ? row['id'] as String : null,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: widget.album == null && widget.person == null
          ? const AppText('PC library')
          : Text(widget.title),
      actions: [
        IconButton(
          tooltip: context.tr('Refresh'),
          onPressed: _busy ? null : () => _load(reset: true),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        if (widget.album == null && widget.person == null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'timeline', label: AppText('Photos')),
                ButtonSegment(value: 'albums', label: AppText('Albums')),
                ButtonSegment(value: 'people', label: AppText('People')),
              ],
              selected: {_collection},
              onSelectionChanged: _busy
                  ? null
                  : (value) {
                      setState(() => _collection = value.single);
                      _load(reset: true);
                    },
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _search,
            onSubmitted: (_) => _load(reset: true),
            decoration: InputDecoration(
              labelText: context.tr('Search PC library'),
              prefixIcon: Icon(Icons.search),
            ),
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(reset: true),
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: _rows.length + 1,
              itemBuilder: (context, index) {
                if (index == _rows.length) {
                  return Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Text('${_rows.length} / $_total'),
                        if (_cursor != null)
                          FilledButton(
                            onPressed: _busy ? null : () => _load(reset: false),
                            child: const AppText('Load more'),
                          ),
                        if (!_busy && _rows.isEmpty)
                          const AppText('No items in this view.'),
                      ],
                    ),
                  );
                }
                final row = _rows[index];
                return ListTile(
                  leading: Icon(
                    _collection == 'people'
                        ? Icons.people_outline
                        : _collection == 'albums'
                        ? Icons.photo_album_outlined
                        : row['kind'] == 'video'
                        ? Icons.movie_outlined
                        : Icons.photo_outlined,
                  ),
                  title: Text(row['name'] as String),
                  subtitle: Text(
                    _collection == 'timeline'
                        ? MaterialLocalizations.of(context).formatFullDate(
                            DateTime.parse(row['takenAt'] as String).toLocal(),
                          )
                        : '${row['count']} photos',
                  ),
                  onTap: () => _open(row),
                );
              },
            ),
          ),
        ),
      ],
    ),
  );
}
