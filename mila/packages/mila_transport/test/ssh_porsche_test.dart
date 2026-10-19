import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';
import 'package:test/test.dart';

const String _host = 'overalls.test';
const int _now = 1800000000;

final class _MemoryTrust implements TrustStore {
  final Map<String, TrustDocument> documents = {};
  int writes = 0;

  @override
  Future<TrustDocument?> read(String host) async => documents[host];

  @override
  Future<void> write(String host, TrustDocument document) async {
    writes++;
    documents[host] = document;
  }
}

final class _OneKey implements DeviceKeyStore {
  _OneKey(this.key);
  final DeviceKey key;
  @override
  Future<DeviceKey> keyFor(String host) async => key;
}

List<int> _document(String ca, {String host = _host, int retirement = _now + 3600}) => utf8.encode(
  jsonEncode({
    'version': 1,
    'ca': ca,
    'management_host': host,
    'zone': 'machines.$host',
    'retirement': retirement,
  }),
);

String _caLine(int seed) => ed25519KeyLine(List<int>.generate(32, (i) => (seed * 31 + i) % 256));

/// Runs [executable] from PATH with [arguments]; fails the test on error.
Future<String> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  expect(result.exitCode, 0, reason: '$executable ${result.stderr}');
  return result.stdout as String;
}

String? _onPath(String name) {
  for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
    final file = File('$dir/$name');
    if (dir.isNotEmpty && file.existsSync()) return file.resolveSymbolicLinksSync();
  }
  return null;
}

/// A stock OpenSSH server standing in for Porsche: it presents a CA-signed
/// Ed25519 host certificate and runs a script that answers like Porsche.
final class _Sshd {
  _Sshd._(this.dir, this.port, this.process, this.ca);

  final Directory dir;
  final int port;
  final Process process;

  /// The `ssh-ed25519 …` line of the CA that signed the host certificate.
  final String ca;

  /// What the attach stand-in observed about its pty.
  List<String> get attach => File('${dir.path}/attach').existsSync()
      ? File('${dir.path}/attach').readAsLinesSync()
      : const [];

  List<String> get received => File('${dir.path}/received').existsSync()
      ? File('${dir.path}/received').readAsLinesSync()
      : const [];

  static Future<_Sshd> start(
    String sshd,
    DeviceKey device, {
    String principal = _host,
    String validity = '-5m:+1h',
    bool certificate = true,
  }) async {
    final dir = await Directory.systemTemp.createTemp('mila-sshd');
    final path = dir.path;
    for (final name in ['ca', 'host']) {
      await _run('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-f', '$path/$name']);
    }
    await _run('ssh-keygen', [
      '-q', '-s', '$path/ca', '-I', 'porsche', '-h', '-n', principal, '-V', validity, //
      '$path/host.pub',
    ]);
    final ca = File('$path/ca.pub').readAsStringSync().split(' ').take(2).join(' ');
    File(
      '$path/authorized_keys',
    ).writeAsStringSync('$deviceKeyAlgorithm ${base64.encode(device.publicBlob)}\n');
    // Porsche's exec contract: one JSON line on stdout and a closed exit code.
    File('$path/porsche.sh').writeAsStringSync('''#!/bin/sh
printf '%s\\n' "\$SSH_ORIGINAL_COMMAND" >> $path/received
echo "progress for people" >&2
case "\$SSH_ORIGINAL_COMMAND" in
  "whoami --json") printf '%s\\n' '{"version":1,"status":"succeeded","result":{"state":"approved"}}'; exit 0 ;;
  "terminal attach "*)
    # Stands in for a Porsche attach: stock OpenSSH merges stderr into the
    # pty, so only the pty, window change, input relay and exit status are
    # observable here; the header path is tested in channels_test.dart.
    if [ -t 0 ]; then echo "tty=yes" >> $path/attach; else echo "tty=no" >> $path/attach; fi
    echo "size=\$(stty size)" >> $path/attach
    echo "term=\$TERM" >> $path/attach
    printf 'ready\\n'
    read -r line
    echo "size=\$(stty size)" >> $path/attach
    printf 'got:%s\\n' "\$line"
    case "\$line" in revoke) exit 3 ;; *) exit 0 ;; esac ;;
  "watch "*)
    n=\$(cat $path/watches 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > $path/watches
    printf '%s\\n' '{"version":1,"event":"watching","session_id":"019a0f74-4e5f-7a6b-8c7d-8e9f0a1b2c3d","machines":[],"threads":["0d9cc041-9db2-4e4c-b28b-1e41d7f472c1"]}'
    printf '%s\\n' '{"version":1,"event":"thread","id":"0d9cc041-9db2-4e4c-b28b-1e41d7f472c1"}'
    printf '%s\\n' '{"version":1,"event":"heartbeat"}'
    if [ "\$n" -ge 2 ]; then printf '%s\\n' '{"version":1,"status":"error","error":"unauthorized"}'; exit 3; fi
    exit 5 ;;
  *) printf '%s\\n' '{"version":1,"status":"error","error":"invalid_command"}'; exit 2 ;;
esac
''');
    await _run('chmod', ['0755', '$path/porsche.sh']);
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    File('$path/sshd_config').writeAsStringSync('''
Port $port
ListenAddress 127.0.0.1
HostKey $path/host
${certificate ? 'HostCertificate $path/host-cert.pub' : ''}
HostKeyAlgorithms ${certificate ? 'ssh-ed25519-cert-v01@openssh.com,' : ''}ssh-ed25519
PubkeyAcceptedAlgorithms ecdsa-sha2-nistp256
AuthorizedKeysFile $path/authorized_keys
AuthenticationMethods publickey
KbdInteractiveAuthentication no
PasswordAuthentication no
StrictModes no
UsePAM no
PidFile $path/sshd.pid
ForceCommand $path/porsche.sh
LogLevel ERROR
''');
    final process = await Process.start(sshd, ['-D', '-e', '-f', '$path/sshd_config']);
    process.stderr.transform(utf8.decoder).listen(stderr.write);
    for (var i = 0; i < 100; i++) {
      try {
        final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
        socket.destroy();
        return _Sshd._(dir, port, process, ca);
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    process.kill();
    throw StateError('sshd did not start');
  }

  Future<void> stop() async {
    process.kill();
    await process.exitCode;
    await dir.delete(recursive: true);
  }
}

void main() {
  group('trust resolution', () {
    test('a first fetch pins the document', () async {
      final store = _MemoryTrust();
      final (doc, refusal) = await resolveTrust(
        host: _host,
        store: store,
        fetch: (_) async => _document(_caLine(1)),
        now: _now,
      );
      expect(refusal, isNull);
      expect(doc!.ca, _caLine(1));
      expect(store.documents[_host]!.ca, _caLine(1));
    });

    test('a different CA is refused and the pin is kept', () async {
      final store = _MemoryTrust();
      await resolveTrust(
        host: _host,
        store: store,
        fetch: (_) async => _document(_caLine(1)),
        now: _now,
      );
      final (doc, refusal) = await resolveTrust(
        host: _host,
        store: store,
        fetch: (_) async => _document(_caLine(2)),
        now: _now,
      );
      expect(doc, isNull);
      expect(refusal, TrustRefusal.conflicts);
      expect(store.documents[_host]!.ca, _caLine(1));
    });

    test('a document for another host is refused', () async {
      final (doc, refusal) = await resolveTrust(
        host: _host,
        store: _MemoryTrust(),
        fetch: (_) async => _document(_caLine(1), host: 'elsewhere.test'),
        now: _now,
      );
      expect((doc, refusal), (null, TrustRefusal.wrongHost));
    });

    test('an unreachable origin falls back to an unretired pin only', () async {
      final store = _MemoryTrust();
      Future<List<int>> down(Uri _) async => throw const SocketException('down');
      expect(await resolveTrust(host: _host, store: store, fetch: down, now: _now), (null, null));
      await resolveTrust(
        host: _host,
        store: store,
        fetch: (_) async => _document(_caLine(1)),
        now: _now,
      );
      final (pinned, _) = await resolveTrust(host: _host, store: store, fetch: down, now: _now);
      expect(pinned!.ca, _caLine(1));
      expect(await resolveTrust(host: _host, store: store, fetch: down, now: _now + 7200), (
        null,
        null,
      ));
    });

    test('the fetch is HTTPS to the deployment origin', () async {
      Uri? asked;
      await resolveTrust(
        host: _host,
        store: _MemoryTrust(),
        fetch: (uri) async {
          asked = uri;
          return _document(_caLine(1));
        },
        now: _now,
      );
      expect(asked.toString(), 'https://$_host/bin/ssh-trust.json');
    });
  });

  group('host key checks', () {
    final caSeed = List<int>.filled(32, 1);
    final leaf = List<int>.filled(32, 2);
    Uint8List cert({
      List<String> principals = const [_host],
      int after = _now - 60,
      int before = _now + 60,
    }) => issueHostCertificate(
      leaf: leaf,
      caSeed: caSeed,
      nonce: List<int>.filled(32, 3),
      principals: principals,
      serial: 1,
      keyId: 'porsche',
      validAfter: after,
      validBefore: before,
    );

    final trust = TrustDocument(
      ca: parseHostCertificateBlob(cert())!.ca,
      managementHost: _host,
      zone: 'machines.$_host',
      retirement: _now + 60,
    );

    test('a current certificate from the pinned CA naming the host is accepted', () {
      expect(checkHostKey(hostCertificateAlgorithm, cert(), trust, _now), isNull);
    });

    test('every other host key is refused', () {
      expect(checkHostKey('ssh-ed25519', cert(), trust, _now), HostRefusal.malformed);
      expect(
        checkHostKey(hostCertificateAlgorithm, cert(principals: ['other.test']), trust, _now),
        HostRefusal.wrongPrincipal,
      );
      expect(checkHostKey(hostCertificateAlgorithm, cert(), trust, _now + 61), HostRefusal.expired);
      final tampered = cert()..[40] ^= 1;
      expect(checkHostKey(hostCertificateAlgorithm, tampered, trust, _now), isNotNull);
      final other = TrustDocument(
        ca: _caLine(9),
        managementHost: _host,
        zone: 'machines.$_host',
        retirement: _now + 60,
      );
      expect(
        checkHostKey(hostCertificateAlgorithm, cert(), other, _now),
        HostRefusal.wrongAuthority,
      );
    });
  });

  group('against OpenSSH', () {
    final sshd = _onPath('sshd');
    final skip = sshd == null && Platform.environment['MILA_REQUIRE_SSHD'] != '1'
        ? 'sshd is not on PATH'
        : null;
    final device = SoftwareDeviceKey.generate(Random(11)).$1;
    // OpenSSH only admits an existing account; the build sandbox sets no USER.
    final user = (Process.runSync('id', ['-un']).stdout as String).trim();

    SshPorscheConnector connector(_Sshd server, {String? ca, int Function()? clock}) {
      final now = clock ?? () => DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return SshPorscheConnector(
        keys: _OneKey(device),
        trust: _MemoryTrust(),
        fetch: (_) async => _document(ca ?? server.ca, retirement: now() + 3600),
        clock: now,
        username: user,
        open: (_, _) => SSHSocket.connect('127.0.0.1', server.port),
        connectTimeout: const Duration(seconds: 10),
      );
    }

    Future<ConnectFailure?> failure(Future<PorscheSession> session) async {
      try {
        await (await session).close();
        return null;
      } on ConnectException catch (e) {
        return e.failure;
      }
    }

    final whoami = PorscheCommand('whoami', options: const {'json': true});
    final show = PorscheCommand(
      'show',
      arguments: const ['dev-box'],
      options: const {'json': true},
    );

    test(
      'a certified host and the device key run Porsche commands',
      () async {
        final server = await _Sshd.start(sshd!, device);
        addTearDown(server.stop);
        final session = await connector(server).connect(const Deployment(_host), generation: 3);
        expect(session.generation, 3);
        final ok = await session.exec(whoami);
        expect(ok.exit, PorscheExit.ok);
        expect(ok.reply, isA<ReadReply>());
        final refused = await session.exec(show);
        expect(refused.exit, PorscheExit.invalid);
        expect((refused.reply! as ErrorReply).error, 'invalid_command');
        await session.close();
        // Lines arrive exactly as encodeCommand wrote them.
        expect(server.received, [encodeCommand(whoami), encodeCommand(show)]);
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'terminal attach runs on a pty sized to the view, with resize and exit mapping',
      () async {
        final server = await _Sshd.start(sshd!, device);
        addTearDown(server.stop);
        final session = await connector(server).connect(const Deployment(_host), generation: 1);
        addTearDown(session.close);
        final command = const TerminalAttach.initial(
          readOnly: false,
        ).command('dev-box', '019a0f73-3d4e-7f5a-8b6c-7d8e9f0a1b2c');
        Future<(String, AttachOutcome)> run(String line) async {
          final channel = await session.attach(command, size: const TerminalSize(100, 30));
          final out = StringBuffer();
          final ready = Completer<void>();
          AttachOutcome? outcome;
          final done = channel.signals.forEach((signal) {
            switch (signal) {
              case AttachOutputSignal(:final bytes):
                out.write(utf8.decode(bytes, allowMalformed: true));
                if (out.toString().contains('ready') && !ready.isCompleted) ready.complete();
              case AttachEndSignal(outcome: final o):
                outcome = o;
              case AttachHeaderSignal():
                fail('stock OpenSSH sends no stderr header on a pty');
            }
          });
          await ready.future.timeout(const Duration(seconds: 10));
          channel.resize(const TerminalSize(132, 43));
          await Future<void>.delayed(const Duration(milliseconds: 300));
          channel.send(utf8.encode('$line\r'));
          await done.timeout(const Duration(seconds: 10));
          return (out.toString(), outcome!);
        }

        final (output, closed) = await run('hello');
        expect(output, contains('got:hello'));
        expect(closed, AttachOutcome.closed);
        expect(server.attach, containsAllInOrder(['tty=yes', 'size=30 100', 'size=43 132']));
        expect(server.attach, contains('term=xterm-256color'));
        final (_, revoked) = await run('revoke');
        expect(revoked, AttachOutcome.authority);
        expect(server.received.first, encodeCommand(command));
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'a watch feed reads JSON lines, reconnects after exit 5 and stops on exit 3',
      () async {
        final server = await _Sshd.start(sshd!, device);
        addTearDown(server.stop);
        final session = await connector(server).connect(const Deployment(_host), generation: 1);
        addTearDown(session.close);
        final feed = WatchFeed(
          open: session.watch,
          filter: WatchFilter(threads: ['0d9cc041-9db2-4e4c-b28b-1e41d7f472c1']),
        );
        final events = <WatchEvent>[];
        feed.events.listen(events.add);
        final stopped = feed.status.firstWhere((s) => s == FeedStatus.stopped);
        feed.start();
        await stopped.timeout(const Duration(seconds: 30));
        expect(events.whereType<ThreadChanged>(), hasLength(2));
        expect(events.whereType<Watching>(), hasLength(2));
        expect(feed.state.stop, WatchStop.authority);
        expect(server.received.where((l) => l.startsWith('watch ')).toSet(), {
          'watch --json --thread=0d9cc041-9db2-4e4c-b28b-1e41d7f472c1',
        });
        await feed.close();
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'a certificate from another CA is refused before authentication',
      () async {
        final server = await _Sshd.start(sshd!, device);
        addTearDown(server.stop);
        expect(
          await failure(
            connector(server, ca: _caLine(5)).connect(const Deployment(_host), generation: 1),
          ),
          ConnectFailure.hostUntrusted,
        );
        expect(server.received, isEmpty);
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'a certificate for another principal is refused',
      () async {
        final server = await _Sshd.start(sshd!, device, principal: 'elsewhere.test');
        addTearDown(server.stop);
        expect(
          await failure(connector(server).connect(const Deployment(_host), generation: 1)),
          ConnectFailure.hostUntrusted,
        );
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'an expired certificate is refused',
      () async {
        final server = await _Sshd.start(sshd!, device, validity: '20200101:20200102');
        addTearDown(server.stop);
        expect(
          await failure(connector(server).connect(const Deployment(_host), generation: 1)),
          ConnectFailure.hostUntrusted,
        );
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'a host without a certificate cannot negotiate at all',
      () async {
        final server = await _Sshd.start(sshd!, device, certificate: false);
        addTearDown(server.stop);
        expect(
          await failure(connector(server).connect(const Deployment(_host), generation: 1)),
          isNotNull,
        );
        expect(server.received, isEmpty);
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
