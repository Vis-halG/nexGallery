import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/core/catalog_models.dart';
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/core/gallery_settings.dart';
import 'package:nex_gallery/src/app.dart';
import 'package:nex_gallery/src/gallery_model.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.thenex.nex_gallery/media'),
          (call) async {
            if (call.method == 'getPersistedDirectories') return <Object>[];
            throw MissingPluginException('Not implemented by this UI fixture');
          },
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.thenex.nex_gallery/media'),
          null,
        );
  });
  testWidgets('shows a real local timeline and four phone destinations', (
    tester,
  ) async {
    final model = _FakeGalleryModel();
    await tester.pumpWidget(
      NexGalleryApp(platform: TargetPlatform.android, model: model),
    );
    await tester.pump();

    for (final label in ['Photos', 'Library', 'My PC', 'Files']) {
      expect(find.text(label), findsWidgets);
    }
    expect(find.text('IMG_20261002.jpg'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.auto_awesome_outlined));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Collections'), findsOneWidget);
    expect(find.text('People'), findsOneWidget);
    expect(find.text('Not installed'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.computer_outlined));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Connect securely'), findsOneWidget);
    expect(find.text('Pair and connect'), findsOneWidget);
  });

  testWidgets('uses the functional desktop navigation at wide widths', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      NexGalleryApp(
        platform: TargetPlatform.windows,
        model: _FakeGalleryModel(),
      ),
    );
    await tester.pump();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('This PC'), findsWidgets);
    expect(find.text('Server'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.dns_outlined));
    await tester.pumpAndSettle();
    expect(find.text('PC server'), findsOneWidget);
    expect(find.text('Start server'), findsOneWidget);
    expect(find.text('Local first'), findsOneWidget);
  });

  testWidgets('fits a compact 320 by 568 phone without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      NexGalleryApp(
        platform: TargetPlatform.android,
        model: _FakeGalleryModel(),
      ),
    );
    await tester.pump();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('IMG_20261002.jpg'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('viewer swipes, follows favorites, and displays local metadata', (
    tester,
  ) async {
    final model = _FakeGalleryModel(additionalItems: 1);
    await tester.pumpWidget(
      NexGalleryApp(platform: TargetPlatform.android, model: model),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('IMG_20261002.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('1 of 2 · Phone'), findsOneWidget);
    expect(model.thumbnailSizes, contains(1024));
    expect(
      find.text('Preview unavailable. Try opening with another app.'),
      findsOneWidget,
    );

    await tester.drag(
      find.byKey(const ValueKey('media-viewer-pages')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 of 2 · Phone'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('1 of 2 · Phone'), findsOneWidget);

    await tester.tap(find.byTooltip('Favorite'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Remove favorite'), findsOneWidget);
    await tester.tap(find.byTooltip('Viewer actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.text('Pictures/Camera'), findsOneWidget);
    expect(find.text('1920 × 1080'), findsOneWidget);
    expect(find.text('2048 bytes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached photos stay visible while refreshing', (tester) async {
    final model = _FakeGalleryModel(
      state: GalleryLoadState.loading,
      indexing: true,
    );
    await tester.pumpWidget(
      NexGalleryApp(platform: TargetPlatform.android, model: model),
    );
    await tester.pump();
    expect(find.text('IMG_20261002.jpg'), findsOneWidget);
    expect(find.text('Indexed 1 of 1'), findsOneWidget);
  });

  testWidgets(
    'denied permissions show the request action and hide cached photos',
    (tester) async {
      final model = _FakeGalleryModel(
        state: GalleryLoadState.permissionRequired,
      );
      await tester.pumpWidget(
        NexGalleryApp(platform: TargetPlatform.android, model: model),
      );
      await tester.pumpAndSettle();
      expect(find.text('Allow photo and video access'), findsOneWidget);
      expect(find.text('IMG_20261002.jpg'), findsNothing);
      await tester.tap(find.text('Choose photos and videos'));
      expect(model.accessRequests, 1);
    },
  );

  testWidgets('load more reveals the next page', (tester) async {
    final model = _FakeGalleryModel(additionalItems: 1, initialPageSize: 1);
    await tester.pumpWidget(
      NexGalleryApp(platform: TargetPlatform.android, model: model),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Load more'));
    await tester.drag(
      find.byKey(const PageStorageKey('photos-timeline')),
      const Offset(0, -250),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(model.items, hasLength(2));
    expect(find.text('Load more'), findsNothing);
  });

  testWidgets('viewer fits a small phone with enlarged text', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = _FakeGalleryModel();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: NexGalleryApp(platform: TargetPlatform.android, model: model),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const PageStorageKey('photos-timeline')),
      const Offset(0, -250),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('IMG_20261002.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('1 of 1 · Phone'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable status fits a dense compact grid', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = _FakeGalleryModel(available: false);
    await tester.pumpWidget(
      NexGalleryApp(platform: TargetPlatform.windows, model: model),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Change grid size'));
    await tester.pumpAndSettle();
    expect(find.text('Drive unavailable'), findsOneWidget);
    expect(model.thumbnailSizes, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

final class _FakeGalleryModel extends ChangeNotifier implements GalleryModel {
  _FakeGalleryModel({
    int additionalItems = 0,
    int? initialPageSize,
    this.state = GalleryLoadState.ready,
    this.indexing = false,
    this.available = true,
  }) {
    final now = DateTime.now();
    _allItems = <MediaItem>[
      MediaItem(
        id: 'photo-1',
        name: 'IMG_20261002.jpg',
        uri: 'file:///test/IMG_20261002.jpg',
        relativePath: 'Pictures/Camera',
        kind: MediaKind.image,
        source: MediaSource.phone,
        isAvailable: available,
        metadata: MediaMetadata(
          sizeBytes: 2048,
          modifiedAt: now,
          takenAt: now,
          width: 1920,
          height: 1080,
          mimeType: 'image/jpeg',
          extension: 'jpg',
        ),
        indexedAt: now,
      ),
    ];
    for (var index = 0; index < additionalItems; index++) {
      _allItems.add(
        _allItems.first.copyWith(id: 'extra-$index', name: 'extra-$index.jpg'),
      );
    }
    _items = initialPageSize == null
        ? _allItems
        : _allItems.take(initialPageSize).toList();
  }

  late final List<MediaItem> _allItems;
  late List<MediaItem> _items;
  GalleryCollection _collection = GalleryCollection.timeline;
  String _search = '';
  final GalleryLoadState state;
  final bool indexing;
  final bool available;
  final thumbnailSizes = <int>[];
  int accessRequests = 0;
  GallerySettings _settings = const GallerySettings();
  @override
  GallerySettings get settings => _settings;
  @override
  List<String> get windowsFolders => const <String>[];
  @override
  Future<void> removeWindowsFolder(String path) async {}
  @override
  Future<void> updateSettings(GallerySettings value) async {
    _settings = value; notifyListeners();
  }
  @override
  Future<void> openAccessSettings() async {}
  @override
  Future<Duration> readVideoPosition(MediaItem item) async => Duration.zero;
  @override
  Future<void> saveVideoPosition(MediaItem item, Duration position) async {}
  @override
  bool canAccessMedia(MediaItem item) => item.isAvailable;

  @override
  List<MediaAlbum> get albums => const <MediaAlbum>[];

  @override
  List<CategorySummary> get categories => MediaKind.values
      .map(
        (kind) => CategorySummary(
          kind: kind,
          itemCount: kind == MediaKind.image ? 1 : 0,
          totalBytes: kind == MediaKind.image ? 2048 : 0,
        ),
      )
      .toList(growable: false);

  @override
  GalleryCollection get collection => _collection;

  @override
  int? get discoveredCount => 1;

  @override
  String? get errorMessage => null;

  @override
  bool get hasLimitedAccess => false;

  @override
  int get indexedCount => 1;

  @override
  bool get isIndexing => indexing;

  @override
  List<MediaItem> get items => _items;

  @override
  int get totalItemCount =>
      _collection == GalleryCollection.timeline && _search.isEmpty
      ? _allItems.length
      : _items.length;

  @override
  bool get hasMoreItems => _items.length < totalItemCount;

  @override
  void loadMoreItems() {
    _items = _allItems;
    notifyListeners();
  }

  @override
  GalleryLoadState get loadState => state;

  @override
  String get searchText => _search;

  @override
  String? get statusMessage => 'Local scan complete.';

  @override
  Future<void> addWindowsFolder(String path) async {}

  @override
  Future<void> addToAlbum(MediaItem item, String albumId) async {}

  @override
  Future<void> archive(MediaItem item) async {}

  @override
  Future<void> createAlbum(String name) async {}

  @override
  Future<bool> deletePermanently(MediaItem item) async => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<Uint8List?> loadThumbnail(MediaItem item, {int size = 384}) async {
    thumbnailSizes.add(size);
    return null;
  }

  @override
  Future<bool> moveToTrash(MediaItem item) async => true;

  @override
  Future<void> open(MediaItem item) async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<void> requestAccessAndRefresh() async {
    accessRequests++;
  }

  @override
  Future<bool> restore(MediaItem item) async => true;

  @override
  void setSearchText(String value) {
    _search = value;
    _items = _allItems
        .where((item) => item.name.toLowerCase().contains(value.toLowerCase()))
        .toList();
    notifyListeners();
  }

  @override
  Future<void> share(MediaItem item) async {}

  @override
  void showCollection(GalleryCollection value) {
    _collection = value;
    _items = value == GalleryCollection.timeline ? _allItems : <MediaItem>[];
    notifyListeners();
  }

  @override
  void showKinds(Set<MediaKind> kinds) {
    _items = kinds.isEmpty
        ? _allItems
        : _allItems.where((item) => kinds.contains(item.kind)).toList();
    notifyListeners();
  }

  @override
  void showAlbum(String albumId) {
    notifyListeners();
  }

  @override
  Future<void> toggleFavorite(MediaItem item) async {
    final index = _allItems.indexWhere((value) => value.id == item.id);
    _allItems[index] = item.copyWith(isFavorite: !item.isFavorite);
    notifyListeners();
  }
}
