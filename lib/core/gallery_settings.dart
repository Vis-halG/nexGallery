enum GalleryAppearance { system, light, dark }

/// Device-local preferences; remote access and backups are configured separately.
final class GallerySettings {
  const GallerySettings({
    this.appearance = GalleryAppearance.system,
    this.autoRefresh = true,
    this.includeHiddenFiles = false,
  });

  final GalleryAppearance appearance;
  final bool autoRefresh;
  final bool includeHiddenFiles;

  GallerySettings copyWith({GalleryAppearance? appearance, bool? autoRefresh,
    bool? includeHiddenFiles}) => GallerySettings(
      appearance: appearance ?? this.appearance,
      autoRefresh: autoRefresh ?? this.autoRefresh,
      includeHiddenFiles: includeHiddenFiles ?? this.includeHiddenFiles,
    );

  Map<String, Object?> toJson() => <String, Object?>{
    'appearance': appearance.name, 'autoRefresh': autoRefresh,
    'includeHiddenFiles': includeHiddenFiles,
  };

  factory GallerySettings.fromJson(Map<String, Object?> json) => GallerySettings(
    appearance: GalleryAppearance.values.firstWhere(
      (value) => value.name == json['appearance'], orElse: () => GalleryAppearance.system),
    autoRefresh: json['autoRefresh'] as bool? ?? true,
    includeHiddenFiles: json['includeHiddenFiles'] as bool? ?? false,
  );
}
