import 'dart:io';
import 'dart:ui' show PluginUtilities;

import 'package:flutter/services.dart';

import '../../core/gallery_settings.dart';
import '../../services/remote/background_entry.dart';

final class DeviceConditions {
  const DeviceConditions({
    this.charging = true,
    this.batteryPercent,
    this.powerSave = false,
    this.thermalStatus,
    this.lowRamDevice = false,
    this.lowMemory = false,
  });

  factory DeviceConditions.fromMap(Map<Object?, Object?> map) =>
      DeviceConditions(
        charging: map['charging'] == true,
        batteryPercent: (map['batteryPercent'] as num?)?.toInt(),
        powerSave: map['powerSave'] == true,
        thermalStatus: (map['thermalStatus'] as num?)?.toInt(),
        lowRamDevice: map['lowRamDevice'] == true,
        lowMemory: map['lowMemory'] == true,
      );

  final bool charging;
  final int? batteryPercent;
  final bool powerSave;

  /// Android PowerManager thermal status; 3 (severe) and above must pause work.
  final int? thermalStatus;
  final bool lowRamDevice;
  final bool lowMemory;

  /// Why heavy indexing should wait, or null when it may continue.
  String? pauseReason({bool requireCharging = false}) {
    if ((thermalStatus ?? 0) >= 3) return 'The phone is too warm.';
    if (lowMemory) return 'The phone is low on memory.';
    if (powerSave) return 'Battery saver is on.';
    if (requireCharging && !charging) return 'Waiting for the charger.';
    if (!charging && (batteryPercent ?? 100) < 20) return 'Battery is low.';
    return null;
  }

  /// Smaller batches keep low-RAM phones responsive.
  int get batchSize => lowRamDevice ? 4 : 16;
}

final class NetworkState {
  const NetworkState({
    this.connected = true,
    this.wifi = true,
    this.cellular = false,
    this.vpn = false,
    this.metered = false,
  });

  factory NetworkState.fromMap(Map<Object?, Object?> map) => NetworkState(
    connected: map['connected'] == true,
    wifi: map['wifi'] == true,
    cellular: map['cellular'] == true,
    vpn: map['vpn'] == true,
    metered: map['metered'] == true,
  );

  final bool connected;
  final bool wifi;
  final bool cellular;
  final bool vpn;
  final bool metered;
}

enum UserCheck { confirmed, cancelled, notSecured }

/// Device conditions and wallpaper. Desktop builds report an unrestricted PC.
class DeviceBridge {
  DeviceBridge({MethodChannel? channel, bool? isAndroid})
    : _channel =
          channel ?? const MethodChannel('com.thenex.nex_gallery/device'),
      _isAndroid = isAndroid ?? Platform.isAndroid;

  static final instance = DeviceBridge();

  final MethodChannel _channel;
  final bool _isAndroid;

  Future<bool> claimTransferSession(String owner) async {
    if (!_isAndroid) return true;
    return await _channel.invokeMethod<bool>('claimTransferSession', {
          'owner': owner,
        }) ??
        false;
  }

  Future<void> releaseTransferSession(String owner) async {
    if (_isAndroid) {
      await _channel.invokeMethod<void>('releaseTransferSession', {
        'owner': owner,
      });
    }
  }

  Future<void> configureBackground(GallerySettings settings) async {
    if (!_isAndroid) return;
    await _channel.invokeMethod<void>('configureBackground', {
      'callbackHandle': PluginUtilities.getCallbackHandle(
        backgroundBackupEntry,
      )!.toRawHandle(),
      'periodic': settings.cameraBackup && settings.backgroundBackup,
      'transfers': settings.backgroundTransfers,
      'wifiOnly': settings.transfersOnWifiOnly,
      'chargingOnly': settings.backupOnlyWhileCharging,
      'minutes': settings.backupIntervalMinutes,
    });
  }

  Future<void> runBackgroundNow() async {
    if (_isAndroid) await _channel.invokeMethod<void>('runBackgroundNow');
  }

  Future<String> runBackgroundReadiness() async =>
      (await _channel.invokeMethod<String>('runBackgroundReadiness', {
        'callbackHandle': PluginUtilities.getCallbackHandle(
          backgroundBackupEntry,
        )!.toRawHandle(),
      }))!;
  Future<Map<Object?, Object?>> backgroundWorkStatus(String id) async =>
      await _channel.invokeMapMethod<Object?, Object?>('backgroundWorkStatus', {
        'id': id,
      }) ??
      const {};

  Future<DeviceConditions> conditions() async {
    if (!_isAndroid) return const DeviceConditions();
    final value = await _channel.invokeMethod<Map<Object?, Object?>>(
      'getDeviceConditions',
    );
    return value == null
        ? const DeviceConditions()
        : DeviceConditions.fromMap(value);
  }

  Future<NetworkState> network() async {
    if (!_isAndroid) return const NetworkState();
    final value = await _channel.invokeMethod<Map<Object?, Object?>>(
      'getNetworkState',
    );
    return value == null
        ? const NetworkState(connected: false)
        : NetworkState.fromMap(value);
  }

  /// Opens the camera QR scanner; null when the user cancels.
  Future<String?> scanQrCode({String? prompt}) async {
    if (!_isAndroid) {
      throw UnsupportedError('QR scanning is available on Android.');
    }
    final value = await _channel.invokeMethod<Map<Object?, Object?>>(
      'scanQrCode',
      {'prompt': ?prompt},
    );
    return value?['status'] == 'scanned' ? value!['text'] as String? : null;
  }

  /// Asks for a fingerprint, face or screen-lock PIN. Phones without a screen
  /// lock, and desktops, report [UserCheck.notSecured].
  Future<UserCheck> confirmUser({
    required String title,
    String? subtitle,
  }) async {
    if (!_isAndroid) return UserCheck.notSecured;
    try {
      final value = await _channel.invokeMethod<String>('confirmUser', {
        'title': title,
        'subtitle': ?subtitle,
      });
      return switch (value) {
        'success' => UserCheck.confirmed,
        'notSecured' => UserCheck.notSecured,
        _ => UserCheck.cancelled,
      };
    } on MissingPluginException {
      return UserCheck.notSecured;
    }
  }

  /// The ABIs this phone runs, preferred first, for example `arm64-v8a`.
  Future<List<String>> supportedAbis() async {
    if (!_isAndroid) return const [];
    final value = await _channel.invokeListMethod<String>('supportedAbis');
    return value ?? const [];
  }

  /// Opens Android's installer for a verified update in the app cache.
  /// Returns false when the user must first allow nexGallery to install
  /// apps; Android then shows that setting.
  Future<bool> installApk(String path) async {
    final value = await _channel.invokeMethod<String>('installApk', {
      'path': path,
    });
    return value == 'started';
  }

  /// Returns false when this device does not allow apps to set wallpaper.
  Future<bool> setAndroidWallpaper(Uri uri, String target) async {
    final value = await _channel.invokeMethod<Map<Object?, Object?>>(
      'setWallpaper',
      {'uri': uri.toString(), 'target': target},
    );
    return value?['status'] == 'completed';
  }
}

/// Sets the desktop background through the documented user32 API.
Future<void> setWindowsWallpaper(String path) async {
  final quoted = path.replaceAll("'", "''");
  final script =
      'Add-Type -TypeDefinition \'using System.Runtime.InteropServices; '
      'public static class NexWallpaper { [DllImport("user32.dll", '
      'CharSet = CharSet.Unicode, SetLastError = true)] public static extern '
      'bool SystemParametersInfo(int action, int value, string path, int flags); }\'; '
      'if (-not [NexWallpaper]::SystemParametersInfo(20, 0, \'$quoted\', 3)) { exit 1 }';
  final result = await Process.run('powershell.exe', [
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-Command',
    script,
  ]);
  if (result.exitCode != 0) {
    throw const FileSystemException('Windows could not set the wallpaper.');
  }
}
