import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/data/windows_files/windows_files_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('nexgallery/windows_files');
  const bridge = WindowsFilesBridge(channel: channel);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('native folder selection preserves Unicode and cancellation', () async {
    String? selected = r'C:\Pictures\旅行';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'chooseFolder');
          return selected;
        });
    expect(await bridge.chooseFolder(), selected);
    selected = null;
    expect(await bridge.chooseFolder(), isNull);
  });

  test('file identity requests are deduplicated and bounded', () async {
    final batches = <List<String>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'fileIdentities');
          final arguments = (call.arguments as Map).cast<String, Object>();
          final paths = (arguments['paths'] as List).cast<String>();
          batches.add(paths);
          return <String, String>{
            for (final path in paths.where((path) => path != 'missing'))
              path: 'winfile_$path',
          };
        });
    final paths = List<String>.generate(600, (index) => 'file-$index');
    final identities = await bridge.fileIdentities(<String>[
      ...paths,
      ...paths,
      'missing',
    ]);
    expect(batches.map((batch) => batch.length), <int>[256, 256, 89]);
    expect(identities, hasLength(600));
    expect(identities['file-599'], 'winfile_file-599');
    expect(identities.containsKey('missing'), isFalse);
    expect(() => identities['new'] = 'new', throwsUnsupportedError);
  });

  test('native failures remain explicit', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(code: 'folder_dialog_failed');
        });
    await expectLater(bridge.chooseFolder(), throwsA(isA<PlatformException>()));
  });
}
