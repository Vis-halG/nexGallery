enum GalleryAppearance { system, light, dark }

/// Device-local preferences; remote access and backups are configured separately.
final class GallerySettings {
  const GallerySettings({
    this.appearance = GalleryAppearance.system,
    this.autoRefresh = true,
    this.includeHiddenFiles = false,
    this.analyzeOnlyWhileCharging = false,
    this.transfersOnWifiOnly = true,
    this.cameraBackup = false,
    this.mobileVideoQuality = 720,
    this.checkForUpdates = true,
    this.language = 'system',
    this.backgroundBackup = false,
    this.backgroundTransfers = false,
    this.backupOnlyWhileCharging = true,
    this.backupIntervalMinutes = 60,
  });

  final GalleryAppearance appearance;
  final bool autoRefresh;
  final bool includeHiddenFiles;

  /// Defers face, label and text indexing until the phone is charging.
  final bool analyzeOnlyWhileCharging;

  /// Pauses phone-PC transfers on mobile data or metered networks.
  final bool transfersOnWifiOnly;

  /// Uploads new camera photos to the paired PC when the app is opened.
  final bool cameraBackup;

  /// Height of the PC's smaller video copy streamed on mobile data or a
  /// metered network; 0 always streams the original.
  final int mobileVideoQuality;

  /// Release builds ask GitHub for a newer build when the app starts.
  final bool checkForUpdates;
  final String language;
  final bool backgroundBackup, backgroundTransfers, backupOnlyWhileCharging;
  final int backupIntervalMinutes;

  GallerySettings copyWith({
    GalleryAppearance? appearance,
    bool? autoRefresh,
    bool? includeHiddenFiles,
    bool? analyzeOnlyWhileCharging,
    bool? transfersOnWifiOnly,
    bool? cameraBackup,
    int? mobileVideoQuality,
    bool? checkForUpdates,
    String? language,
    bool? backgroundBackup,
    bool? backgroundTransfers,
    bool? backupOnlyWhileCharging,
    int? backupIntervalMinutes,
  }) => GallerySettings(
    appearance: appearance ?? this.appearance,
    autoRefresh: autoRefresh ?? this.autoRefresh,
    includeHiddenFiles: includeHiddenFiles ?? this.includeHiddenFiles,
    analyzeOnlyWhileCharging:
        analyzeOnlyWhileCharging ?? this.analyzeOnlyWhileCharging,
    transfersOnWifiOnly: transfersOnWifiOnly ?? this.transfersOnWifiOnly,
    cameraBackup: cameraBackup ?? this.cameraBackup,
    mobileVideoQuality: mobileVideoQuality ?? this.mobileVideoQuality,
    checkForUpdates: checkForUpdates ?? this.checkForUpdates,
    language: language ?? this.language,
    backgroundBackup: backgroundBackup ?? this.backgroundBackup,
    backgroundTransfers: backgroundTransfers ?? this.backgroundTransfers,
    backupOnlyWhileCharging:
        backupOnlyWhileCharging ?? this.backupOnlyWhileCharging,
    backupIntervalMinutes: backupIntervalMinutes ?? this.backupIntervalMinutes,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'appearance': appearance.name,
    'autoRefresh': autoRefresh,
    'includeHiddenFiles': includeHiddenFiles,
    'analyzeOnlyWhileCharging': analyzeOnlyWhileCharging,
    'transfersOnWifiOnly': transfersOnWifiOnly,
    'cameraBackup': cameraBackup,
    'mobileVideoQuality': mobileVideoQuality,
    'checkForUpdates': checkForUpdates,
    'language': language,
    'backgroundBackup': backgroundBackup,
    'backgroundTransfers': backgroundTransfers,
    'backupOnlyWhileCharging': backupOnlyWhileCharging,
    'backupIntervalMinutes': backupIntervalMinutes,
  };

  factory GallerySettings.fromJson(Map<String, Object?> json) =>
      GallerySettings(
        appearance: GalleryAppearance.values.firstWhere(
          (value) => value.name == json['appearance'],
          orElse: () => GalleryAppearance.system,
        ),
        autoRefresh: json['autoRefresh'] as bool? ?? true,
        includeHiddenFiles: json['includeHiddenFiles'] as bool? ?? false,
        analyzeOnlyWhileCharging:
            json['analyzeOnlyWhileCharging'] as bool? ?? false,
        transfersOnWifiOnly: json['transfersOnWifiOnly'] as bool? ?? true,
        cameraBackup: json['cameraBackup'] as bool? ?? false,
        mobileVideoQuality: switch (json['mobileVideoQuality']) {
          final int value when const [0, 360, 720].contains(value) => value,
          _ => 720,
        },
        checkForUpdates: json['checkForUpdates'] as bool? ?? true,
        language: const ['system', 'en', 'hi'].contains(json['language'])
            ? json['language'] as String
            : 'system',
        backgroundBackup: json['backgroundBackup'] as bool? ?? false,
        backgroundTransfers: json['backgroundTransfers'] as bool? ?? false,
        backupOnlyWhileCharging:
            json['backupOnlyWhileCharging'] as bool? ?? true,
        backupIntervalMinutes:
            const [15, 60, 360].contains(json['backupIntervalMinutes'])
            ? json['backupIntervalMinutes'] as int
            : 60,
      );
}
