import 'dart:convert';
import 'dart:io';

enum ScanVerdict { clean, threat, unavailable }

/// Checks an uploaded file before it appears in a shared folder.
abstract interface class UploadScanner {
  /// Shown to the owner, for example "Microsoft Defender".
  String get name;
  Future<ScanVerdict> scan(File file);
}

/// Microsoft Defender's command-line scanner. Remediation is disabled so the
/// server decides where a flagged file goes.
final class DefenderScanner implements UploadScanner {
  DefenderScanner(this.executable);

  final String executable;

  @override
  String get name => 'Microsoft Defender';

  static Future<DefenderScanner?> find() async {
    if (!Platform.isWindows) return null;
    final candidates = <String>[];
    final programData = Platform.environment['ProgramData'];
    if (programData != null) {
      // Platform updates install newer scanners here; the newest wins.
      final platforms = Directory(
        '$programData\\Microsoft\\Windows Defender\\Platform',
      );
      try {
        final versions = await platforms
            .list()
            .where((entity) => entity is Directory)
            .map((entity) => entity.path)
            .toList();
        versions.sort();
        candidates.addAll(
          versions.reversed.map((path) => '$path\\MpCmdRun.exe'),
        );
      } on FileSystemException {
        // Defender's platform folder is optional.
      }
    }
    candidates.add(
      '${Platform.environment['ProgramFiles'] ?? r'C:\Program Files'}'
      r'\Windows Defender\MpCmdRun.exe',
    );
    for (final path in candidates) {
      if (await File(path).exists()) return DefenderScanner(path);
    }
    return null;
  }

  @override
  Future<ScanVerdict> scan(File file) async {
    try {
      final result = await Process.run(executable, [
        '-Scan',
        '-ScanType',
        '3',
        '-File',
        // MpCmdRun cannot open paths written with forward slashes.
        file.absolute.path.replaceAll('/', r'\'),
        '-DisableRemediation',
      ]).timeout(const Duration(minutes: 15));
      return parseDefenderResult(result.exitCode, '${result.stdout}');
    } on Object {
      return ScanVerdict.unavailable;
    }
  }
}

/// MpCmdRun exits with 2 both for a detection and for a failed scan, so the
/// verdict comes from its report.
ScanVerdict parseDefenderResult(int exitCode, String output) {
  final found = RegExp(r'found (\d+) threats?').firstMatch(output);
  if (output.contains('found no threats') && exitCode == 0) {
    return ScanVerdict.clean;
  }
  if ((found != null && int.parse(found.group(1)!) > 0) ||
      output.contains('LIST OF DETECTED THREATS')) {
    return ScanVerdict.threat;
  }
  // For example "CmdTool: Failed with hr = ...", or another antivirus
  // product has replaced Defender.
  return ScanVerdict.unavailable;
}

const _riskyExtensions = <String>{
  // Programs, scripts and shortcuts Windows can run.
  'exe', 'msi', 'msix', 'msixbundle', 'appx', 'appxbundle', 'bat', 'cmd',
  'com', 'scr', 'pif', 'cpl', 'dll', 'sys', 'ocx', 'lnk', 'url', 'reg', 'inf',
  'ps1', 'psm1', 'psd1', 'vbs', 'vbe', 'js', 'jse', 'wsf', 'wsh', 'hta', 'jar',
  'msc', 'application', 'gadget', 'scf', 'chm', 'apk', 'xapk', 'aab',
  // Archives and disk images that can hide them.
  'zip', '7z', 'rar', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'cab', 'iso', 'img',
  'vhd', 'vhdx',
  // Office documents with macros.
  'docm', 'dotm', 'xlsm', 'xltm', 'xlam', 'pptm', 'potm', 'ppam',
};

/// Executables, scripts, archives and macro documents are held until they
/// have been scanned.
bool needsUploadScan(String path) {
  final name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
  final dot = name.lastIndexOf('.');
  return dot >= 0 && _riskyExtensions.contains(name.substring(dot + 1));
}

/// Marks [file] as downloaded from the internet, so Windows SmartScreen and
/// Office Protected View warn before it runs. Best effort; FAT and exFAT
/// drives have no alternate streams.
Future<void> markFromInternet(File file) async {
  if (!Platform.isWindows) return;
  try {
    await File('${file.path}:Zone.Identifier').writeAsString(
      '[ZoneTransfer]\r\nZoneId=3\r\nReferrerUrl=nexgallery://paired-phone\r\n',
      flush: true,
    );
  } on FileSystemException {
    // The file still waits for its scan.
  }
}

/// An upload kept out of its shared folder until it is scanned or the PC
/// owner decides.
final class QuarantinedUpload {
  QuarantinedUpload({
    required this.id,
    required this.root,
    required this.path,
    required this.size,
    required this.uploadedAt,
    required this.status,
    this.deviceName,
    this.sha256,
    this.scanner,
  });

  factory QuarantinedUpload.fromJson(Map<String, dynamic> json) =>
      QuarantinedUpload(
        id: json['id'] as String,
        root: json['root'] as String,
        path: json['path'] as String,
        size: (json['size'] as num).toInt(),
        uploadedAt: DateTime.parse(json['uploadedAt'] as String),
        status: QuarantineStatus.values.byName(json['status'] as String),
        deviceName: json['deviceName'] as String?,
        sha256: json['sha256'] as String?,
        scanner: json['scanner'] as String?,
      );

  static final idPattern = RegExp(r'^[0-9]+-[0-9a-f]+$');

  final String id;
  final String root;

  /// Where the phone asked to put the file.
  final String path;
  final int size;
  final DateTime uploadedAt;
  QuarantineStatus status;
  final String? deviceName;
  final String? sha256;
  String? scanner;

  String get name => path.split('/').last;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'root': root,
    'path': path,
    'size': size,
    'uploadedAt': uploadedAt.toUtc().toIso8601String(),
    'status': status.name,
    'deviceName': ?deviceName,
    'sha256': ?sha256,
    'scanner': ?scanner,
  };

  String encode() => jsonEncode(toJson());
}

enum QuarantineStatus {
  /// Being scanned; released automatically when clean.
  scanning,

  /// No scanner could check it; the owner may release or delete it.
  held,

  /// The scanner found a threat; it can only be deleted.
  blocked,
}
