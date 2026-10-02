import 'package:flutter/material.dart';

import 'home_shell.dart';

class NexGalleryApp extends StatelessWidget {
  const NexGalleryApp({super.key, this.platform});

  static const _violet = Color(0xFF6D3BEF);
  final TargetPlatform? platform;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'nexGallery',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: const NexGalleryHome(),
    );
  }

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _violet,
      brightness: brightness,
    );
    final isDark = brightness == Brightness.dark;

    return ThemeData(
      brightness: brightness,
      platform: platform,
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: isDark
          ? const Color(0xFF111015)
          : const Color(0xFFF9F8FC),
      cardTheme: CardThemeData(
        elevation: 0,
        color: isDark ? const Color(0xFF1B191F) : Colors.white,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.65),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        indicatorColor: scheme.secondaryContainer,
        labelTextStyle: WidgetStatePropertyAll(
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: isDark ? const Color(0xFF151419) : Colors.white,
        indicatorColor: scheme.secondaryContainer,
        selectedLabelTextStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    );
  }
}
