// An in-memory Porsche for widget tests and the Linux demo flavour. It
// speaks only through the same encoded command lines and JSON envelopes the
// real gateway uses, so features cannot depend on anything else.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
  int vcpu = 2;
  int memoryMib = 4096;
  int diskGib = 50;

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
    'vcpu': vcpu,
    'memory_bytes': memoryMib * 1024 * 1024,
    'disk_bytes': diskGib * 1024 * 1024 * 1024,
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

  /// Registered push devices by id.
  final Map<String, FakeDevice> devices = {};

  /// Grants by machine id, then email: the role name.
  final Map<String, Map<String, String>> shares = {};

  /// When true, `device register` is refused with `push_disabled`.
  bool pushDisabled = false;
  int _nextDevice = 0;

  /// The push keys received on stdin, for assertions that they stay off
  /// command lines.
  final List<String> pushKeys = [];

  /// Agent threads by id.
  final Map<String, FakeThread> threads = {};

  /// Terminal sessions by id.
  final Map<String, FakeTerminal> terminals = {};

  /// Web endpoints by machine id.
  final Map<String, FakeWeb> webs = {};

  /// Text received on stdin for payload commands, for assertions that it
  /// never appears in a command line.
  final List<String> payloads = [];

  /// Open attach channels, newest last.
  final List<FakeAttach> attaches = [];

  final List<StreamController<Uint8List>> _watchers = [];
  int _nextId = 0;

  String _id(String prefix) =>
      '$prefix-0000-4000-8000-${(_nextId++).toRadixString(16).padLeft(12, '0')}';

  /// Sends one `watch` line to every open watch channel.
  void notify(Map<String, Object?> line) {
    final bytes = Uint8List.fromList(utf8.encode('${jsonEncode({'version': 1, ...line})}\n'));
    for (final w in _watchers) {
      if (!w.isClosed) w.add(bytes);
    }
  }

  /// Open watch channels.
  int get watchers => _watchers.where((w) => !w.isClosed).length;
}

/// A fake agent thread.
final class FakeThread {
  FakeThread(this.id, this.title, {this.machineId, this.mode = 'work'});

  final String id;
  final String title;
  final String? machineId;
  String mode;
  bool busy = false;
  int readSequence = 0;
  final List<Map<String, Object?>> events = [];
  Map<String, Object?>? question;
  Map<String, Object?>? plan;
  DateTime updated = DateTime.utc(2026, 10, 18, 9);

  int get lastSequence => events.isEmpty ? 0 : events.last['sequence']! as int;

  void add(String kind, Map<String, Object?> body) {
    events.add({
      'sequence': lastSequence + 1,
      'kind': kind,
      'turn_id': null,
      'body': body,
      'inserted_at': updated.toIso8601String(),
    });
  }

  Map<String, Object?> toJson(String host) => {
    'id': id,
    'title': title,
    'status': 'ready',
    'failure_reason': null,
    'collaboration_mode': mode,
    'machine_id': machineId,
    'team_id': null,
    'mine': true,
    'archived': false,
    'inserted_at': updated.toIso8601String(),
    'updated_at': updated.toIso8601String(),
    'read_sequence': readSequence,
    'last_sequence': lastSequence,
    'unread': lastSequence > readSequence ? lastSequence - readSequence : 0,
    'route': 'overalls://$host/threads/$id',
  };
}

/// A fake terminal session.
final class FakeTerminal {
  FakeTerminal(this.id, this.machineId);
  final String id;
  final String machineId;

  /// Every output byte the session ever produced; attaches replay from it.
  final List<int> output = [];
  int columns = 80;
  int rows = 24;

  Map<String, Object?> toJson(String host) => {
    'id': id,
    'guest_session_id': '3f2e1d0c-9b8a-4766-8544-332211009988',
    'guest_user': 'dev',
    'cols': columns,
    'rows': rows,
    'viewers': 0,
    'created_ms': 1792314891002,
    'last_ms': 1792314951002,
    'mine': true,
    'can_kill': true,
    'kill_status': 'idle',
    'route': 'overalls://$host/machines/$machineId/terminals/$id',
  };
}

/// A fake web endpoint.
final class FakeWeb {
  FakeWeb(this.machineId, {this.port = 8080, this.visibility = 'private', this.url});
  final String machineId;
  int port;
  String visibility;
  int revision = 1;
  String? url;

  Map<String, Object?> toJson(String host) => {
    'machine_id': machineId,
    'label': 'web-box-k3x9',
    'port': port,
    'visibility': visibility,
    'policy_revision': revision,
    'url': url,
    'route': 'overalls://$host/machines/$machineId/web',
  };
}

/// One fake attach channel. The fake gateway echoes input as output and
/// records resizes; tests can end it with any exit status.
final class FakeAttach implements TerminalChannel {
  FakeAttach(
    this.terminal,
    this.line, {
    required int? cursor,
    required this.readOnly,
    required this.size,
  }) {
    final from = cursor == null || cursor > terminal.output.length ? 0 : cursor;
    scheduleMicrotask(() {
      if (_signals.isClosed) return;
      _signals.add(
        AttachHeaderSignal(
          AttachedHeader(
            from: from,
            replayBytes: terminal.output.length - from,
            mode: readOnly ? AttachMode.readOnly : AttachMode.readWrite,
          ),
        ),
      );
      if (terminal.output.length > from) {
        _signals.add(AttachOutputSignal(Uint8List.fromList(terminal.output.sublist(from))));
      }
    });
  }

  final FakeTerminal terminal;
  final String line;
  final bool readOnly;
  TerminalSize size;
  final List<TerminalSize> resizes = [];
  final StreamController<AttachSignal> _signals = StreamController<AttachSignal>();

  /// Input lengths received (never the bytes, mirroring the real gateway's
  /// logging rules).
  final List<int> inputLengths = [];

  @override
  Stream<AttachSignal> get signals => _signals.stream;

  /// Writes output as the shared session would.
  void output(String text) {
    final bytes = utf8.encode(text);
    terminal.output.addAll(bytes);
    if (!_signals.isClosed) _signals.add(AttachOutputSignal(Uint8List.fromList(bytes)));
  }

  @override
  void send(List<int> bytes) {
    if (readOnly) throw StateError('a read-only attachment received input');
    inputLengths.add(bytes.length);
    output(utf8.decode(bytes, allowMalformed: true));
  }

  @override
  void resize(TerminalSize size) {
    this.size = size;
    resizes.add(size);
  }

  /// Ends the channel as Porsche would with [status].
  Future<void> end(int status) async {
    if (_signals.isClosed) return;
    _signals.add(AttachEndSignal(AttachOutcome.fromStatus(status)));
    await _signals.close();
  }

  bool get open => !_signals.isClosed;

  @override
  Future<void> close() => end(0);
}

/// A fake registered push device.
final class FakeDevice {
  FakeDevice(this.id, this.platform, this.encPubkey);

  final String id;
  final String platform;
  final String encPubkey;
  bool enabled = true;

  Map<String, Object?> toJson() => {'id': id, 'platform': platform, 'enabled': enabled};
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
  Future<TerminalChannel> attach(PorscheCommand command, {required TerminalSize size}) async {
    final line = encodeCommand(command);
    _fake.received.add(line);
    final parsed = parseCommandLine(line)!;
    final terminal = _fake.terminals[parsed.arguments[1]];
    if (terminal == null || !_fake.approved) {
      throw const ConnectException(ConnectFailure.unreachable);
    }
    final cursor = parsed.options['cursor'];
    final channel = FakeAttach(
      terminal,
      line,
      cursor: cursor is String ? int.parse(cursor) : null,
      readOnly: parsed.options['read-only'] == true,
      size: size,
    );
    _fake.attaches.add(channel);
    return channel;
  }

  @override
  Future<WatchChannel> watch(PorscheCommand command) async {
    final line = encodeCommand(command);
    _fake.received.add(line);
    final out = StreamController<Uint8List>();
    final exit = Completer<int?>();
    _fake._watchers.add(out);
    final channel = StreamWatchChannel(
      stdout: out.stream,
      exitStatus: exit.future,
      close: () async {
        if (!exit.isCompleted) exit.complete(0);
        _fake._watchers.remove(out);
        await out.close();
      },
    );
    final parsed = parseCommandLine(line)!;
    List<String> ids(String key) => switch (parsed.options[key]) {
      final List<String> list => list,
      final String one => [one],
      _ => const [],
    };
    out.add(
      Uint8List.fromList(
        utf8.encode(
          '${jsonEncode({'version': 1, 'event': 'watching', 'session_id': '019a0f74-4e5f-7a6b-8c7d-8e9f0a1b2c3d', 'machines': ids('machine'), 'threads': ids('thread')})}\n',
        ),
      ),
    );
    return channel;
  }

  @override
  Future<ChannelOutcome> exec(PorscheCommand command, {List<int>? stdin}) async {
    // Round-trip through the wire grammar exactly as Porsche would.
    final line = encodeCommand(command);
    _fake.received.add(line);
    final parsed = parseCommandLine(line)!;
    final (exit, envelope) = _run(parsed, stdin);
    return ChannelOutcome(exit, decodeReplyLine('${jsonEncode(envelope)}\n'));
  }

  (PorscheExit, Map<String, Object?>) _run(PorscheCommand command, List<int>? stdin) {
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
    (PorscheExit, Map<String, Object?>) receipt(String id, Map<String, Object?> result) {
      final receipt = <String, Object?>{
        'version': 1,
        'request_id': id,
        'status': 'succeeded',
        'operation_id': null,
        'result': result,
      };
      _fake._receipts[id] = receipt;
      return (PorscheExit.ok, receipt);
    }

    final client = _client(command, stdin, read, error, receipt);
    if (client != null) return client;
    switch (command.name) {
      case 'device ls':
        return (
          PorscheExit.ok,
          read({
            'items': [for (final d in _fake.devices.values) d.toJson()],
          }),
        );
      case 'device register':
        final id = command.options['request-id']! as String;
        if (_fake.pushDisabled) return (PorscheExit.invalid, error('push_disabled'));
        final key = utf8.decode(stdin ?? const []).trim();
        if (key.isEmpty) return (PorscheExit.invalid, error('invalid_command'));
        _fake.pushKeys.add(key);
        final n = (_fake._nextDevice++).toRadixString(16).padLeft(12, '0');
        final device = FakeDevice(
          'a1b2c3d4-0000-4000-8000-$n',
          command.options['platform']! as String,
          command.options['enc-pubkey']! as String,
        );
        _fake.devices[device.id] = device;
        return receipt(id, {'device': device.toJson()});
      case 'device rm' || 'device prefs':
        final id = command.options['request-id']! as String;
        final device = _fake.devices[command.arguments.single];
        if (device == null) return (PorscheExit.invalid, error('not_found'));
        if (command.name == 'device rm') {
          _fake.devices.remove(device.id);
        } else {
          device.enabled = command.options['enabled'] == 'true';
        }
        return receipt(id, device.toJson());
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
      case 'new':
        final id = command.options['request-id']! as String;
        final created = FakeMachine(_fake._id('7c1e2d3c'), switch (command.options['name']) {
          final String name => name,
          _ => 'machine-${_fake.machines.length + 1}',
        });
        _apply(created, command.options);
        _fake.machines.add(created);
        return receipt(id, created.toJson(_fake.host));
      case 'clone':
        final m = machine();
        if (m == null) return (PorscheExit.invalid, error('not_found'));
        final id = command.options['request-id']! as String;
        final copy = FakeMachine(_fake._id('7c1e2d3c'), switch (command.options['name']) {
          final String name => name,
          _ => '${m.name}-clone',
        });
        _fake.machines.add(copy);
        return receipt(id, copy.toJson(_fake.host));
      case 'resize':
        final m = machine();
        if (m == null) return (PorscheExit.invalid, error('not_found'));
        final id = command.options['request-id']! as String;
        final disk = command.options['disk'];
        if (disk is String && int.parse(disk) < m.diskGib) {
          return (PorscheExit.invalid, error('invalid_vm_size'));
        }
        _apply(m, command.options);
        return receipt(id, m.toJson(_fake.host));
      case 'share show':
        final m = machine();
        if (m == null) return (PorscheExit.invalid, error('not_found'));
        final grants = _fake.shares[m.id] ?? const {};
        return (
          PorscheExit.ok,
          read({
            'owner': {
              'user_id': '00000000-0000-4000-8000-000000000001',
              'email': 'user@${_fake.host}',
              'role': 'owner',
            },
            'items': [
              for (final (index, MapEntry(key: email, value: role)) in grants.entries.indexed)
                {
                  'id':
                      '00000000-0000-4000-8000-${(index + 100).toRadixString(16).padLeft(12, '0')}',
                  'user_id':
                      '00000000-0000-4000-9000-${(index + 100).toRadixString(16).padLeft(12, '0')}',
                  'email': email,
                  'role': role,
                },
            ],
            'next_cursor': null,
          }),
        );
      case 'share add' || 'share remove':
        final m = machine();
        if (m == null) return (PorscheExit.invalid, error('not_found'));
        final id = command.options['request-id']! as String;
        final email = command.arguments[1];
        if (!email.endsWith('@${_fake.host}')) {
          return (PorscheExit.invalid, error('user_not_found'));
        }
        final grants = _fake.shares.putIfAbsent(m.id, () => {});
        if (command.name == 'share add') {
          grants[email] = command.arguments[2];
        } else {
          grants.remove(email);
        }
        return receipt(id, {
          'vm_id': m.id,
          'role': command.name == 'share add' ? command.arguments[2] : 'revoked',
        });
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

  /// Applies `--cpu`, `--memory` (MiB) and `--disk` (GiB) to [machine].
  static void _apply(FakeMachine machine, Map<String, Object> options) {
    if (options['cpu'] case final String cpu) machine.vcpu = int.parse(cpu);
    if (options['memory'] case final String memory) machine.memoryMib = int.parse(memory);
    if (options['disk'] case final String disk) machine.diskGib = int.parse(disk);
  }

  /// Thread, terminal and web commands (ADR-0222, ADR-0223).
  (PorscheExit, Map<String, Object?>)? _client(
    PorscheCommand command,
    List<int>? stdin,
    Map<String, Object?> Function(Map<String, Object?>) read,
    Map<String, Object?> Function(String) error,
    (PorscheExit, Map<String, Object?>) Function(String, Map<String, Object?>) receipt,
  ) {
    final host = _fake.host;
    final requestId = command.options['request-id'];
    String text() {
      final value = utf8.decode(stdin ?? const []);
      _fake.payloads.add(value);
      return value;
    }

    FakeThread? thread() =>
        command.arguments.isEmpty ? null : _fake.threads[command.arguments.first];
    switch (command.name) {
      case 'thread ls':
        final machine = command.options['machine'];
        return (
          PorscheExit.ok,
          read({
            'items': [
              for (final t in _fake.threads.values)
                if (machine == null || t.machineId == machine) t.toJson(host),
            ],
            'next_cursor': null,
          }),
        );
      case 'thread show':
        final t = thread();
        if (t == null) return (PorscheExit.invalid, error('not_found'));
        return (
          PorscheExit.ok,
          read({
            ...t.toJson(host),
            'busy': t.busy,
            'pending_question': t.question,
            'latest_plan': t.plan,
          }),
        );
      case 'thread turns':
        final t = thread();
        if (t == null) return (PorscheExit.invalid, error('not_found'));
        final after = int.parse((command.options['after'] as String?) ?? '0');
        return (
          PorscheExit.ok,
          read({
            'thread_id': t.id,
            'items': [
              for (final e in t.events)
                if ((e['sequence']! as int) > after) e,
            ],
            'next_after': null,
          }),
        );
      case 'thread prompt':
        final t = thread();
        if (t == null) return (PorscheExit.invalid, error('not_found'));
        if (t.busy) return (PorscheExit.invalid, error('thread_busy'));
        t
          ..add('prompt', {'prompt': text()})
          ..add('assistant', {'text': 'On it.'});
        _fake.notify({'event': 'thread', 'id': t.id});
        return receipt(requestId! as String, {
          'thread_id': t.id,
          'turn_id': _fake._id('019a0f71'),
          'status': 'queued',
        });
      case 'thread answer':
        final t = thread();
        final q = t?.question;
        if (t == null || q == null || q['id'] != command.arguments[1]) {
          return (PorscheExit.invalid, error('not_found'));
        }
        final answers = jsonDecode(text());
        if (answers is! Map<String, Object?>) {
          return (PorscheExit.invalid, error('invalid_answers'));
        }
        t
          ..question = null
          ..add('questions_answered', {});
        return receipt(requestId! as String, {
          'thread_id': t.id,
          'question_id': q['id'],
          'status': 'answered',
        });
      case 'thread plan approve' || 'thread plan revise':
        final t = thread();
        final plan = t?.plan;
        if (t == null || plan == null || plan['id'] != command.arguments[1]) {
          return (PorscheExit.invalid, error('stale_proposal'));
        }
        if (command.name == 'thread plan approve') {
          t
            ..plan = {...plan, 'implemented': true}
            ..mode = 'work';
        } else {
          t.add('prompt', {'prompt': text()});
        }
        return receipt(requestId! as String, {
          'thread_id': t.id,
          'plan_id': plan['id'],
          'turn_id': _fake._id('019a0f72'),
          if (command.name == 'thread plan approve')
            'collaboration_mode': 'work'
          else
            'status': 'queued',
        });
      case 'thread mode':
        final t = thread();
        if (t == null) return (PorscheExit.invalid, error('not_found'));
        t.mode = command.arguments[1];
        return receipt(requestId! as String, {
          'thread_id': t.id,
          'collaboration_mode': t.mode,
          'busy': t.busy,
        });
      case 'thread read':
        final t = thread();
        if (t == null) return (PorscheExit.invalid, error('not_found'));
        final seq = int.parse(command.arguments[1]);
        // Monotonic, as Marshall.Threads.ReadMarker.
        if (seq > t.readSequence) t.readSequence = seq > t.lastSequence ? t.lastSequence : seq;
        return receipt(requestId! as String, {
          'thread_id': t.id,
          'read_sequence': t.readSequence,
          'last_sequence': t.lastSequence,
          'unread': t.lastSequence - t.readSequence,
        });
      case 'terminal ls':
        final machine = command.arguments.single;
        return (
          PorscheExit.ok,
          read({
            'machine_id': machine,
            'items': [
              for (final t in _fake.terminals.values)
                if (t.machineId == machine) t.toJson(host),
            ],
          }),
        );
      case 'terminal new':
        final machine = command.arguments.single;
        final terminal = FakeTerminal(_fake._id('019a0f73'), machine);
        _fake.terminals[terminal.id] = terminal;
        _fake.notify({'event': 'terminal_session', 'machine_id': machine});
        return receipt(requestId! as String, {
          'machine_id': machine,
          'session_id': terminal.id,
          'guest_session_id': '3f2e1d0c-9b8a-4766-8544-332211009988',
          'route': 'overalls://$host/machines/$machine/terminals/${terminal.id}',
        });
      case 'terminal kill':
        final removed = _fake.terminals.remove(command.arguments[1]);
        if (removed == null) return (PorscheExit.invalid, error('not_found'));
        for (final a in _fake.attaches) {
          if (a.terminal == removed) unawaited(a.end(0));
        }
        return receipt(requestId! as String, {
          'machine_id': command.arguments[0],
          'session_id': removed.id,
          'closed': true,
        });
      case 'web show':
        final web = _fake.webs[command.arguments.single];
        if (web == null) return (PorscheExit.invalid, error('not_found'));
        return (PorscheExit.ok, read(web.toJson(host)));
      case 'web set':
        final web = _fake.webs[command.arguments.single];
        if (web == null) return (PorscheExit.invalid, error('not_found'));
        final revision = command.options['revision'];
        if (revision != null && revision != '${web.revision}') {
          return (PorscheExit.invalid, error('conflict'));
        }
        final port = command.options['port'];
        if (port is String) web.port = int.parse(port);
        if (command.options['public'] == true) web.visibility = 'public';
        if (command.options['private'] == true) web.visibility = 'private';
        web.revision++;
        return receipt(requestId! as String, web.toJson(host));
    }
    return null;
  }
}
