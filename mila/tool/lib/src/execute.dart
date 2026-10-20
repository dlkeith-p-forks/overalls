// Runs a plan's steps on this machine. Everything that depends on the host
// (tool lookup, the pinned Flutter check, source preparation) lives here;
// what to run lives in plan.dart.
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';

import 'plan.dart';

/// Why a build stopped.
final class BuildFailure implements Exception {
  const BuildFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Runs [planned] from the repository [root] with the caller's [environment].
Future<void> execute(
  Planned planned, {
  required String root,
  required Map<String, String> environment,
  required void Function(String) log,
}) async {
  final runs = planned.steps.whereType<Run>();
  if (runs.any((r) => r.executable == 'flutter')) {
    await _checkFlutter(root, environment);
    _checkSources(root);
  }
  for (final step in planned.steps) {
    log('» ${step.describe()}');
    switch (step) {
      case Run():
        await _run(step, root, environment);
      case CopyTree(:final from, :final to):
        await _copyTree(io.Directory(_path(root, from)), io.Directory(_path(root, to)));
      case WriteManifest():
        await _writeManifest(step, root);
      case Checksums(:final directory, :final files):
        final lines = [
          for (final name in files)
            '${_sha256(await io.File(_path(root, '$directory/$name')).readAsBytes())}  $name',
        ];
        await io.File(_path(root, '$directory/SHA256SUMS')).writeAsString('${lines.join('\n')}\n');
    }
  }
}

String _path(String root, String relative) =>
    relative == '.' ? root : '$root${io.Platform.pathSeparator}$relative';

Future<void> _run(Run step, String root, Map<String, String> inherited) async {
  final environment = Map.of(inherited)
    ..removeWhere((key, _) => step.remove.contains(key))
    ..addAll(step.environment);
  if (step.appleToolchain) {
    final rsync = _gnuRsync(inherited['PATH'] ?? '');
    environment['PATH'] = [
      rsync,
      '/usr/bin',
      '/bin',
      '/usr/sbin',
      '/sbin',
      inherited['PATH'] ?? '',
    ].join(':');
    environment['DEVELOPER_DIR'] =
        inherited['MILA_XCODE_DEVELOPER_DIR'] ?? '/Applications/Xcode.app/Contents/Developer';
  }
  final executable = _resolve(step.executable, environment);
  final process = await io.Process.start(
    executable,
    step.arguments,
    workingDirectory: _path(root, step.directory),
    environment: environment,
    includeParentEnvironment: false,
    // flutter is a batch file on Windows.
    runInShell: io.Platform.isWindows && step.executable == 'flutter',
    mode: io.ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;
  if (code != 0) throw BuildFailure('${step.executable} exited with $code');
}

/// The directory of an rsync that is not macOS's openrsync.
String _gnuRsync(String path) {
  for (final directory in path.split(':')) {
    if (directory.isEmpty || directory == '/usr/bin' || directory == '/bin') continue;
    if (io.File('$directory/rsync').existsSync()) return directory;
  }
  throw const BuildFailure(
    'Apple builds need GNU rsync on PATH (macOS openrsync drops the --chmod Flutter passes); '
    'run inside `devenv shell`',
  );
}

/// The Windows SDK tools come from MILA_WINDOWS_SDK_BIN, PATH, or the newest
/// installed Windows 10/11 SDK.
String _resolve(String executable, Map<String, String> environment) {
  if (!executable.endsWith('.exe')) return executable;
  final configured = environment['MILA_WINDOWS_SDK_BIN'];
  if (configured != null && io.File('$configured\\$executable').existsSync()) {
    return '$configured\\$executable';
  }
  for (final directory in (environment['PATH'] ?? '').split(';')) {
    if (directory.isNotEmpty && io.File('$directory\\$executable').existsSync()) {
      return '$directory\\$executable';
    }
  }
  final kits = io.Directory(r'C:\Program Files (x86)\Windows Kits\10\bin');
  if (kits.existsSync()) {
    final versions =
        kits
            .listSync()
            .whereType<io.Directory>()
            .map((d) => d.path)
            .where((p) => io.File('$p\\x64\\$executable').existsSync())
            .toList()
          ..sort();
    if (versions.isNotEmpty) return '${versions.last}\\x64\\$executable';
  }
  throw BuildFailure('$executable not found: install the Windows SDK or set MILA_WINDOWS_SDK_BIN');
}

Future<void> _checkFlutter(String root, Map<String, String> environment) async {
  final result = await io.Process.run(
    'flutter',
    ['--version', '--machine'],
    environment: environment,
    includeParentEnvironment: false,
    runInShell: io.Platform.isWindows,
  );
  final Object? decoded;
  try {
    decoded = jsonDecode(result.stdout as String);
  } on FormatException {
    throw const BuildFailure('flutter --version --machine printed no JSON');
  }
  final version = decoded is Map<String, Object?> ? decoded['frameworkVersion'] : null;
  if (version != pinnedFlutter) {
    throw BuildFailure('Flutter $pinnedFlutter is pinned (ADR-0227); found $version');
  }
}

/// The patched dartssh2 and the Noto fonts come from Nix: devenv links them,
/// and on Windows the `mila-source-bundle` carries copies.
void _checkSources(String root) {
  final required = {
    'mila/packages/mila_transport/.nix/dartssh2/pubspec.yaml': 'the patched dartssh2',
    'mila/app/assets/fonts/noto/noto-mono.ttf': 'the pinned Noto fonts',
  };
  for (final entry in required.entries) {
    if (!io.File(_path(root, entry.key)).existsSync()) {
      throw BuildFailure(
        '${entry.value} is missing (${entry.key}): enter `devenv shell`, or on Windows unpack '
        'the mila-source-bundle',
      );
    }
  }
}

Future<void> _copyTree(io.Directory from, io.Directory to) async {
  if (!from.existsSync()) throw BuildFailure('${from.path} does not exist');
  if (to.existsSync()) await to.delete(recursive: true);
  await to.create(recursive: true);
  await for (final entity in from.list(recursive: true, followLinks: false)) {
    final relative = entity.path.substring(from.path.length + 1);
    final target = '${to.path}${io.Platform.pathSeparator}$relative';
    switch (entity) {
      case io.Directory():
        await io.Directory(target).create(recursive: true);
      case io.File():
        await io.File(target).parent.create(recursive: true);
        await entity.copy(target);
      case io.Link():
        await io.Link(target).create(await entity.target());
    }
  }
}

Future<void> _writeManifest(WriteManifest step, String root) async {
  final template = await io.File(_path(root, step.template)).readAsString();
  final manifest = template
      .replaceAll('@PUBLISHER@', const HtmlEscape(HtmlEscapeMode.attribute).convert(step.publisher))
      .replaceAll('@VERSION@', step.version);
  final leftover = RegExp(r'@[A-Z_]+@').firstMatch(manifest);
  if (leftover != null) throw BuildFailure('${step.template} has an unknown ${leftover[0]}');
  final file = io.File(_path(root, step.to));
  await file.parent.create(recursive: true);
  await file.writeAsString(manifest);
}

String _sha256(List<int> bytes) => SHA256Digest()
    .process(Uint8List.fromList(bytes))
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();
