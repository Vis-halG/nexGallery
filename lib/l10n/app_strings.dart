import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppStrings {
  const AppStrings(this.locale, this.translations);
  final Locale locale;
  final Map<String, String> translations;
  static const supportedLocales = [Locale('en'), Locale('hi')];
  static const delegate = _StringsDelegate();
  static AppStrings of(BuildContext context) =>
      Localizations.of<AppStrings>(context, AppStrings) ??
      const AppStrings(Locale('en'), {});
  String tr(String english) => translations[english] ?? english;
}

class _StringsDelegate extends LocalizationsDelegate<AppStrings> {
  const _StringsDelegate();
  @override
  bool isSupported(Locale locale) => AppStrings.supportedLocales.any(
    (v) => v.languageCode == locale.languageCode,
  );
  @override
  Future<AppStrings> load(Locale locale) async {
    if (locale.languageCode == 'en') {
      return SynchronousFuture(AppStrings(locale, const {}));
    }
    final json = await rootBundle.loadString(
      'assets/l10n/${locale.languageCode}.json',
    );
    return AppStrings(
      locale,
      Map<String, String>.from(jsonDecode(json) as Map),
    );
  }

  @override
  bool shouldReload(_StringsDelegate old) => false;
}

extension LocalizedContext on BuildContext {
  String tr(String english) => AppStrings.of(this).tr(english);
}

/// Const-friendly localized text for application-owned copy. Filenames, album
/// names and other user content continue to use Text and are never translated.
class AppText extends Text {
  const AppText(
    super.data, {
    super.key,
    super.style,
    super.strutStyle,
    super.textAlign,
    super.textDirection,
    super.locale,
    super.softWrap,
    super.overflow,
    super.textScaler,
    super.maxLines,
    super.semanticsLabel,
    super.textWidthBasis,
    super.textHeightBehavior,
    super.selectionColor,
  });
  @override
  Widget build(BuildContext context) => Text(
    context.tr(data!),
    style: style,
    strutStyle: strutStyle,
    textAlign: textAlign,
    textDirection: textDirection,
    locale: locale,
    softWrap: softWrap,
    overflow: overflow,
    textScaler: textScaler,
    maxLines: maxLines,
    semanticsLabel: semanticsLabel == null ? null : context.tr(semanticsLabel!),
    textWidthBasis: textWidthBasis,
    textHeightBehavior: textHeightBehavior,
    selectionColor: selectionColor,
  ).build(context);
}
