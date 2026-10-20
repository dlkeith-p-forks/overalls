// `mila-build <linux|android|ios|macos|windows> <dev|release> [--demo] [--dry-run]`
import 'dart:io' as io;

import 'package:mila_build/mila_build.dart';

const String _usage =
    'usage: mila-build <linux|android|ios|macos|windows> <dev|release> [--demo] [--dry-run]';

Future<void> main(List<String> arguments) async {
  final flags = arguments.where((a) => a.startsWith('--')).toSet();
  final positional = arguments.where((a) => !a.startsWith('--')).toList();
  final unknown = flags.difference({'--demo', '--dry-run'});
  final platform = positional.isNotEmpty ? Platform.parse(positional[0]) : null;
  final mode = positional.length > 1 ? Mode.parse(positional[1]) : null;
  if (platform == null || mode == null || positional.length != 2 || unknown.isNotEmpty) {
    io.stderr.writeln(_usage);
    io.exit(64);
  }
  final root = _repositoryRoot();
  final version = _version(root);
  final environment = io.Platform.environment;
  final result = plan(
    platform,
    mode,
    host: _host(),
    inputs: BuildInputs.fromEnvironment(environment, demo: flags.contains('--demo')),
    version: version,
  );
  switch (result) {
    case Refused(:final reason):
      io.stderr.writeln('mila-build: $reason');
      io.exit(2);
    case Planned():
      if (flags.contains('--dry-run')) {
        for (final step in result.steps) {
          io.stdout.writeln(step.describe());
        }
        return;
      }
      try {
        await execute(result, root: root, environment: environment, log: io.stdout.writeln);
      } on BuildFailure catch (failure) {
        io.stderr.writeln('mila-build: $failure');
        io.exit(1);
      }
      for (final artifact in result.artifacts) {
        io.stdout.writeln('built $artifact');
      }
      for (final note in result.notes) {
        io.stdout.writeln('note: $note');
      }
  }
}

Host _host() => switch (io.Platform.operatingSystem) {
  'linux' => Host.linux,
  'macos' => Host.macos,
  'windows' => Host.windows,
  final other => throw UnsupportedError('mila-build does not run on $other'),
};

/// The checkout holding `flake.nix` and `mila/`, found from this script.
String _repositoryRoot() {
  var directory = io.File.fromUri(io.Platform.script).parent;
  while (true) {
    if (io.File('${directory.path}/flake.nix').existsSync() &&
        io.Directory('${directory.path}/mila').existsSync()) {
      return directory.path;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) throw StateError('no repository root above the script');
    directory = parent;
  }
}

/// The app version from `mila/app/pubspec.yaml`, e.g. `0.1.0+1`.
String _version(String root) {
  final pubspec = io.File('$root/mila/app/pubspec.yaml').readAsStringSync();
  final match = RegExp(
    r'^version: ([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+)\s*$',
    multiLine: true,
  ).firstMatch(pubspec);
  if (match == null) throw StateError('mila/app/pubspec.yaml has no version');
  return match[1]!;
}
