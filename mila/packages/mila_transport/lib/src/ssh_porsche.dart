// The real Porsche transport: one SSH connection per deployment, verified
// against the deployment's pinned SSH CA (ADR-0228) and authenticated with
// the device key. There is no trust-on-first-use and no unsigned fallback:
// a host that cannot prove a certificate from the pinned CA is refused.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:mila_core/mila_core.dart';

import 'channels.dart';
import 'device_key.dart';
import 'porsche.dart';

/// Porsche's SSH port when a deployment names none.
const int defaultPorschePort = 22;

/// The most stdout one command may return; Porsche replies are small JSON.
const int maximumReplyBytes = 1 << 20;

/// Pinned trust documents, by management host.
abstract interface class TrustStore {
  Future<TrustDocument?> read(String host);
  Future<void> write(String host, TrustDocument document);
}

/// Fetches `https://HOST/bin/ssh-trust.json`; throws on any transport error.
typedef TrustFetch = Future<List<int>> Function(Uri uri);

/// Opens the TCP socket for a deployment's SSH endpoint.
typedef SocketOpen = Future<SSHSocket> Function(String host, int port);

/// Seconds since the epoch.
typedef EpochClock = int Function();

/// The trust document Mila should verify a deployment against, or why none
/// is usable. A failed fetch falls back to an unretired pinned document, and
/// with none to fall back to yields `(null, null)`: the host is unreachable,
/// not refused. A fetched document that changes the pinned authority is
/// refused.
Future<(TrustDocument?, TrustRefusal?)> resolveTrust({
  required String host,
  required TrustStore store,
  required TrustFetch fetch,
  required int now,
}) async {
  final pinned = await store.read(host);
  final usablePin = pinned != null && pinned.retirement > now ? pinned : null;
  final List<int> bytes;
  try {
    bytes = await fetch(Uri(scheme: 'https', host: host, path: '/bin/ssh-trust.json'));
  } on Exception {
    return (usablePin, null);
  }
  final (fetched, refusal) = decodeTrustDocument(bytes, originHost: host, now: now);
  if (fetched == null) return (null, refusal);
  final (trusted, conflict) = reconcileTrust(pinned, fetched);
  if (trusted == null) return (null, conflict);
  if (!identical(trusted, pinned)) await store.write(host, trusted);
  return (trusted, null);
}

/// Decides whether the host key blob a server signed the exchange with is a
/// valid certificate from [trust]'s CA naming its management host.
HostRefusal? checkHostKey(String algorithm, Uint8List blob, TrustDocument trust, int now) {
  if (algorithm != hostCertificateAlgorithm) return HostRefusal.malformed;
  final certificate = parseHostCertificateBlob(blob);
  if (certificate == null) return HostRefusal.malformed;
  return verifyHostCertificate(
    certificate,
    ca: trust.ca,
    principal: trust.managementHost,
    now: now,
  );
}

final class SshPorscheConnector implements PorscheConnector {
  SshPorscheConnector({
    required this.keys,
    required this.trust,
    required this.fetch,
    required this.clock,
    SocketOpen? open,
    this.username = 'mila',
    this.connectTimeout = const Duration(seconds: 15),
  }) : _open = open ?? ((host, port) => SSHSocket.connect(host, port, timeout: connectTimeout));

  final DeviceKeyStore keys;
  final TrustStore trust;
  final TrustFetch fetch;
  final EpochClock clock;

  /// Porsche ignores the SSH username; identity is the proved key. Only a
  /// stock OpenSSH server in tests needs a real account name here.
  final String username;
  final Duration connectTimeout;
  final SocketOpen _open;

  @override
  Future<PorscheSession> connect(Deployment deployment, {required int generation}) async {
    final (document, refusal) = await resolveTrust(
      host: deployment.host,
      store: trust,
      fetch: fetch,
      now: clock(),
    );
    if (document == null) {
      throw ConnectException(
        refusal == null ? ConnectFailure.unreachable : ConnectFailure.hostUntrusted,
      );
    }
    final key = await keys.keyFor(deployment.host);
    final SSHSocket socket;
    try {
      socket = await _open(deployment.host, deployment.port ?? defaultPorschePort);
    } on Exception {
      throw const ConnectException(ConnectFailure.unreachable);
    }
    HostRefusal? refused;
    final client = SSHClient(
      socket,
      username: username,
      algorithms: const SSHAlgorithms(hostkey: [SSHHostkeyType.ed25519Cert]),
      onVerifyHostKeyBlob: (algorithm, blob) {
        refused = checkHostKey(algorithm, blob, document, clock());
        return refused == null;
      },
      identities: [
        SSHIdentity.custom(
          type: deviceKeyAlgorithm,
          publicKey: SSHRawHostKey(key.publicBlob),
          signer: (data) async => SSHRawSignature(await key.sign(data)),
          // Probe first: a hardware signature may prompt the user.
          shouldProbe: true,
        ),
      ],
    );
    try {
      await client.authenticated.timeout(connectTimeout);
    } on Object catch (error) {
      unawaited(client.close().catchError((Object _) {}));
      if (refused != null || error is SSHHostkeyError) {
        throw const ConnectException(ConnectFailure.hostUntrusted);
      }
      throw const ConnectException(ConnectFailure.unreachable);
    }
    return _SshPorscheSession(client, generation);
  }
}

final class _SshPorscheSession implements PorscheSession {
  _SshPorscheSession(this._client, this.generation);

  final SSHClient _client;

  @override
  final int generation;

  @override
  Future<void> get closed => _client.done.catchError((Object _) {});

  @override
  Future<ChannelOutcome> exec(PorscheCommand command, {List<int>? stdin}) async {
    final session = await _client.execute(encodeCommand(command));
    // Progress lines on stderr are for people; drain them unread so they
    // never hold back the window stdout needs.
    final progress = session.stderr.drain<void>();
    if (stdin != null) session.stdin.add(Uint8List.fromList(stdin));
    await session.stdin.close();
    final out = BytesBuilder(copy: false);
    var overflow = false;
    await for (final chunk in session.stdout) {
      if (out.length + chunk.length > maximumReplyBytes) {
        overflow = true;
        session.close();
        break;
      }
      out.add(chunk);
    }
    await session.done;
    await progress.catchError((Object _) {});
    final exit = PorscheExit.fromCode(session.exitCode ?? -1);
    if (overflow || exit == null) return const ChannelOutcome(PorscheExit.failed, null);
    final bytes = out.takeBytes();
    if (bytes.isEmpty) return ChannelOutcome(exit, null);
    try {
      return ChannelOutcome(exit, decodeReplyLine(utf8.decode(bytes)));
    } on ReplyFormatException {
      return const ChannelOutcome(PorscheExit.failed, null);
    } on FormatException {
      return const ChannelOutcome(PorscheExit.failed, null);
    }
  }

  // @cc [owner:ghuntley,label:protocol;security] mila-attach-pty-channel
  // `terminal attach` MUST run on its own exec channel after a pty request
  // sized to the view; window changes are sent only through resize, and the
  // channel's bytes are relayed, never stored or logged.
  @override
  Future<TerminalChannel> attach(PorscheCommand command, {required TerminalSize size}) async {
    if (command.name != 'terminal attach') {
      throw ArgumentError.value(command.name, 'command', 'not terminal attach');
    }
    final clamped = size.clamped;
    final session = await _client.execute(
      encodeCommand(command),
      pty: SSHPtyConfig(width: clamped.columns, height: clamped.rows),
    );
    return StreamTerminalChannel(
      stdout: session.stdout,
      stderr: session.stderr,
      exitStatus: session.done.then((_) => session.exitCode),
      write: session.write,
      resize: (size) => session.resizeTerminal(size.columns, size.rows),
      close: () async => session.close(),
    );
  }

  @override
  Future<WatchChannel> watch(PorscheCommand command) async {
    if (command.name != 'watch') throw ArgumentError.value(command.name, 'command', 'not watch');
    final session = await _client.execute(encodeCommand(command));
    unawaited(session.stderr.drain<void>().catchError((Object _) {}));
    return StreamWatchChannel(
      stdout: session.stdout,
      exitStatus: session.done.then((_) => session.exitCode),
      close: () async => session.close(),
    );
  }

  @override
  Future<void> close() async {
    await _client.close().catchError((Object _) {});
    await closed;
  }
}

/// Fetches a trust document with the platform HTTP client: HTTPS only, the
/// system trust store, no redirects, bounded size and time.
Future<List<int>> fetchTrustDocument(Uri uri) async {
  if (uri.scheme != 'https') throw ArgumentError.value(uri.scheme, 'uri', 'not HTTPS');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(uri)
      ..followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('status ${response.statusCode}', uri: uri);
    }
    final body = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 10))) {
      body.add(chunk);
      if (body.length > 8192) throw HttpException('trust document too large', uri: uri);
    }
    return body.takeBytes();
  } finally {
    client.close(force: true);
  }
}
