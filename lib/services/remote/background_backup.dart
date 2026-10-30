import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../data/android_media/android_backup_source.dart';
import '../../data/android_media/android_media_bridge.dart';
import '../../data/device/device_bridge.dart';
import '../../data/gallery_preferences_store.dart';
import '../../src/android_secret_store.dart';
import 'remote_session.dart';
import 'transfer_queue.dart';

/// Headless entry. Reads preferences and authorized MediaStore rows without
/// opening the UI catalogue for writes. One native lease owns transfer files.
Future<void> runBackgroundBackup() async {
  const channel = MethodChannel('com.thenex.nex_gallery/background_worker');
  RemoteSession? session;
  var stopped = false, retry = false;
  channel.setMethodCallHandler((call) async {
    if (call.method == 'stop') {
      stopped = true;
      await session?.deactivate();
    }
  });
  try {
    final configuration =
        await channel.invokeMapMethod<String, Object?>('configuration') ??
        const {};
    final bridge = AndroidMediaBridge.instance;
    final base = await bridge.getAppDataPath();
    if (configuration['readiness'] == true) {
      // A real headless-engine probe: requires native context-backed channels,
      // Keystore and device conditions, but never edits user media or settings.
      final name = 'worker.probe.${DateTime.now().microsecondsSinceEpoch}';
      try {
        await bridge.storeSecret(name, 'headless-keystore-ready');
        if (await bridge.readSecret(name) != 'headless-keystore-ready') {
          throw StateError('Headless Keystore failed.');
        }
        await DeviceBridge.instance.conditions();
        if (!Directory(base).isAbsolute) {
          throw StateError('Invalid headless app data path.');
        }
      } finally {
        await bridge.deleteSecret(name);
      }
    } else if (!stopped && configuration['foreground'] != true) {
      final settingsFile = File('$base/settings.json');
      if (!await settingsFile.exists()) return;
      final raw = jsonDecode(await settingsFile.readAsString()) as Map;
      final settings = GalleryPreferences.fromJson(
        Map<String, Object?>.from(raw),
      ).settings;
      if (!settings.backgroundTransfers &&
          !(settings.backgroundBackup && settings.cameraBackup)) {
        return;
      }
      final conditions = await DeviceBridge.instance.conditions();
      if (conditions.pauseReason(
            requireCharging: settings.backupOnlyWhileCharging,
          ) !=
          null) {
        retry = true;
        return;
      }
      final source = await AndroidBackupSource.load(
        settings,
        cancelled: () => stopped,
      );
      if (stopped) return;
      session = RemoteSession(
        secrets: const AndroidSecretStore(),
        dataDirectory: Directory('$base/remote'),
        backupSource: source,
        background: true,
      );
      await session.initialize();
      if (!session.ownsSession || !session.isConnected) {
        retry = session.saved != null || !session.ownsSession;
        return;
      }
      if (settings.backgroundBackup && settings.cameraBackup) {
        await session.backUpCamera();
      }
      // Explicitly paused transfers remain paused. Failed transfers are visible
      // to the owner; only transient queued/network work receives OS retry.
      final watch = Stopwatch()..start();
      while (!stopped && watch.elapsed < const Duration(minutes: 7)) {
        if (session.queue.waitingReason != null) {
          retry = true;
          break;
        }
        final pending = session.queue.jobs.any(
          (v) =>
              session!.queue.canRun(v) &&
              (v.status == TransferStatus.queued ||
                  v.status == TransferStatus.running),
        );
        if (!pending && !session.queue.isBusy) {
          if (settings.backgroundBackup &&
              settings.cameraBackup &&
              await session.backUpCamera() > 0) {
            continue;
          }
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      retry =
          retry ||
          session.queue.jobs.any(
            (v) =>
                session!.queue.canRun(v) &&
                (v.status == TransferStatus.queued ||
                    v.status == TransferStatus.running),
          );
      await session.queue.pruneFinished();
    }
  } catch (_) {
    retry = true;
  } finally {
    try {
      await session?.close();
    } catch (_) {
      retry = true;
    }
    await channel.invokeMethod<void>('complete', {'retry': retry && !stopped});
  }
}
