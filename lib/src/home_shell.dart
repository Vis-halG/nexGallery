import 'package:flutter/material.dart';

class NexGalleryHome extends StatefulWidget {
  const NexGalleryHome({super.key});

  @override
  State<NexGalleryHome> createState() => _NexGalleryHomeState();
}

class _NexGalleryHomeState extends State<NexGalleryHome> {
  var _index = 0;

  static const _destinations = <NavigationDestination>[
    NavigationDestination(
      icon: Icon(Icons.photo_library_outlined),
      selectedIcon: Icon(Icons.photo_library_rounded),
      label: 'Photos',
    ),
    NavigationDestination(
      icon: Icon(Icons.auto_awesome_outlined),
      selectedIcon: Icon(Icons.auto_awesome_rounded),
      label: 'Library',
    ),
    NavigationDestination(
      icon: Icon(Icons.computer_outlined),
      selectedIcon: Icon(Icons.computer_rounded),
      label: 'My PC',
    ),
    NavigationDestination(
      icon: Icon(Icons.folder_outlined),
      selectedIcon: Icon(Icons.folder_rounded),
      label: 'Files',
    ),
  ];

  static const _pages = <Widget>[
    _ProjectPage(
      title: 'Photos on this phone',
      subtitle: 'Private timeline, albums and memories — processed locally.',
      icon: Icons.photo_library_rounded,
      features: [
        'Day, month and year timeline',
        'Photos, videos, favorites, archive and trash',
        'On-device thumbnails and incremental indexing',
      ],
    ),
    _ProjectPage(
      title: 'Smart local library',
      subtitle: 'Face groups, OCR and visual search without cloud storage.',
      icon: Icons.auto_awesome_rounded,
      features: [
        'People and face grouping',
        'Object, scene and document search',
        'Duplicates, screenshots and storage cleanup',
      ],
    ),
    _ProjectPage(
      title: 'Your PC, anywhere',
      subtitle: 'Encrypted access to folders you explicitly allow.',
      icon: Icons.computer_rounded,
      features: [
        'QR device pairing and per-folder permissions',
        'Remote search, photo and video streaming',
        'Resumable phone-to-PC and PC-to-phone transfers',
      ],
    ),
    _ProjectPage(
      title: 'All your files',
      subtitle: 'A clear Phone / PC badge keeps every source understandable.',
      icon: Icons.folder_rounded,
      features: [
        'Documents, audio, APKs, archives and folders',
        'Copy, move, rename, ZIP and recoverable delete',
        'Read-only by default for remotely paired devices',
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final content = IndexedStack(index: _index, children: _pages);
    if (width >= 760) {
      return Scaffold(
        body: Row(
          children: [
            SafeArea(
              child: NavigationRail(
                extended: width >= 1050,
                selectedIndex: _index,
                onDestinationSelected: _select,
                leading: const Padding(
                  padding: EdgeInsets.fromLTRB(12, 20, 12, 28),
                  child: _Brand(compact: true),
                ),
                destinations: [
                  for (final destination in _destinations)
                    NavigationRailDestination(
                      icon: destination.icon,
                      selectedIcon: destination.selectedIcon,
                      label: Text(destination.label),
                    ),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: content),
          ],
        ),
      );
    }
    return Scaffold(
      body: content,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _select,
        destinations: _destinations,
      ),
    );
  }

  void _select(int value) => setState(() => _index = value);
}

class _ProjectPage extends StatelessWidget {
  const _ProjectPage({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.features,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final List<String> features;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(24, 22, 24, 10),
              child: _Brand(),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 36),
            sliver: SliverList.list(
              children: [
                Icon(icon, size: 54, color: scheme.primary),
                const SizedBox(height: 20),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 28),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (final feature in features)
                        ListTile(
                          leading: Icon(
                            Icons.check_circle_outline_rounded,
                            color: scheme.primary,
                          ),
                          title: Text(feature),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Card(
                  color: scheme.primaryContainer,
                  child: const Padding(
                    padding: EdgeInsets.all(20),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.construction_rounded),
                        SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            'Foundation build: implementation order, privacy '
                            'boundaries and device support are documented in '
                            'docs/NEXGALLERY_PRODUCT_AND_BUILD_PLAN.md.',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.auto_awesome_mosaic_rounded,
          color: Theme.of(context).colorScheme.primary,
          size: compact ? 28 : 32,
        ),
        if (!compact) ...[
          const SizedBox(width: 10),
          Text(
            'nexGallery',
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
        ],
      ],
    );
  }
}
