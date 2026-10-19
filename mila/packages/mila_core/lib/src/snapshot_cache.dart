/// The offline snapshot of a deployment's machine list: a closed JSON schema
/// with pure merge rules. Snapshots hold only what the machine list shows;
/// never terminal bytes, credentials, tokens or keys (ADR-0220).
library;

import 'dart:convert';

import 'app_route.dart';
import 'machine.dart';

/// The snapshot format version.
const int snapshotVersion = 1;

/// The most machines a snapshot keeps.
const int maximumSnapshotMachines = 500;

/// The largest snapshot file Mila reads.
const int maximumSnapshotBytes = 1 << 20;

/// What Mila last saw of one deployment.
final class MachineSnapshot {
  MachineSnapshot({
    required this.host,
    required this.port,
    required this.savedAt,
    required Iterable<Machine> machines,
  }) : machines = List.unmodifiable(
         (machines.toList()..sort(compareMachines)).take(maximumSnapshotMachines),
       );

  /// The deployment's management host and optional SSH port.
  final String host;
  final int? port;

  /// When the listing was read from the deployment, in UTC.
  final DateTime savedAt;

  /// Pinned first, then by name and id.
  final List<Machine> machines;
}

// @cc [owner:ghuntley,label:security;privacy] mila-snapshot-closed-schema
// A snapshot MUST contain only the listed machine fields, host, port, time
// and version. Decoding MUST refuse unknown keys, another deployment's
// snapshot and anything oversized, so nothing else can be smuggled to disk.
const Set<String> _machineKeys = {
  'id',
  'name',
  'desired_state',
  'observed_state',
  'pinned',
  'owner',
  'permissions',
  'route',
  'image_name',
  'vcpu',
  'memory_bytes',
  'disk_bytes',
  'profile',
  'failure_reason',
};

Map<String, Object?> _encodeMachine(Machine m) => {
  'id': m.id,
  'name': m.name,
  'desired_state': m.desired.name,
  'observed_state': m.observed?.name,
  'pinned': m.pinned,
  'owner': m.owner,
  'permissions': {
    'read': m.permissions.read,
    'write': m.permissions.write,
    'manage': m.permissions.manage,
  },
  'route': m.route?.format(),
  'image_name': m.imageName,
  'vcpu': m.vcpu,
  'memory_bytes': m.memoryBytes,
  'disk_bytes': m.diskBytes,
  'profile': m.profile,
  'failure_reason': m.failureReason,
};

/// Encodes [snapshot] as UTF-8 JSON bytes.
List<int> encodeSnapshot(MachineSnapshot snapshot) => utf8.encode(
  jsonEncode({
    'version': snapshotVersion,
    'host': snapshot.host,
    'port': snapshot.port,
    'saved_at': snapshot.savedAt.toUtc().millisecondsSinceEpoch,
    'machines': [for (final m in snapshot.machines) _encodeMachine(m)],
  }),
);

/// Decodes a snapshot for exactly [host] and [port], or null when it is
/// malformed, oversized, from another version or for another deployment.
MachineSnapshot? decodeSnapshot(List<int> bytes, {required String host, required int? port}) {
  if (bytes.length > maximumSnapshotBytes) return null;
  final Object? value;
  try {
    value = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    return null;
  }
  if (value is! Map<String, Object?>) return null;
  if (value.keys.toSet().difference(const {'version', 'host', 'port', 'saved_at', 'machines'})
      case final extra when extra.isNotEmpty || value.length != 5) {
    return null;
  }
  final savedAt = value['saved_at'];
  final machines = value['machines'];
  if (value['version'] != snapshotVersion ||
      value['host'] != host ||
      value['port'] != port ||
      !isHostname(host) ||
      savedAt is! int ||
      savedAt < 0 ||
      machines is! List<Object?> ||
      machines.length > maximumSnapshotMachines) {
    return null;
  }
  final decoded = <Machine>[];
  for (final item in machines) {
    if (item is! Map<String, Object?> || !_machineKeys.containsAll(item.keys)) return null;
    try {
      decoded.add(decodeMachine(item));
    } on MachineFormatException {
      return null;
    }
  }
  return MachineSnapshot(
    host: host,
    port: port,
    savedAt: DateTime.fromMillisecondsSinceEpoch(savedAt, isUtc: true),
    machines: decoded,
  );
}

/// Merges a fresh complete listing into the cached snapshot. An older
/// listing never replaces a newer one (two refreshes can finish out of
/// order); a newer complete listing replaces the snapshot exactly, so a
/// machine deleted on the deployment leaves the cache too.
MachineSnapshot mergeSnapshot(MachineSnapshot? cached, MachineSnapshot fresh) {
  if (cached == null) return fresh;
  if (cached.host != fresh.host || cached.port != fresh.port) {
    throw ArgumentError('snapshots of different deployments');
  }
  return fresh.savedAt.isBefore(cached.savedAt) ? cached : fresh;
}

/// Applies one machine's newer state, from `show` or a lifecycle receipt,
/// to the snapshot without waiting for the next full listing.
MachineSnapshot updateSnapshotMachine(MachineSnapshot snapshot, Machine machine, DateTime at) {
  if (at.isBefore(snapshot.savedAt)) return snapshot;
  return MachineSnapshot(
    host: snapshot.host,
    port: snapshot.port,
    savedAt: snapshot.savedAt,
    machines: [...snapshot.machines.where((m) => m.id != machine.id), machine],
  );
}
