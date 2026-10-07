import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/features/files/files_page.dart';
import 'package:nex_gallery/src/gallery_model.dart';

void main() {
  const channel = MethodChannel('nexgallery/windows_files');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> showFiles(WidgetTester tester, _FolderModel model) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FilesPage(model: model, isWindows: true)),
        ),
      );

  testWidgets('native folder selection and removal update selected roots', (
    tester,
  ) async {
    final model = _FolderModel();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => r'C:\Pictures\旅行');
    await showFiles(tester, model);
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();
    expect(model.windowsFolders, <String>[r'C:\Pictures\旅行']);
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.text(r'C:\Pictures\旅行'), findsOneWidget);
    await tester.tap(
      find.byTooltip('Remove from library; files stay in place'),
    );
    await tester.pumpAndSettle();
    expect(model.windowsFolders, isEmpty);
    expect(model.removed, <String>[r'C:\Pictures\旅行']);
    expect(find.text('0 selected'), findsOneWidget);
  });

  testWidgets('cancelled folder dialogs preserve selected roots', (
    tester,
  ) async {
    final model = _FolderModel()..windowsFolders.add(r'D:\Family');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    await showFiles(tester, model);
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();
    expect(model.windowsFolders, <String>[r'D:\Family']);
    expect(find.text('Choose folder'), findsOneWidget);
  });

  testWidgets('unavailable native dialogs expose the path fallback', (
    tester,
  ) async {
    final model = _FolderModel();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => throw MissingPluginException(),
        );
    await showFiles(tester, model);
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();
    expect(find.textContaining('folder dialog is unavailable'), findsOneWidget);
    await tester.tap(find.text('Enter a folder path'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), r'D:\Documents');
    await tester.ensureVisible(find.text('Add path'));
    await tester.tap(find.text('Add path'));
    await tester.pumpAndSettle();
    expect(model.windowsFolders, <String>[r'D:\Documents']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('folder controls fit a compact window with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = _FolderModel()
      ..windowsFolders.add(r'D:\Family\Long folder names\Vacation');
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(body: FilesPage(model: model, isWindows: true)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Choose folder'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// This focused fake fails for unused contracts so accidental new dependencies
/// are visible while keeping the folder tests independent of persistence.
final class _FolderModel extends ChangeNotifier implements GalleryModel {
  @override
  final windowsFolders = <String>[];
  final removed = <String>[];

  @override
  bool get isIndexing => false;
  @override
  List<MediaItem> get items => const <MediaItem>[];

  @override
  Future<void> addWindowsFolder(String path) async {
    windowsFolders.add(path);
    notifyListeners();
  }

  @override
  Future<void> removeWindowsFolder(String path) async {
    removed.add(path);
    windowsFolders.remove(path);
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unused folder test contract: ${invocation.memberName}',
  );
}
