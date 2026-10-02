import 'package:flutter/material.dart';

import 'home_shell.dart';

class NexGalleryApp extends StatelessWidget {
  const NexGalleryApp({super.key});

  static const violet = Color(0xFF7C3AED);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'nexGallery',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: violet),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF8F7FC),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: violet,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const NexGalleryHome(),
    );
  }
}
