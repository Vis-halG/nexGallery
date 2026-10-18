import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Reads the NTFS/ReFS identity that survives renames and moves within a
/// drive, in the same form as the Windows runner's `fileIdentities` channel:
/// `winfile_<volume>_<file id>_<creation time>`. Returns null on other
/// platforms and on drives without stable IDs, such as FAT.
String? windowsFileIdentity(String path) {
  if (!Platform.isWindows) return null;
  return (_api ??= _FileIdApi()).identity(path);
}

_FileIdApi? _api;

typedef _CreateFileNative = IntPtr Function(
  Pointer<Utf16>,
  Uint32,
  Uint32,
  Pointer<Void>,
  Uint32,
  Uint32,
  IntPtr,
);
typedef _CreateFile = int Function(
  Pointer<Utf16>,
  int,
  int,
  Pointer<Void>,
  int,
  int,
  int,
);
typedef _InfoNative = Int32 Function(IntPtr, Int32, Pointer<Uint8>, Uint32);
typedef _Info = int Function(int, int, Pointer<Uint8>, int);
typedef _CloseNative = Int32 Function(IntPtr);
typedef _Close = int Function(int);

final class _FileIdApi {
  _FileIdApi() {
    final kernel = DynamicLibrary.open('kernel32.dll');
    _create = kernel.lookupFunction<_CreateFileNative, _CreateFile>(
      'CreateFileW',
    );
    _info = kernel.lookupFunction<_InfoNative, _Info>(
      'GetFileInformationByHandleEx',
    );
    _close = kernel.lookupFunction<_CloseNative, _Close>('CloseHandle');
  }

  static const _readAttributes = 0x80;
  static const _shareAll = 0x7;
  static const _openExisting = 3;
  static const _backupSemantics = 0x02000000;
  static const _openReparsePoint = 0x00200000;
  static const _fileBasicInfo = 0;
  static const _fileIdInfo = 18;
  static const _directory = 0x10;
  static const _reparsePoint = 0x400;

  late final _CreateFile _create;
  late final _Info _info;
  late final _Close _close;

  String? identity(String path) {
    final native = _extendedPath(File(path).absolute.path).toNativeUtf16();
    final buffer = calloc<Uint8>(64);
    try {
      final handle = _create(
        native,
        _readAttributes,
        _shareAll,
        nullptr,
        _openExisting,
        _backupSemantics | _openReparsePoint,
        0,
      );
      if (handle == -1 || handle == 0) return null;
      try {
        if (_info(handle, _fileIdInfo, buffer, 24) == 0) return null;
        final id = Uint8List.fromList(buffer.asTypedList(24));
        if (_info(handle, _fileBasicInfo, buffer, 40) == 0) return null;
        final basic = ByteData.sublistView(buffer.asTypedList(40));
        final attributes = basic.getUint32(32, Endian.little);
        if (attributes & (_directory | _reparsePoint) != 0) return null;
        final created = _hex64(basic, 0);
        final volume = _hex64(ByteData.sublistView(id), 0);
        final fileId = id
            .sublist(8)
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join();
        if (RegExp(r'^0+$').hasMatch(fileId)) return null;
        return 'winfile_${volume}_${fileId}_$created';
      } finally {
        _close(handle);
      }
    } finally {
      calloc.free(buffer);
      calloc.free(native);
    }
  }

  static String _hex64(ByteData data, int offset) =>
      data
          .getUint32(offset + 4, Endian.little)
          .toRadixString(16)
          .padLeft(8, '0') +
      data.getUint32(offset, Endian.little).toRadixString(16).padLeft(8, '0');

  /// `\\?\` lifts the 260-character limit for deep folders.
  static String _extendedPath(String path) {
    final windows = path.replaceAll('/', r'\');
    if (windows.startsWith(r'\\?\')) return windows;
    if (windows.startsWith(r'\\')) return '\\\\?\\UNC\\${windows.substring(2)}';
    return '\\\\?\\$windows';
  }
}
