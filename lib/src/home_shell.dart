import 'package:flutter/material.dart';

abstract final class NexBreakpoints {
  static const navigationRail = 840.0;
  static const extendedRail = 1120.0;
  static const contentMaxWidth = 880.0;

  static double pagePadding(double width) => width < 600 ? 16 : 24;
}

class NexGalleryHome extends StatefulWidget {
  const NexGalleryHome({super.key});

  @override
  State<NexGalleryHome> createState() => _NexGalleryHomeState();
}

class _NexGalleryHomeState extends State<NexGalleryHome> {
  var _index = 0;

  static const _mobileDestinations = <_DestinationSpec>[
    _DestinationSpec(
      icon: Icons.photo_library_outlined,
      selectedIcon: Icons.photo_library_rounded,
      label: 'Photos',
    ),
    _DestinationSpec(
      icon: Icons.auto_awesome_outlined,
      selectedIcon: Icons.auto_awesome_rounded,
      label: 'Library',
    ),
    _DestinationSpec(
      icon: Icons.computer_outlined,
      selectedIcon: Icons.computer_rounded,
      label: 'My PC',
    ),
    _DestinationSpec(
      icon: Icons.folder_outlined,
      selectedIcon: Icons.folder_rounded,
      label: 'Files',
    ),
  ];

  static const _desktopDestinations = <_DestinationSpec>[
    _DestinationSpec(
      icon: Icons.photo_library_outlined,
      selectedIcon: Icons.photo_library_rounded,
      label: 'This PC',
    ),
    _DestinationSpec(
      icon: Icons.auto_awesome_outlined,
      selectedIcon: Icons.auto_awesome_rounded,
      label: 'Library',
    ),
    _DestinationSpec(
      icon: Icons.dns_outlined,
      selectedIcon: Icons.dns_rounded,
      label: 'Server',
    ),
    _DestinationSpec(
      icon: Icons.folder_outlined,
      selectedIcon: Icons.folder_rounded,
      label: 'Files',
    ),
  ];

  static const _mobilePages = <Widget>[
    _ProjectPage(
      eyebrow: 'THIS PHONE',
      title: 'Your moments, kept private',
      subtitle: 'A fast local timeline for photos and videos on this phone.',
      icon: Icons.photo_library_rounded,
      features: [
        'Day, month and year timeline',
        'Favorites, archive and recoverable trash',
        'On-device thumbnails and incremental indexing',
      ],
    ),
    _ProjectPage(
      eyebrow: 'ON-DEVICE INTELLIGENCE',
      title: 'A library that understands',
      subtitle: 'Face groups, OCR and visual search without cloud storage.',
      icon: Icons.auto_awesome_rounded,
      features: [
        'People and same-face grouping',
        'Object, scene and document search',
        'Duplicates, screenshots and storage cleanup',
      ],
    ),
    _ProjectPage(
      eyebrow: 'PRIVATE REMOTE ACCESS',
      title: 'Your PC, anywhere',
      subtitle: 'Encrypted access to only the folders you explicitly allow.',
      icon: Icons.computer_rounded,
      features: [
        'QR pairing and per-folder permissions',
        'Remote search, photo and video streaming',
        'Resumable phone-to-PC and PC-to-phone transfers',
      ],
    ),
    _ProjectPage(
      eyebrow: 'PHONE + PC',
      title: 'Every file has a clear home',
      subtitle: 'Visible source badges keep local and remote files distinct.',
      icon: Icons.folder_rounded,
      features: [
        'Documents, audio, APKs, archives and folders',
        'Copy, move, rename, ZIP and recoverable delete',
        'Read-only remote access until you allow changes',
      ],
    ),
  ];

  static const _desktopPages = <Widget>[
    _ProjectPage(
      eyebrow: 'THIS PC',
      title: 'Your local media workspace',
      subtitle: 'Browse selected folders and drives without moving originals.',
      icon: Icons.photo_library_rounded,
      features: [
        'Responsive timeline and folder views',
        'External drive and removable-media awareness',
        'Local thumbnails and incremental indexing',
      ],
    ),
    _ProjectPage(
      eyebrow: 'LOCAL INTELLIGENCE',
      title: 'Search across your own library',
      subtitle: 'Private People, OCR and visual indexes stored on this PC.',
      icon: Icons.auto_awesome_rounded,
      features: [
        'People, places and smart categories',
        'Text, filename and object search',
        'Duplicate review and storage cleanup',
      ],
    ),
    _ProjectPage(
      eyebrow: 'NEXGALLERY SERVER',
      title: 'Private access for paired devices',
      subtitle:
          'Share selected roots through an authenticated private network.',
      icon: Icons.dns_rounded,
      features: [
        'Per-device and per-folder permissions',
        'Encrypted streaming and resumable transfers',
        'Connection status, audit history and one-tap revoke',
      ],
    ),
    _ProjectPage(
      eyebrow: 'AUTHORIZED ROOTS',
      title: 'Manage personal files safely',
      subtitle: 'System folders stay outside the server boundary.',
      icon: Icons.folder_rounded,
      features: [
        'Documents, media, APKs and archives',
        'Copy, move, rename, ZIP and recoverable delete',
        'Keyboard, mouse, touch and accessible focus states',
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isWindows = Theme.of(context).platform == TargetPlatform.windows;
    final destinations = isWindows ? _desktopDestinations : _mobileDestinations;
    final pages = isWindows ? _desktopPages : _mobilePages;

    // Only the active foundation page is built. Feature tabs can later add
    // their own PageStorage/Navigator state without keeping media decoders alive.
    final content = KeyedSubtree(
      key: ValueKey('${isWindows ? 'desktop' : 'mobile'}-$_index'),
      child: pages[_index],
    );

    if (width >= NexBreakpoints.navigationRail) {
      final extended = width >= NexBreakpoints.extendedRail;
      return Scaffold(
        body: Row(
          children: [
            SafeArea(
              child: NavigationRail(
                extended: extended,
                selectedIndex: _index,
                onDestinationSelected: _select,
                leading: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 20, 12, 28),
                  child: _Brand(compact: !extended),
                ),
                destinations: [
                  for (final destination in destinations)
                    NavigationRailDestination(
                      icon: Icon(destination.icon),
                      selectedIcon: Icon(destination.selectedIcon),
                      label: Text(destination.label),
                    ),
                ],
              ),
            ),
            const VerticalDivider(),
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
        destinations: [
          for (final destination in destinations)
            NavigationDestination(
              icon: Icon(destination.icon),
              selectedIcon: Icon(destination.selectedIcon),
              label: destination.label,
            ),
        ],
      ),
    );
  }

  void _select(int value) => setState(() => _index = value);
}

class _DestinationSpec {
  const _DestinationSpec({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

class _ProjectPage extends StatelessWidget {
  const _ProjectPage({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.features,
  });

  final String eyebrow;
  final String title;
  final String subtitle;
  final IconData icon;
  final List<String> features;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final padding = NexBreakpoints.pagePadding(width);
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: CustomScrollView(
        key: PageStorageKey(title),
        slivers: [
          SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: NexBreakpoints.contentMaxWidth,
                ),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(padding, 20, padding, 36),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const _TopBar(),
                      const SizedBox(height: 24),
                      _HeroCard(
                        eyebrow: eyebrow,
                        title: title,
                        subtitle: subtitle,
                        icon: icon,
                      ),
                      const SizedBox(height: 24),
                      Semantics(
                        header: true,
                        child: Text(
                          'Planned roadmap',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Card(
                        child: Column(
                          children: [
                            for (var i = 0; i < features.length; i++) ...[
                              _RoadmapRow(label: features[i]),
                              if (i != features.length - 1)
                                Divider(
                                  height: 1,
                                  indent: 64,
                                  color: scheme.outlineVariant,
                                ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      const _FoundationNotice(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    return const Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 12,
      children: [_Brand(), _PrivacyBadge()],
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String eyebrow;
  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primaryContainer, scheme.tertiaryContainer],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 560;
          final copy = Column(
            crossAxisAlignment: compact
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              Text(
                eyebrow,
                textAlign: compact ? TextAlign.center : TextAlign.start,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 10),
              Semantics(
                header: true,
                child: Text(
                  title,
                  textAlign: compact ? TextAlign.center : TextAlign.start,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w800,
                    height: 1.12,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                subtitle,
                textAlign: compact ? TextAlign.center : TextAlign.start,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: scheme.onPrimaryContainer.withValues(alpha: 0.82),
                  height: 1.45,
                ),
              ),
            ],
          );

          if (compact) {
            return Column(
              children: [
                _HeroIcon(icon: icon),
                const SizedBox(height: 20),
                copy,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: copy),
              const SizedBox(width: 28),
              _HeroIcon(icon: icon),
            ],
          );
        },
      ),
    );
  }
}

class _HeroIcon extends StatelessWidget {
  const _HeroIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 88,
      height: 88,
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.72),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 44, color: scheme.primary),
    );
  }
}

class _RoadmapRow extends StatelessWidget {
  const _RoadmapRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(Icons.schedule_rounded, color: scheme.primary),
          const SizedBox(width: 16),
          Expanded(child: Text(label)),
          const SizedBox(width: 8),
          const _StatusPill(label: 'PLANNED'),
        ],
      ),
    );
  }
}

class _FoundationNotice extends StatelessWidget {
  const _FoundationNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest,
      child: const Padding(
        padding: EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.construction_rounded),
            SizedBox(width: 14),
            Expanded(
              child: Text(
                'Preview build · These features are planned and being built. '
                'This foundation does not scan or upload your files.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrivacyBadge extends StatelessWidget {
  const _PrivacyBadge();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Privacy status: local first',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.shield_outlined,
              size: 18,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 6),
            Text(
              'Local first',
              style: TextStyle(
                color: scheme.onSecondaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'nexGallery',
      header: true,
      excludeSemantics: true,
      child: Row(
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
                  ?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.4),
            ),
          ],
        ],
      ),
    );
  }
}
