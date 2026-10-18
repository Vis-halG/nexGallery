import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Small secrets (the PC's TLS private key and the owner secret) encrypted
/// with Windows DPAPI for the signed-in user, so copying the files to another
/// account or PC does not reveal them. Other platforms keep them in the
/// app-private folder as before.
abstract final class ProtectedFile {
  static final _magic = ascii.encode('NEXDPAPI1\n');

  static bool isProtected(List<int> bytes) =>
      bytes.length > _magic.length && _startsWith(bytes, _magic);

  /// Reads a protected or older plain file. Plain files on Windows are
  /// protected in place.
  static Future<Uint8List> read(File file) async {
    final bytes = await file.readAsBytes();
    if (isProtected(bytes)) {
      return _Dpapi.instance.unprotect(bytes.sublist(_magic.length));
    }
    if (Platform.isWindows) await write(file, bytes);
    return bytes;
  }

  static Future<void> write(File file, List<int> secret) async {
    await file.parent.create(recursive: true);
    final data = Platform.isWindows
        ? <int>[..._magic, ..._Dpapi.instance.protect(secret)]
        : secret;
    // The app and the agent may migrate the same file at once.
    final temporary = File('${file.path}.$pid.tmp');
    await temporary.writeAsBytes(data, flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  static bool _startsWith(List<int> bytes, List<int> prefix) {
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }
}

// DATA_BLOB: a 32-bit length followed by a pointer.
final class _Blob extends Struct {
  @Uint32()
  external int length;
  external Pointer<Uint8> data;
}

typedef _CryptNative = Int32 Function(
  Pointer<_Blob>,
  Pointer<Utf16>,
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<_Blob>,
);
typedef _Crypt = int Function(
  Pointer<_Blob>,
  Pointer<Utf16>,
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_Blob>,
);
typedef _UnprotectNative = Int32 Function(
  Pointer<_Blob>,
  Pointer<Pointer<Utf16>>,
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<_Blob>,
);
typedef _Unprotect = int Function(
  Pointer<_Blob>,
  Pointer<Pointer<Utf16>>,
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_Blob>,
);
typedef _LocalFreeNative = IntPtr Function(Pointer<Void>);
typedef _LocalFree = int Function(Pointer<Void>);

final class _Dpapi {
  _Dpapi._() {
    final crypt = DynamicLibrary.open('crypt32.dll');
    _protect = crypt.lookupFunction<_CryptNative, _Crypt>('CryptProtectData');
    _unprotect = crypt.lookupFunction<_UnprotectNative, _Unprotect>(
      'CryptUnprotectData',
    );
    _free = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<_LocalFreeNative, _LocalFree>('LocalFree');
  }

  static final instance = _Dpapi._();
  static const _uiForbidden = 0x1;

  late final _Crypt _protect;
  late final _Unprotect _unprotect;
  late final _LocalFree _free;

  Uint8List protect(List<int> secret) {
    final description = 'nexGallery'.toNativeUtf16();
    try {
      return _run(
        secret,
        (input, output) => _protect(
          input,
          description,
          nullptr,
          nullptr,
          nullptr,
          _uiForbidden,
          output,
        ),
      );
    } finally {
      calloc.free(description);
    }
  }

  Uint8List unprotect(List<int> blob) => _run(
    blob,
    (input, output) => _unprotect(
      input,
      nullptr,
      nullptr,
      nullptr,
      nullptr,
      _uiForbidden,
      output,
    ),
  );

  Uint8List _run(
    List<int> bytes,
    int Function(Pointer<_Blob> input, Pointer<_Blob> output) call,
  ) {
    final input = calloc<_Blob>();
    final output = calloc<_Blob>();
    final buffer = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      input.ref
        ..length = bytes.length
        ..data = buffer;
      if (call(input, output) == 0) {
        throw const FileSystemException(
          'Windows could not unlock a nexGallery secret for this user.',
        );
      }
      final result = Uint8List.fromList(
        output.ref.data.asTypedList(output.ref.length),
      );
      _free(output.ref.data.cast());
      return result;
    } finally {
      // Plain secret bytes do not linger in native memory.
      buffer
          .asTypedList(bytes.isEmpty ? 1 : bytes.length)
          .fillRange(0, bytes.isEmpty ? 1 : bytes.length, 0);
      calloc.free(buffer);
      calloc.free(input);
      calloc.free(output);
    }
  }
}
