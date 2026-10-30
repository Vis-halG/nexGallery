// Builds the Windows PC server executables:
//
//   windows/server/build/bundle/bin/nex_gallery_server.exe  console CLI
//   windows/server/build/bundle/bin/nexgallery_server.exe   background agent
//   windows/server/build/bundle/lib/                       native assets
//
// The agent is the same program with its PE subsystem set to Windows GUI, so
// starting it at sign-in does not open a console window. The Windows app
// build preserves bin/lib below the installed app's server directory.
//
//   dart run tool/build_server.dart

import 'dart:io';
import 'dart:typed_data';

Future<void> main() async {
  final output = Directory('windows/server/build');
  await output.create(recursive: true);
  final cli = File('${output.path}/bundle/bin/nex_gallery_server.exe');
  final result = await Process.run(Platform.resolvedExecutable, [
    'build',
    'cli',
    '--target',
    'windows/server/bin/nex_gallery_server.dart',
    '--output',
    output.path,
  ]);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    exitCode = result.exitCode;
    return;
  }
  final agent = File('${output.path}/bundle/bin/nexgallery_server.exe');
  final bytes = await cli.readAsBytes();
  setWindowsGuiSubsystem(bytes);
  await agent.writeAsBytes(bytes, flush: true);
  stdout.writeln('Built ${cli.path} and ${agent.path}');
}

/// Changes a PE image's subsystem from console (3) to Windows GUI (2).
void setWindowsGuiSubsystem(Uint8List image) {
  final data = ByteData.sublistView(image);
  if (image.length < 0x40 || data.getUint16(0, Endian.little) != 0x5A4D) {
    throw const FormatException('Not a Windows executable.');
  }
  final pe = data.getUint32(0x3C, Endian.little);
  if (pe + 0x60 > image.length ||
      data.getUint32(pe, Endian.little) != 0x00004550) {
    throw const FormatException('Missing PE header.');
  }
  // The optional header starts after the 4-byte signature and the 20-byte
  // file header; Subsystem is at offset 68 for both PE32 and PE32+.
  final subsystem = pe + 24 + 68;
  final current = data.getUint16(subsystem, Endian.little);
  if (current != 3 && current != 2) {
    throw FormatException('Unexpected PE subsystem $current.');
  }
  data.setUint16(subsystem, 2, Endian.little);
}
