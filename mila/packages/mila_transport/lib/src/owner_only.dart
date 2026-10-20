// Owner-only files: device keys (Linux), poke keys (Linux), offline
// snapshots, preferences and probe state. Mode bits on POSIX; a protected
// owner-only DACL on Windows (owner_only_windows.dart). The other builds keep
// keys in platform custody instead.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'owner_only_windows.dart';

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
// Mila's key and cache files MUST be created 0600 inside a 0700 directory
// (on Windows: under a protected DACL for the current user and SYSTEM only)
// before any byte is written, replaced atomically, and refused (never read)
// when other users can access them.
/// Writes [bytes] to [name] in [directory] atomically, owner-only from the
/// first byte.
Future<File> writeOwnerOnly(Directory directory, String name, List<int> bytes) async {
  await directory.create(recursive: true);
  _restrict(directory.path, directory: true);
  final file = File('${directory.path}/$name');
  final staging = File('${file.path}.new');
  if (await staging.exists()) await staging.delete();
  await staging.create(exclusive: true);
  _restrict(staging.path, directory: false);
  await staging.writeAsBytes(bytes, flush: true);
  await staging.rename(file.path);
  return file;
}

/// Reads an owner-only file, or null when it does not exist. Throws when
/// other users could read it.
Future<List<int>?> readOwnerOnly(File file) async {
  if (!await file.exists()) return null;
  final shared = Platform.isWindows
      ? !pathIsOwnerOnly(file.path)
      : ((await file.stat()).mode & _groupOrOther) != 0;
  if (shared) throw FileSystemException('file is readable by other users', file.path);
  return file.readAsBytes();
}

/// Restricts [path] to its owner: 0700 or 0600, or the owner-only DACL.
void _restrict(String path, {required bool directory}) {
  if (Platform.isWindows) {
    protectPath(path, directory: directory);
  } else {
    chmodPath(path, directory ? 0x1C0 : 0x180); // 0700 : 0600
  }
}
