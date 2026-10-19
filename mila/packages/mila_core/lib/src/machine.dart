/// Machines as `ls --json` and `show --json` report them, plus the state
/// label, tone, ordering and search the machine list presents.
library;

import 'app_route.dart';

/// `VirtualMachine.desired_state`.
enum DesiredState { running, stopped, paused, deleted }

/// `VirtualMachine.observed_state`.
enum ObservedState { pending, running, stopped, paused, unknown, failed, deleted }

/// The text label a machine shows, mirroring `WorkspaceComponents.machine_state/1`.
enum StateLabel {
  deleting,
  stopping,
  suspending,
  resuming,
  starting,
  pending,
  running,
  stopped,
  paused,
  failed,
  deleted,
  unknown,
  unavailable,
}

/// The severity a label carries, mirroring `machine_tone/1`. Never colour alone.
enum StateTone { pending, danger, success }

/// What the caller may do with a machine. Presentation only; never authority.
final class MachinePermissions {
  const MachinePermissions({required this.read, required this.write, required this.manage});
  final bool read;
  final bool write;
  final bool manage;
}

/// One machine row. Unknown result keys are ignored (tolerant decoding).
final class Machine {
  const Machine({
    required this.id,
    required this.name,
    required this.desired,
    required this.observed,
    required this.pinned,
    required this.owner,
    required this.permissions,
    this.route,
    this.imageName,
    this.vcpu,
    this.memoryBytes,
    this.diskBytes,
    this.sshHost,
    this.profile,
    this.failureReason,
    this.resizing = false,
    this.relocating = false,
  });

  final String id;
  final String name;
  final DesiredState desired;

  /// Null when the server sent a state this client does not know yet.
  final ObservedState? observed;
  final bool pinned;
  final bool owner;
  final MachinePermissions permissions;
  final MilaRoute? route;
  final String? imageName;
  final int? vcpu;
  final int? memoryBytes;
  final int? diskBytes;
  final String? sshHost;
  final String? profile;
  final String? failureReason;
  final bool resizing;
  final bool relocating;

  StateLabel get label => stateLabel(desired, observed);
  StateTone? get tone => stateTone(desired, observed);
}

/// The label for a desired/observed pair, in the web's clause order.
StateLabel stateLabel(DesiredState desired, ObservedState? observed) {
  if (desired == DesiredState.deleted) return StateLabel.deleting;
  if (desired == DesiredState.stopped && observed == ObservedState.running) {
    return StateLabel.stopping;
  }
  if (desired == DesiredState.paused && observed == ObservedState.running) {
    return StateLabel.suspending;
  }
  if (desired == DesiredState.running && observed == ObservedState.paused) {
    return StateLabel.resuming;
  }
  if (desired == DesiredState.running &&
      (observed == ObservedState.pending || observed == ObservedState.stopped)) {
    return StateLabel.starting;
  }
  return switch (observed) {
    ObservedState.pending => StateLabel.pending,
    ObservedState.running => StateLabel.running,
    ObservedState.stopped => StateLabel.stopped,
    ObservedState.paused => StateLabel.paused,
    ObservedState.failed => StateLabel.failed,
    ObservedState.deleted => StateLabel.deleted,
    ObservedState.unknown => StateLabel.unknown,
    null => StateLabel.unavailable,
  };
}

/// The tone for a desired/observed pair, in the web's clause order.
StateTone? stateTone(DesiredState desired, ObservedState? observed) {
  if (desired == DesiredState.deleted) return StateTone.pending;
  if (desired == DesiredState.stopped && observed == ObservedState.running) {
    return StateTone.pending;
  }
  if ((desired == DesiredState.paused && observed == ObservedState.running) ||
      (desired == DesiredState.running && observed == ObservedState.paused)) {
    return StateTone.pending;
  }
  if (desired == DesiredState.running &&
      (observed == ObservedState.pending || observed == ObservedState.stopped)) {
    return StateTone.pending;
  }
  return switch (observed) {
    ObservedState.failed => StateTone.danger,
    ObservedState.running => StateTone.success,
    ObservedState.pending || ObservedState.unknown => StateTone.pending,
    _ => null,
  };
}

/// Why a machine row could not be decoded.
final class MachineFormatException implements Exception {
  const MachineFormatException(this.field);
  final String field;
  @override
  String toString() => 'MachineFormatException($field)';
}

T? _enum<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

int? _int(Object? value) => value is int && value >= 0 ? value : null;
String? _string(Object? value) => value is String ? value : null;

/// Decodes one machine object. Identity and authority fields are strict;
/// descriptive fields are optional so newer servers stay readable.
Machine decodeMachine(Map<String, Object?> value) {
  final id = value['id'];
  if (id is! String || !isCanonicalUuid(id)) throw const MachineFormatException('id');
  final name = value['name'];
  if (name is! String || name.isEmpty) throw const MachineFormatException('name');
  final desired = _enum(DesiredState.values, value['desired_state']);
  if (desired == null) throw const MachineFormatException('desired_state');
  final permissions = value['permissions'];
  if (permissions is! Map<String, Object?>) throw const MachineFormatException('permissions');
  final routeText = value['route'];
  final route = routeText is String ? parseMilaRoute(routeText) : null;
  // A route naming a different machine is ignored rather than followed.
  final page = route?.page;
  final safeRoute = page is MachinePage && page.machineId == id ? route : null;
  return Machine(
    id: id,
    name: name,
    desired: desired,
    observed: _enum(ObservedState.values, value['observed_state']),
    pinned: value['pinned'] == true,
    owner: value['owner'] == true,
    permissions: MachinePermissions(
      read: permissions['read'] == true,
      write: permissions['write'] == true,
      manage: permissions['manage'] == true,
    ),
    route: safeRoute,
    imageName: _string(value['image_name']),
    vcpu: _int(value['vcpu']),
    memoryBytes: _int(value['memory_bytes']),
    diskBytes: _int(value['disk_bytes']),
    sshHost: _string(value['ssh_host']),
    profile: _string(value['profile']),
    failureReason: _string(value['failure_reason']),
    resizing: value['resize'] is Map,
    relocating: value['relocation'] is Map,
  );
}

/// One `ls` page.
final class MachineListing {
  const MachineListing(this.items, this.nextCursor);
  final List<Machine> items;
  final String? nextCursor;
}

/// Decodes an `ls --json` result. Rows that fail strict fields are skipped
/// and counted, never shown half-decoded.
(MachineListing, int skipped) decodeMachineList(Map<String, Object?> result) {
  final items = result['items'];
  if (items is! List<Object?>) throw const MachineFormatException('items');
  final machines = <Machine>[];
  var skipped = 0;
  for (final item in items) {
    try {
      if (item is! Map<String, Object?>) throw const MachineFormatException('item');
      machines.add(decodeMachine(item));
    } on MachineFormatException {
      skipped++;
    }
  }
  final next = result['next_cursor'];
  final cursor = next is String && isCanonicalUuid(next) ? next : null;
  return (MachineListing(List.unmodifiable(machines), cursor), skipped);
}

/// Pinned machines first, then by name, then by id for a total order.
int compareMachines(Machine a, Machine b) {
  if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
  final byName = a.name.compareTo(b.name);
  return byName != 0 ? byName : a.id.compareTo(b.id);
}

/// Filters [machines] by a case-insensitive query over name, image and
/// state label, then orders them with [compareMachines].
List<Machine> searchMachines(Iterable<Machine> machines, String query) {
  final terms = query.toLowerCase().split(RegExp(r'\s+')).where((term) => term.isNotEmpty).toList();
  bool matches(Machine machine) {
    final haystack = [
      machine.name,
      machine.imageName ?? '',
      machine.label.name,
      if (machine.pinned) 'pinned',
    ].join(' ').toLowerCase();
    return terms.every(haystack.contains);
  }

  return machines.where(matches).toList()..sort(compareMachines);
}
