import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Keeps Windows from sleeping while phones use this PC. The request appears
/// in `powercfg /requests` with a readable reason and never keeps the display
/// on.
abstract interface class PowerRequest {
  /// Holds the request until [release]; calls nest.
  void acquire();
  void release();
  void dispose();
}

/// Holds [PowerRequest]s for active streams and transfers, and for a short
/// grace period after the last one so a paused video can resume.
final class AwakeTracker {
  AwakeTracker(
    this._request, {
    this.grace = const Duration(seconds: 90),
    bool always = false,
  }) {
    if (always) setAlways(true);
  }

  final PowerRequest? _request;
  final Duration grace;
  var _active = 0;
  var _held = false;
  var _always = false;
  Timer? _graceTimer;

  bool get isHeld => _held;

  /// "Keep PC available": stay awake for as long as the server runs.
  void setAlways(bool value) {
    _always = value;
    _update();
  }

  /// Runs [action] while keeping the PC awake.
  Future<T> during<T>(Future<T> Function() action) async {
    _active++;
    _update();
    try {
      return await action();
    } finally {
      _active--;
      _update();
    }
  }

  void _update() {
    final want = _always || _active > 0;
    if (want) {
      _graceTimer?.cancel();
      _graceTimer = null;
      _hold(true);
    } else if (_held && _graceTimer == null) {
      _graceTimer = Timer(grace, () {
        _graceTimer = null;
        if (!_always && _active == 0) _hold(false);
      });
    }
  }

  void _hold(bool value) {
    if (value == _held) return;
    _held = value;
    value ? _request?.acquire() : _request?.release();
  }

  void dispose() {
    _graceTimer?.cancel();
    _graceTimer = null;
    _hold(false);
    _request?.dispose();
  }
}

/// The platform request, or null where none is available.
PowerRequest? createPowerRequest(String reason) {
  if (!Platform.isWindows) return null;
  try {
    return _WindowsPowerRequest(reason);
  } on Object {
    return null;
  }
}

// REASON_CONTEXT with POWER_REQUEST_CONTEXT_SIMPLE_STRING.
final class _ReasonContext extends Struct {
  @Uint32()
  external int version;
  @Uint32()
  external int flags;
  external Pointer<Utf16> reason;
  @Uint64()
  external int padding0;
  @Uint64()
  external int padding1;
}

typedef _CreateNative = IntPtr Function(Pointer<_ReasonContext>);
typedef _Create = int Function(Pointer<_ReasonContext>);
typedef _SetNative = Int32 Function(IntPtr, Int32);
typedef _Set = int Function(int, int);
typedef _CloseNative = Int32 Function(IntPtr);
typedef _Close = int Function(int);

final class _WindowsPowerRequest implements PowerRequest {
  _WindowsPowerRequest(String reason) {
    final kernel = DynamicLibrary.open('kernel32.dll');
    _set = kernel.lookupFunction<_SetNative, _Set>('PowerSetRequest');
    _clear = kernel.lookupFunction<_SetNative, _Set>('PowerClearRequest');
    _close = kernel.lookupFunction<_CloseNative, _Close>('CloseHandle');
    final create = kernel.lookupFunction<_CreateNative, _Create>(
      'PowerCreateRequest',
    );
    final context = calloc<_ReasonContext>();
    final text = reason.toNativeUtf16();
    try {
      context.ref
        ..version = 0
        ..flags = 1
        ..reason = text;
      _handle = create(context);
    } finally {
      calloc.free(text);
      calloc.free(context);
    }
    if (_handle == 0 || _handle == -1) {
      throw const OSError('PowerCreateRequest failed');
    }
  }

  static const _systemRequired = 1;
  late final _Set _set;
  late final _Set _clear;
  late final _Close _close;
  late int _handle;
  var _depth = 0;

  @override
  void acquire() {
    if (_handle == 0) return;
    if (_depth++ == 0) _set(_handle, _systemRequired);
  }

  @override
  void release() {
    if (_handle == 0 || _depth == 0) return;
    if (--_depth == 0) _clear(_handle, _systemRequired);
  }

  @override
  void dispose() {
    if (_handle == 0) return;
    if (_depth > 0) _clear(_handle, _systemRequired);
    _depth = 0;
    _close(_handle);
    _handle = 0;
  }
}
