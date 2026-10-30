import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nex_gallery/data/android_media/android_media_bridge.dart';
import 'package:nex_gallery/data/device/device_bridge.dart';
import 'package:nex_gallery/features/library/places_map_page.dart';
import 'package:nex_gallery/l10n/app_strings.dart';
import 'package:nex_gallery/src/gallery_runtime.dart';

/// Uses only a new app-private directory; never edits the device's media.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'scheduled worker runs real headless native channels and Keystore',
    (tester) async {
      final id = await DeviceBridge.instance.runBackgroundReadiness();
      Map<Object?, Object?> status = const {};
      for (var attempt = 0; attempt < 120; attempt++) {
        status = await DeviceBridge.instance.backgroundWorkStatus(id);
        if (const [
          'SUCCEEDED',
          'FAILED',
          'CANCELLED',
        ].contains(status['state'])) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      expect(status['state'], 'SUCCEEDED', reason: '$status');
      expect(status['ok'], isTrue);
    },
  );
  testWidgets('native Keystore catalogue roundtrip, Hindi and offline map', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue);
    final base = await AndroidMediaBridge.instance.getAppDataPath();
    final directory = await Directory(
      '$base/readiness-${DateTime.now().microsecondsSinceEpoch}',
    ).create();
    final runtime = NexGalleryRuntime(dataDirectory: directory.path);
    NexGalleryRuntime? reopened;
    try {
      await runtime.initialize();
      expect(runtime.errorMessage, isNull);
      await runtime.updateSettings(runtime.settings.copyWith(language: 'hi'));
      await runtime.setCatalogueEncryption(true);
      expect(await File('${directory.path}/catalog.enc').exists(), isTrue);
      expect(await File('${directory.path}/catalog.sqlite').exists(), isFalse);
      reopened = NexGalleryRuntime(dataDirectory: directory.path);
      await reopened.initialize();
      expect(reopened.errorMessage, isNull);
      expect(reopened.catalogueEncrypted, isTrue);
      expect(reopened.settings.language, 'hi');
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('hi'),
          supportedLocales: AppStrings.supportedLocales,
          localizationsDelegates: const [
            AppStrings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: PlacesMapPage(model: reopened, tools: reopened),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (v) => v is RichText && v.text.toPlainText() == 'फ़ोटो का नक्शा',
        ),
        findsOneWidget,
      );
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(tester.takeException(), isNull);
      await reopened.setCatalogueEncryption(false);
      expect(await File('${directory.path}/catalog.sqlite').exists(), isTrue);
      debugPrint(
        'PASS: real Android Keystore, encrypted catalogue migration/reopen, Hindi and bundled offline map.',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      runtime.dispose();
      reopened?.dispose();
      await directory.delete(recursive: true);
    }
  });
}
