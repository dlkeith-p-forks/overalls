/// Porsche v1 command lines: the subset of the catalog Mila sends, an encoder
/// that always produces lines Porsche's parser reads back unchanged, and a
/// port of `OverallsProtocol.SSHCommand` lexing used to prove that.
///
/// Both sides are tested against `protocol/test/fixtures/ssh_command_lines.json`.
library;

import 'dart:convert';
import 'dart:math';

import 'app_route.dart' show isCanonicalUuid;
import 'workspace_source.dart';

/// Porsche refuses lines longer than this many UTF-8 bytes.
const int maximumLineBytes = 8192;

/// Mila never emits more tokens than this, staying under Porsche's lexer cap.
const int maximumTokens = 32;

/// Porsche refuses more options than this on one command.
const int maximumOptions = 12;

const Set<String> _booleans = {'json', 'no-wait', 'peer'};

/// One catalog row: positional bounds, extra options and request kind.
final class CommandSpec {
  const CommandSpec(
    this.name, {
    this.minArguments = 0,
    this.maxArguments = 0,
    this.options = const [],
    this.mutation = false,
    this.physical = false,
  });

  final String name;
  final int minArguments;
  final int maxArguments;
  final List<String> options;

  /// Mutations carry a client-allocated `--request-id`.
  final bool mutation;

  /// Physical mutations also accept `--timeout` and `--no-wait`.
  final bool physical;

  /// Every option Porsche accepts on this command.
  Set<String> get allowedOptions => {
    'json',
    ...options,
    if (mutation) 'request-id',
    if (physical) ...['timeout', 'no-wait'],
  };
}

/// The catalog rows Mila uses, mirroring `OverallsProtocol.SSHCommand`.
const Map<String, CommandSpec> catalog = {
  'whoami': CommandSpec('whoami'),
  'images': CommandSpec('images'),
  'ls': CommandSpec('ls', options: ['after']),
  'show': CommandSpec('show', minArguments: 1, maxArguments: 1),
  'new': CommandSpec(
    'new',
    options: ['name', 'image', 'profile', 'cpu', 'memory', 'disk', 'team', 'source'],
    mutation: true,
    physical: true,
  ),
  'clone': CommandSpec(
    'clone',
    minArguments: 1,
    maxArguments: 1,
    options: ['name'],
    mutation: true,
    physical: true,
  ),
  'resize': CommandSpec(
    'resize',
    minArguments: 1,
    maxArguments: 1,
    options: ['cpu', 'memory', 'disk'],
    mutation: true,
    physical: true,
  ),
  'start': CommandSpec('start', minArguments: 1, maxArguments: 1, mutation: true, physical: true),
  'pause': CommandSpec('pause', minArguments: 1, maxArguments: 1, mutation: true, physical: true),
  'resume': CommandSpec('resume', minArguments: 1, maxArguments: 1, mutation: true, physical: true),
  'unpause': CommandSpec(
    'unpause',
    minArguments: 1,
    maxArguments: 1,
    mutation: true,
    physical: true,
  ),
  'stop': CommandSpec('stop', minArguments: 1, maxArguments: 1, mutation: true, physical: true),
  'rm': CommandSpec('rm', minArguments: 1, maxArguments: 1, mutation: true, physical: true),
  'pin': CommandSpec('pin', minArguments: 1, maxArguments: 1, mutation: true),
  'unpin': CommandSpec('unpin', minArguments: 1, maxArguments: 1, mutation: true),
  'share show': CommandSpec('share show', minArguments: 1, maxArguments: 1, options: ['after']),
  'share add': CommandSpec('share add', minArguments: 3, maxArguments: 3, mutation: true),
  'share remove': CommandSpec('share remove', minArguments: 2, maxArguments: 2, mutation: true),
  'ssh-key list': CommandSpec('ssh-key list'),
  'ssh-key remove': CommandSpec('ssh-key remove', minArguments: 1, maxArguments: 1, mutation: true),
  'request show': CommandSpec('request show', minArguments: 1, maxArguments: 1),
  'request retry': CommandSpec(
    'request retry',
    minArguments: 1,
    maxArguments: 1,
    mutation: true,
    physical: true,
  ),
  'request cancel': CommandSpec(
    'request cancel',
    minArguments: 1,
    maxArguments: 1,
    mutation: true,
    physical: true,
  ),
  'team list': CommandSpec('team list', options: ['after']),
};

/// A structured Porsche command before encoding.
final class PorscheCommand {
  PorscheCommand(
    this.name, {
    List<String> arguments = const [],
    Map<String, Object> options = const {},
  }) : arguments = List<String>.unmodifiable(arguments),
       options = Map<String, Object>.unmodifiable(options);

  final String name;
  final List<String> arguments;

  /// Values are `String`, or `true` for boolean flags.
  final Map<String, Object> options;

  @override
  bool operator ==(Object other) =>
      other is PorscheCommand &&
      other.name == name &&
      _listEquals(other.arguments, arguments) &&
      other.options.length == options.length &&
      options.entries.every((entry) => other.options[entry.key] == entry.value);

  @override
  int get hashCode => Object.hash(
    name,
    Object.hashAll(arguments),
    Object.hashAllUnordered(options.entries.map((e) => Object.hash(e.key, e.value))),
  );

  @override
  String toString() => 'PorscheCommand($name, $arguments, $options)';
}

bool _listEquals(List<String> a, List<String> b) =>
    a.length == b.length && Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

/// Why Mila refused to build a command line.
enum CommandRefusal {
  unknownCommand,
  argumentCount,
  invalidArgument,
  unknownOption,
  invalidOption,
  tooManyOptions,
  tooLarge,
}

/// Thrown only for programming errors: Mila code built an invalid command.
final class CommandRefused implements Exception {
  const CommandRefused(this.reason);
  final CommandRefusal reason;
  @override
  String toString() => 'CommandRefused(${reason.name})';
}

final RegExp _machineName = RegExp(
  r'^(?![0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$)[a-z][a-z0-9]*(?:-[a-z0-9]+)*$',
);
final RegExp _requestId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]*$');
final RegExp _image = RegExp(r'^sha256:[0-9a-f]{64}$');
final RegExp _team = RegExp(r'^[a-z][a-z0-9-]{0,61}[a-z0-9]$|^[a-z]$');
final RegExp _control = RegExp(r'[\x00-\x1f\x7f\x80-\x9f  ]');

/// Whether [name] is a machine name, as `OverallsProtocol.MachineName.valid?`.
bool isMachineName(String name) {
  final bytes = utf8.encode(name).length;
  return bytes >= 1 && bytes <= 63 && _machineName.hasMatch(name);
}

/// Whether [value] names a machine by name or canonical UUID.
bool isMachineReference(String value) => isMachineName(value) || isCanonicalUuid(value);

/// Whether [value] is a valid request id.
bool isRequestId(String value) =>
    value.isNotEmpty && value.length <= 128 && _requestId.hasMatch(value);

bool _positive(String value, int maximum) {
  if (value.isEmpty || value.length > 10) return false;
  final n = int.tryParse(value);
  return n != null && n > 0 && n <= maximum && n.toString() == value;
}

bool _text(String value) {
  final bytes = utf8.encode(value).length;
  return bytes >= 1 && bytes <= 4096 && !_control.hasMatch(value);
}

/// Disk maximum shared with `OverallsProtocol.VMShape`.
const int maximumDiskGib = 500;

bool _optionValid(String key, Object value) {
  if (_booleans.contains(key)) return value == true;
  if (value is! String) return false;
  return switch (key) {
    'name' => isMachineName(value),
    'after' => isCanonicalUuid(value),
    'team' => value.length <= 63 && _team.hasMatch(value),
    'image' => _image.hasMatch(value),
    'profile' => const ['customer', 'standard', 'oss', 'inception'].contains(value),
    'source' => parseWorkspaceSource(value) is SourceAccepted,
    'request-id' => isRequestId(value),
    'timeout' => _positive(value, 3600),
    'disk' => _positive(value, maximumDiskGib),
    'cpu' || 'memory' => _positive(value, 2147483647),
    _ => false,
  };
}

bool _argumentsValid(String name, List<String> args) => switch ((name, args)) {
  (
    'show' ||
        'start' ||
        'pause' ||
        'resume' ||
        'unpause' ||
        'stop' ||
        'rm' ||
        'pin' ||
        'unpin' ||
        'clone' ||
        'resize' ||
        'share show',
    [final machine],
  ) =>
    isMachineReference(machine),
  ('share add', [final machine, final email, final role]) =>
    isMachineReference(machine) &&
        utf8.encode(email).length <= 320 &&
        const ['viewer', 'operator', 'manager'].contains(role),
  ('share remove', [final machine, final email]) =>
    isMachineReference(machine) && utf8.encode(email).length <= 320,
  ('ssh-key remove', [final id]) => isCanonicalUuid(id),
  ('request show' || 'request retry' || 'request cancel', [final id]) => isRequestId(id),
  (_, []) => true,
  _ => false,
};

/// Validates [command] against Mila's catalog, or returns why it is refused.
CommandRefusal? validateCommand(PorscheCommand command) {
  final spec = catalog[command.name];
  if (spec == null) return CommandRefusal.unknownCommand;
  final count = command.arguments.length;
  if (count < spec.minArguments || count > spec.maxArguments) return CommandRefusal.argumentCount;
  if (!command.arguments.every(_text)) return CommandRefusal.invalidArgument;
  if (command.options.length > maximumOptions) return CommandRefusal.tooManyOptions;
  final allowed = spec.allowedOptions;
  for (final MapEntry(:key, :value) in command.options.entries) {
    if (!allowed.contains(key)) return CommandRefusal.unknownOption;
    if (!_optionValid(key, value)) return CommandRefusal.invalidOption;
  }
  if (!_argumentsValid(command.name, command.arguments)) return CommandRefusal.invalidArgument;
  return null;
}

/// Allocates a request id in Porsche's own `porsche-<32 hex>` shape.
String allocateRequestId([Random? random]) {
  final source = random ?? Random.secure();
  final hex = List<String>.generate(
    16,
    (_) => source.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  return 'porsche-$hex';
}

final RegExp _bare = RegExp(r'^[A-Za-z0-9@%+=:,./_-]+$');

String _quote(String token) {
  if (_bare.hasMatch(token)) return token;
  // Single quotes take every byte literally; a quote closes, is escaped, reopens.
  return "'${token.replaceAll("'", r"'\''")}'";
}

/// Encodes a validated command as one Porsche line. Options come first so a
/// positional argument beginning with `--` follows the `--` separator.
String encodeCommand(PorscheCommand command) {
  final refusal = validateCommand(command);
  if (refusal != null) throw CommandRefused(refusal);
  final keys = command.options.keys.toList()..sort();
  final tokens = <String>[
    ...command.name.split(' '),
    for (final key in keys)
      if (command.options[key] == true)
        '--$key'
      else
        '--$key=${_quote(command.options[key]! as String)}',
    if (command.arguments.any((arg) => arg.startsWith('-'))) '--',
    ...command.arguments.map(_quote),
  ];
  final line = tokens.join(' ');
  if (tokens.length > maximumTokens || utf8.encode(line).length > maximumLineBytes) {
    throw const CommandRefused(CommandRefusal.tooLarge);
  }
  return line;
}

/// Lexes [line] exactly as `OverallsProtocol.SSHCommand.lex/6`, or returns
/// null when Porsche would refuse it.
List<String>? lexCommandLine(String line) {
  final bytes = utf8.encode(line);
  if (bytes.length > maximumLineBytes) return null;
  if (bytes.contains(0) || bytes.contains(0x0A) || bytes.contains(0x0D)) return null;
  const plain = 0, single = 1, double = 2;
  var mode = plain;
  var started = false;
  var escaped = false;
  final current = <int>[];
  final tokens = <List<int>>[];
  void finish() {
    if (started) tokens.add(List<int>.of(current));
    current.clear();
  }

  for (final byte in bytes) {
    if (tokens.length > maximumTokens) return null;
    if (escaped) {
      current.add(byte);
      started = true;
      escaped = false;
    } else if (byte == 0x5C && mode != single) {
      started = true;
      escaped = true;
    } else if (byte == 0x27 && mode != double) {
      mode = mode == plain ? single : plain;
      started = true;
    } else if (byte == 0x22 && mode != single) {
      mode = mode == plain ? double : plain;
      started = true;
    } else if ((byte == 0x20 || byte == 0x09) && mode == plain) {
      finish();
      started = false;
    } else {
      current.add(byte);
      started = true;
    }
  }
  if (tokens.length > maximumTokens || mode != plain || escaped) return null;
  finish();
  try {
    return [for (final token in tokens) utf8.decode(token)];
  } on FormatException {
    return null;
  }
}

/// Parses [line] structurally as Porsche does: lexing, command grouping and
/// option collection. Catalog validation is [validateCommand].
PorscheCommand? parseCommandLine(String line) {
  final tokens = lexCommandLine(line);
  if (tokens == null || tokens.isEmpty) return null;
  final (name, rest) = switch (tokens) {
    ['team', final sub, final sub2, ...final rest] when sub == 'member' || sub == 'transfer' => (
      'team $sub $sub2',
      rest,
    ),
    [final group, final sub, ...final rest]
        when const ['share', 'ssh-key', 'request', 'integration', 'team'].contains(group) =>
      ('$group $sub', rest),
    [final name, ...final rest] => (name, rest),
    _ => throw StateError('unreachable: tokens is non-empty'),
  };
  final arguments = <String>[];
  final options = <String, Object>{};
  var positional = false;
  for (var i = 0; i < rest.length; i++) {
    final token = rest[i];
    if (!positional && token == '--') {
      positional = true;
    } else if (!positional && token.startsWith('--')) {
      final flag = token.substring(2);
      final equals = flag.indexOf('=');
      final String key;
      final Object value;
      if (equals >= 0) {
        key = flag.substring(0, equals);
        value = flag.substring(equals + 1);
      } else if (_booleans.contains(flag)) {
        key = flag;
        value = true;
      } else if (i + 1 < rest.length) {
        key = flag;
        value = rest[++i];
      } else {
        return null;
      }
      // Mila never sends repeatable integration headers.
      if (options.containsKey(key)) return null;
      options[key] = value;
      positional = false;
    } else {
      arguments.add(token);
    }
  }
  return PorscheCommand(name, arguments: arguments, options: options);
}
