import 'package:flutter/material.dart';

import 'gallery_model.dart';
import 'gallery_runtime.dart';
import '../core/gallery_settings.dart';
import 'home_shell.dart';

class NexGalleryApp extends StatefulWidget {
  const NexGalleryApp({super.key, this.platform, this.model});

  static const _violet = Color(0xFF6D3BEF);
  final TargetPlatform? platform;
  final GalleryModel? model;

  @override
  State<NexGalleryApp> createState() => _NexGalleryAppState();
}

class _NexGalleryAppState extends State<NexGalleryApp> {
  late final GalleryModel _model;
  late final bool _ownsModel;
  @override
  void initState() {
    super.initState();
    _ownsModel = widget.model == null;
    _model = widget.model ?? NexGalleryRuntime(platform: widget.platform);
  }
  @override
  void dispose() {
    if (_ownsModel) (_model as NexGalleryRuntime).dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _model,
    builder: (context, _) {
    return MaterialApp(
      title: 'nexGallery',
      debugShowCheckedModeBanner: false,
      themeMode: switch (_model.settings.appearance) {
        GalleryAppearance.system => ThemeMode.system,
        GalleryAppearance.light => ThemeMode.light,
        GalleryAppearance.dark => ThemeMode.dark,
      },
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: NexGalleryHome(platform: widget.platform, model: _model),
    );
  });

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: NexGalleryApp._violet,
      brightness: brightness,
    );
    final isDark = brightness == Brightness.dark;

    return ThemeData(
      brightness: brightness,
      platform: widget.platform,
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
