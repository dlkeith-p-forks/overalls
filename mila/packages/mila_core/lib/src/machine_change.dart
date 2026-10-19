/// The machine-creating and reshaping commands Mila sends: `new`, `clone`
/// and `resize` (ADR-0220, plan M1). Each is a physical mutation sent once
/// with `--no-wait` and its own request id, then observed by `request show`.
library;

import 'ssh_command.dart';
import 'workspace_source.dart';

/// A typed form field: empty is valid and absent; anything else must parse.
typedef FieldValue<T> = ({bool valid, T? value});

/// Parses an optional size: blank is absent, otherwise a canonical positive
/// integer no larger than [maximum].
FieldValue<int> parseSize(String text, {required int maximum}) {
  final value = text.trim();
  if (value.isEmpty) return (valid: true, value: null);
  if (value.length > 10) return (valid: false, value: null);
  final n = int.tryParse(value);
  if (n == null || n < 1 || n > maximum || '$n' != value) return (valid: false, value: null);
  return (valid: true, value: n);
}

/// Parses an optional machine name.
FieldValue<String> parseMachineName(String text) {
  final value = text.trim();
  if (value.isEmpty) return (valid: true, value: null);
  return isMachineName(value) ? (valid: true, value: value) : (valid: false, value: null);
}

/// Parses an optional workspace source with the shared grammar, returning
/// its canonical URL.
FieldValue<String> parseSource(String text) {
  final value = text.trim();
  if (value.isEmpty) return (valid: true, value: null);
  return switch (parseWorkspaceSource(value)) {
    SourceAccepted(:final source) => (valid: true, value: source.toUrl()),
    SourceRefused() => (valid: false, value: null),
  };
}

/// The largest CPU and memory values the line grammar accepts; the
/// deployment applies its own shape limits.
const int maximumShapeValue = 2147483647;

/// Requested sizes; an absent size keeps the default (new) or the current
/// size (resize). Memory is in MiB and disk in GiB, as Porsche reads them.
final class MachineShape {
  const MachineShape({this.cpu, this.memoryMib, this.diskGib});

  final int? cpu;
  final int? memoryMib;
  final int? diskGib;

  bool get isEmpty => cpu == null && memoryMib == null && diskGib == null;

  Map<String, Object> get options => {
    'cpu': ?cpu?.toString(),
    'memory': ?memoryMib?.toString(),
    'disk': ?diskGib?.toString(),
  };
}

Map<String, Object> _mutation(String requestId) => {
  'json': true,
  'request-id': requestId,
  'no-wait': true,
};

PorscheCommand? _valid(PorscheCommand command) => validateCommand(command) == null ? command : null;

/// `new`, or null when a value would be refused.
PorscheCommand? createMachineCommand({
  String? name,
  String? source,
  MachineShape shape = const MachineShape(),
  required String requestId,
}) => _valid(
  PorscheCommand(
    'new',
    options: {..._mutation(requestId), 'name': ?name, 'source': ?source, ...shape.options},
  ),
);

/// `clone`, or null when a value would be refused.
PorscheCommand? cloneMachineCommand(String machineId, {String? name, required String requestId}) =>
    _valid(
      PorscheCommand(
        'clone',
        arguments: [machineId],
        options: {..._mutation(requestId), 'name': ?name},
      ),
    );

/// `resize`, or null when nothing changes or a value would be refused.
/// Disk can only grow: a disk below [currentDiskGib] is refused here
/// rather than sent.
PorscheCommand? resizeMachineCommand(
  String machineId,
  MachineShape shape, {
  int? currentDiskGib,
  required String requestId,
}) {
  if (shape.isEmpty) return null;
  final disk = shape.diskGib;
  if (disk != null && currentDiskGib != null && disk < currentDiskGib) return null;
  return _valid(
    PorscheCommand(
      'resize',
      arguments: [machineId],
      options: {..._mutation(requestId), ...shape.options},
    ),
  );
}
