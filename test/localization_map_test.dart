import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/core/gallery_settings.dart';
import 'package:nex_gallery/data/gallery_preferences_store.dart';
import 'package:nex_gallery/l10n/app_strings.dart';
import 'package:nex_gallery/features/library/places_map_page.dart';

void main() {
  test('language survives settings serialization; unknown languages fall back safely', () {
    final hindi = const GallerySettings().copyWith(language: 'hi');
    expect(GallerySettings.fromJson(hindi.toJson()).language, 'hi');
    expect(
      GallerySettings.fromJson({'language': 'unknown'}).language,
      'system',
    );
    final preferences = GalleryPreferences.fromJson(
      GalleryPreferences(settings: hindi).toJson(),
    );
    expect(preferences.settings.language, 'hi');
  });

  testWidgets(
    'Hindi renders application and system controls; user content stays unchanged',
    (tester) async {
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
          home: const Scaffold(
            body: Column(
              children: [
                AppText('Photos'),
                AppText('Settings'),
                Text('Photos'),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (v) => v is RichText && v.text.toPlainText() == 'फ़ोटो',
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (v) => v is RichText && v.text.toPlainText() == 'सेटिंग्स',
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (v) => v is RichText && v.text.toPlainText() == 'Photos',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test('every app-owned localized literal has a Hindi translation', () async {
    final strings = AppStrings(
      const Locale('hi'),
      Map<String, String>.from(
        jsonDecode(await File('assets/l10n/hi.json').readAsString()) as Map,
      ),
    );
    final literal = RegExp(r"(?:AppText|context\.tr)\(\s*'((?:\\.|[^'\\])*)'");
    final missing = <String>{};
    for (final directory in ['lib/src', 'lib/features']) {
      await for (final file in Directory(directory).list(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        for (final match in literal.allMatches(await file.readAsString())) {
          final value = match.group(1)!.replaceAll(r"\'", "'");
          if (value.contains(r'$')) continue;
          if (!strings.translations.containsKey(value)) missing.add(value);
        }
      }
    }
    expect(
      missing,
      isEmpty,
      reason: 'Add translations for these application strings.',
    );
  });

  test('offline map projection covers poles and antimeridian and rejects invalid GPS', () {
    const size = Size(360, 180);
    expect(projectLocation(90, -180, size), Offset.zero);
    expect(projectLocation(-90, 180, size), const Offset(360, 180));
    expect(projectLocation(0, 0, size), const Offset(180, 90));
    for (final pair in [
      (91.0, 0.0),
      (0.0, 181.0),
      (double.nan, 0.0),
      (0.0, double.infinity),
    ]) {
      expect(
        () => projectLocation(pair.$1, pair.$2, size),
        throwsFormatException,
      );
    }
  });
}
