// The offline snapshot cache on disk: one owner-only JSON file per
// deployment, holding only the closed snapshot schema from mila_core.
import 'dart:io';

import 'package:mila_core/mila_core.dart';

import 'owner_only.dart';
import 'porsche.dart';

/// Reads and writes offline snapshots.
abstract interface class SnapshotStore {
  Future<MachineSnapshot?> read(Deployment deployment);
  Future<void> write(MachineSnapshot snapshot);
  Future<void> delete(Deployment deployment);
}

/// Snapshots under [directory] as `<host>[_<port>].json`, mode 0600.
final class FileSnapshotStore implements SnapshotStore {
  FileSnapshotStore(this.directory);

  final Directory directory;

  String _name(String host, int? port) {
    if (!isHostname(host)) throw ArgumentError.value(host, 'host', 'not a hostname');
    return port == null ? '$host.json' : '${host}_$port.json';
  }

  @override
  Future<MachineSnapshot?> read(Deployment deployment) async {
    final file = File('${directory.path}/${_name(deployment.host, deployment.port)}');
    final List<int>? bytes;
    try {
      bytes = await readOwnerOnly(file);
    } on FileSystemException {
      // A cache other users can read is discarded, never shown.
      await file.delete().catchError((Object _) => file);
      return null;
    }
    if (bytes == null) return null;
    return decodeSnapshot(bytes, host: deployment.host, port: deployment.port);
  }

  @override
  Future<void> write(MachineSnapshot snapshot) async {
    // Merge with what is on disk, so an older refresh finishing late never
    // overwrites a newer snapshot.
    final current = await read(Deployment(snapshot.host, port: snapshot.port));
    final merged = mergeSnapshot(current, snapshot);
    if (identical(merged, current)) return;
    await writeOwnerOnly(directory, _name(snapshot.host, snapshot.port), encodeSnapshot(merged));
  }

  @override
  Future<void> delete(Deployment deployment) async {
    final file = File('${directory.path}/${_name(deployment.host, deployment.port)}');
    if (await file.exists()) await file.delete();
  }
}
