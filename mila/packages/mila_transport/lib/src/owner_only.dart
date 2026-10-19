// Owner-only files for Mila's Linux build: device keys, poke keys and
// offline snapshots. Mobile builds keep keys in platform custody instead.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Group and other permission bits.
const int _groupOrOther = 0x3F;

/// `chmod(2)` on [path].
void chmodPath(String path, int mode) {
  final chmod = DynamicLibrary.process()
      .lookupFunction<Int32 Function(Pointer<Utf8>, Uint32), int Function(Pointer<Utf8>, int)>(
        'chmod',
      );
  final native = path.toNativeUtf8();
  try {
    if (chmod(native, mode) != 0) throw FileSystemException('chmod failed', path);
  } finally {
    malloc.free(native);
  }
}

// @cc [owner:ghuntley,label:security] mila-owner-only-files
// Mila's Linux key and cache files MUST be created 0600 inside a 0700
// directory before any byte is written, replaced atomically, and refused
// (never read) when group or other users can access them.
/// Writes [bytes] to [name] in [directory] atomically, owner-only from the
/// first byte.
Future<File> writeOwnerOnly(Directory directory, String name, List<int> bytes) async {
  await directory.create(recursive: true);
  chmodPath(directory.path, 0x1C0); // 0700
  final file = File('${directory.path}/$name');
  final staging = File('${file.path}.new');
  if (await staging.exists()) await staging.delete();
  await staging.create(exclusive: true);
  chmodPath(staging.path, 0x180); // 0600
  await staging.writeAsBytes(bytes, flush: true);
  await staging.rename(file.path);
  return file;
}

/// Reads an owner-only file, or null when it does not exist. Throws when
/// other users could read it.
Future<List<int>?> readOwnerOnly(File file) async {
  if (!await file.exists()) return null;
  if (((await file.stat()).mode & _groupOrOther) != 0) {
    throw FileSystemException('file is readable by other users', file.path);
  }
  return file.readAsBytes();
}
