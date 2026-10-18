// mila-probe: drives Mila's production transport from the command line so
// NixOS machine tests can check it against a real Porsche. It prints one JSON
// line describing the outcome and never prints key material or reply bodies.
//
//   mila-probe --host HOST [--port N] --trust FILE --keys DIR --command LINE
//   mila-probe --keys DIR --host HOST --public-key
import 'dart:convert';
import 'dart:io';

import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

/// Holds the pin for this one run; the document itself comes from `--trust`
/// in place of the HTTPS fetch, so the test controls which CA is pinned.
final class _RunTrust implements TrustStore {
  TrustDocument? _pinned;
  @override
  Future<TrustDocument?> read(String host) async => _pinned;
  @override
  Future<void> write(String host, TrustDocument document) async => _pinned = document;
}

Never _usage(String message) {
  stderr.writeln('mila-probe: $message');
  exit(64);
}

Future<void> main(List<String> arguments) async {
  final options = <String, String>{};
  var publicKey = false;
  for (var i = 0; i < arguments.length; i++) {
    final name = arguments[i];
    if (name == '--public-key') {
      publicKey = true;
    } else if (name.startsWith('--') && i + 1 < arguments.length) {
      options[name.substring(2)] = arguments[++i];
    } else {
      _usage('unexpected argument $name');
    }
  }
  final host = options['host'] ?? _usage('--host is required');
  final keysPath = options['keys'] ?? _usage('--keys is required');
  if (!isHostname(host)) _usage('--host is not a hostname');
  final keys = FileDeviceKeyStore(Directory(keysPath));
  if (publicKey) {
    final key = await keys.keyFor(host);
    stdout.writeln('$deviceKeyAlgorithm ${base64.encode(key.publicBlob)}');
    return;
  }
  final trustPath = options['trust'] ?? _usage('--trust is required');
  final line = options['command'] ?? _usage('--command is required');
  final command = parseCommandLine(line) ?? _usage('--command is not a Porsche command');
  final port = int.tryParse(options['port'] ?? '') ?? defaultPorschePort;
  final connector = SshPorscheConnector(
    keys: keys,
    trust: _RunTrust(),
    fetch: (_) => File(trustPath).readAsBytes(),
    clock: () => DateTime.now().millisecondsSinceEpoch ~/ 1000,
  );
  stdout.writeln(jsonEncode(await _probe(connector, Deployment(host, port: port), command)));
}

Future<Map<String, Object?>> _probe(
  SshPorscheConnector connector,
  Deployment deployment,
  PorscheCommand command,
) async {
  try {
    final session = await connector.connect(deployment, generation: 1);
    final outcome = await session.exec(command);
    await session.close();
    return {
      'connected': true,
      'exit': outcome.exit.name,
      'reply': switch (outcome.reply) {
        ReadReply() => 'read',
        ReceiptReply() => 'receipt',
        ApprovalReply() => 'approval_required',
        ErrorReply(:final error) => 'error:$error',
        null => null,
      },
    };
  } on ConnectException catch (e) {
    return {'connected': false, 'failure': e.failure.name};
  }
}
