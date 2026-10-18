import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../data/android_media/android_media_bridge.dart';
import '../data/device/device_bridge.dart';
import '../features/files/files_page.dart';
import '../features/library/library_page.dart';
import '../features/photos/photos_page.dart';
import '../features/remote/remote_page.dart';
import '../features/settings/settings_page.dart';
import '../features/updates/update_banner.dart';
import '../services/remote/remote_session.dart';
import '../services/updates/app_update.dart';
import 'android_secret_store.dart';
import 'gallery_model.dart';
import 'gallery_runtime.dart';

abstract final class NexBreakpoints {
  static const navigationRail = 840.0;
  static const extendedRail = 1180.0;
}

class NexGalleryHome extends StatefulWidget {
  const NexGalleryHome({super.key, this.platform, this.model});

  final TargetPlatform? platform;
  final GalleryModel? model;

  @override
  State<NexGalleryHome> createState() => _NexGalleryHomeState();
}

class _NexGalleryHomeState extends State<NexGalleryHome>
    with WidgetsBindingObserver {
  late final GalleryModel _model;
  late final bool _ownsModel;
  RemoteSession? _session;
  AppUpdater? _updater;
  var _index = 0;

  bool get _isWindows =>
      (widget.platform ?? Theme.of(context).platform) == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ownsModel = widget.model == null;
    _model = widget.model ?? NexGalleryRuntime(platform: widget.platform);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _model.initialize();
      if (!_isWindows) unawaited(_openRemoteSession());
      if (updatesEnabled) unawaited(_startUpdates());
    });
  }

  /// The phone's PC connection lives as long as the app so transfers and
  /// camera backup continue while other tabs are open.
  Future<void> _openRemoteSession() async {
    final bridge = AndroidMediaBridge.instance;
    if (!bridge.isSupported || !Platform.isAndroid) return;
    try {
      final path = await bridge.getAppDataPath();
      if (!mounted) return;
      final session = RemoteSession(
        secrets: const AndroidSecretStore(),
        dataDirectory: Directory('$path${Platform.pathSeparator}remote'),
        model: _model,
      );
      setState(() => _session = session);
      await session.initialize();
    } on Object {
      // Remote access stays unavailable; the local gallery still works.
    }
  }

  /// Release builds look for a newer build on GitHub shortly after start,
  /// unless the owner turned it off in Settings.
  Future<void> _startUpdates() async {
    if (!Platform.isAndroid && !Platform.isWindows) return;
    try {
      final android = Platform.isAndroid;
      final updater = AppUpdater(
        isAndroid: android,
        abis: android ? await DeviceBridge.instance.supportedAbis() : const [],
        // On Android the system temp folder is the app cache, which the
        // installer bridge accepts.
        downloads: Directory(
          android
              ? '${Directory.systemTemp.path}/updates'
              : '${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}'
                    '\\nexGallery\\updates',
        ),
        installer: android
            ? (file) async {
                if (!await DeviceBridge.instance.installApk(file.path)) {
                  throw const FormatException(
                    'Allow nexGallery to install updates, then tap Install again.',
                  );
                }
              }
            : runWindowsInstaller,
      );
      if (!mounted) return;
      AppUpdater.instance = updater;
      setState(() => _updater = updater);
      await Future<void>.delayed(const Duration(seconds: 4));
      if (!mounted || !_model.settings.checkForUpdates) return;
      await updater.check();
      await updater.cleanUp();
    } on Object {
      // Updates are optional; the gallery keeps working offline.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (identical(AppUpdater.instance, _updater)) AppUpdater.instance = null;
    _updater?.dispose();
    _session?.dispose();
    if (_ownsModel) {
      (_model as NexGalleryRuntime).dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        (_model.settings.autoRefresh || !_isWindows)) {
      _model.refresh();
    }
    final session = _session;
    if (state == AppLifecycleState.resumed && session != null) {
      if (session.saved != null && !session.isConnected && !session.isBusy) {
        unawaited(session.reconnect());
      } else {
        unawaited(session.backUpCamera());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isWindows = _isWindows;
    final destinations = isWindows ? _desktopDestinations : _mobileDestinations;
    final pages = <Widget>[
      PhotosPage(
        model: _model,
        isDesktop: isWindows,
        remoteSession: _session,
        onOpenSettings: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SettingsPage(model: _model, isWindows: isWindows),
          ),
        ),
      ),
      LibraryPage(model: _model, onShowPhotos: () => _select(0)),
      RemotePage(isWindows: isWindows, session: _session),
      FilesPage(model: _model, isWindows: isWindows),
    ];

    // Keep each tab's navigation and transfer/server state alive. Media grids
    // remain lazy, while a running PC server must not stop when another tab is
    // selected.
    final stack = IndexedStack(
      index: _index,
      children: [
        for (var index = 0; index < pages.length; index++)
          TickerMode(enabled: index == _index, child: pages[index]),
      ],
    );
    final updater = _updater;
    final content = updater == null
        ? stack
        : Column(
            children: [
              UpdateBanner(updater: updater),
              Expanded(child: stack),
            ],
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
                trailing: Expanded(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: extended
                          ? const _LocalFirstBadge()
                          : const Tooltip(
                              message: 'Local first',
                              child: Icon(Icons.shield_outlined),
                            ),
                    ),
                  ),
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

  void _select(int value) {
    if (_index == value) return;
    setState(() => _index = value);
  }
}

const _mobileDestinations = <_DestinationSpec>[
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

const _desktopDestinations = <_DestinationSpec>[
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

class _LocalFirstBadge extends StatelessWidget {
  const _LocalFirstBadge();

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
