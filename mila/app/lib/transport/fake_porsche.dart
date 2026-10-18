// An in-memory Porsche for widget tests and the Linux demo flavour. It
// speaks only through the same encoded command lines and JSON envelopes the
// real gateway uses, so features cannot depend on anything else.
import 'dart:async';
import 'dart:convert';

import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

/// A fake machine row.
final class FakeMachine {
  FakeMachine(this.id, this.name, {this.desired = 'running', this.observed = 'running'});

  final String id;
  final String name;
  String desired;
  String observed;
  bool pinned = false;

  Map<String, Object?> toJson(String host) => {
    'id': id,
    'name': name,
    'desired_state': desired,
    'observed_state': observed,
    'pinned': pinned,
    'owner': true,
    'permissions': {'read': true, 'write': true, 'manage': true},
    'route': 'overalls://$host/machines/$id',
    'image_name': 'NixOS',
    'vcpu': 2,
    'memory_bytes': 4096 * 1024 * 1024,
    'disk_bytes': 50 * 1024 * 1024 * 1024,
    'ssh_host': '$name.ssh.$host',
    'profile': 'standard',
    'resize': null,
    'relocation': null,
  };
}

/// A deployment's fake state, shared by every connection to it.
final class FakeDeployment {
  FakeDeployment(this.host, {List<FakeMachine>? machines, this.approved = false})
    : machines = machines ?? [];

  final String host;
  final List<FakeMachine> machines;
  bool approved;

  /// When true, the host presents a certificate from the wrong authority.
  bool untrusted = false;
  final Map<String, Map<String, Object?>> _receipts = {};

  /// Every line the fake received, for assertions.
  final List<String> received = [];
}

final class FakePorscheConnector implements PorscheConnector {
  FakePorscheConnector(this.deployments);

  final Map<String, FakeDeployment> deployments;

  @override
  Future<PorscheSession> connect(Deployment deployment, {required int generation}) async {
    final fake = deployments[deployment.host];
    if (fake == null) throw const ConnectException(ConnectFailure.unreachable);
    if (fake.untrusted) throw const ConnectException(ConnectFailure.hostUntrusted);
    return _FakeSession(fake, generation);
  }
}

final class _FakeSession implements PorscheSession {
  _FakeSession(this._fake, this.generation);

  final FakeDeployment _fake;
  @override
  final int generation;
  final Completer<void> _closed = Completer<void>();

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<void> close() async {
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<ChannelOutcome> exec(PorscheCommand command, {List<int>? stdin}) async {
    // Round-trip through the wire grammar exactly as Porsche would.
    final line = encodeCommand(command);
    _fake.received.add(line);
    final parsed = parseCommandLine(line)!;
    final (exit, envelope) = _run(parsed);
    return ChannelOutcome(exit, decodeReplyLine('${jsonEncode(envelope)}\n'));
  }

  (PorscheExit, Map<String, Object?>) _run(PorscheCommand command) {
    if (!_fake.approved) {
      return (
        PorscheExit.authority,
        {
          'version': 1,
          'status': 'approval_required',
          'fingerprint': 'SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU',
          'approval_url': 'https://${_fake.host}/ssh/approve/fake-$generation',
          'message': 'Approve this key in your browser, then retry the command.',
        },
      );
    }
    FakeMachine? machine() {
      final ref = command.arguments.first;
      for (final m in _fake.machines) {
        if (m.id == ref || m.name == ref) return m;
      }
      return null;
    }

    Map<String, Object?> read(Map<String, Object?> result) => {
      'version': 1,
      'status': 'succeeded',
      'result': result,
    };
    Map<String, Object?> error(String reason) => {'version': 1, 'status': 'error', 'error': reason};
    switch (command.name) {
      case 'whoami':
        return (PorscheExit.ok, read({'email': 'user@${_fake.host}'}));
      case 'ls':
        return (
          PorscheExit.ok,
          read({
            'items': [for (final m in _fake.machines) m.toJson(_fake.host)],
            'next_cursor': null,
          }),
        );
      case 'show':
        final m = machine();
        return m == null
            ? (PorscheExit.invalid, error('not_found'))
            : (PorscheExit.ok, read(m.toJson(_fake.host)));
      case 'request show':
        final receipt = _fake._receipts[command.arguments.single];
        return receipt == null
            ? (PorscheExit.invalid, error('request_not_found'))
            : (PorscheExit.ok, receipt);
      case 'start' || 'stop' || 'pause' || 'resume' || 'rm' || 'pin' || 'unpin':
        final m = machine();
        if (m == null) return (PorscheExit.invalid, error('not_found'));
        final id = command.options['request-id']! as String;
        final physical = catalog[command.name]!.physical;
        switch (command.name) {
          case 'start' || 'resume':
            m
              ..desired = 'running'
              ..observed = 'running';
          case 'stop':
            m
              ..desired = 'stopped'
              ..observed = 'stopped';
          case 'pause':
            m
              ..desired = 'paused'
              ..observed = 'paused';
          case 'rm':
            if (m.pinned) return (PorscheExit.invalid, error('machine_pinned'));
            _fake.machines.remove(m);
          case 'pin':
            m.pinned = true;
          case 'unpin':
            m.pinned = false;
        }
        final receipt = <String, Object?>{
          'version': 1,
          'request_id': id,
          'status': 'succeeded',
          'operation_id': physical ? '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1' : null,
          'result': <String, Object?>{},
        };
        _fake._receipts[id] = receipt;
        return (PorscheExit.ok, receipt);
    }
    return (PorscheExit.invalid, error('invalid_command'));
  }
}
