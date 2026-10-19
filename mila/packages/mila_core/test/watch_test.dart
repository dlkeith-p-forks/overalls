import 'dart:convert';

import 'package:hegel/hegel.dart';
import 'package:mila_core/mila_core.dart';
import 'package:test/test.dart';

const String _machine = '019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a';
const String _thread = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';
const String _session = '019a0f74-4e5f-7a6b-8c7d-8e9f0a1b2c3d';

final List<String> _lines = [
  jsonEncode({
    'version': 1,
    'event': 'watching',
    'session_id': _session,
    'machines': [_machine],
    'threads': [_thread],
  }),
  jsonEncode({'version': 1, 'event': 'thread', 'id': _thread}),
  jsonEncode({'version': 1, 'event': 'machine', 'id': _machine}),
  jsonEncode({'version': 1, 'event': 'terminal_session', 'machine_id': _machine}),
  jsonEncode({'version': 1, 'event': 'resync'}),
  jsonEncode({'version': 1, 'event': 'heartbeat'}),
  jsonEncode({'version': 1, 'event': 'session', 'id': _session, 'status': 'authenticated'}),
  jsonEncode({'version': 1, 'event': 'later_kind', 'anything': 1}),
];

/// Every transition a watch channel can report, for the supervisor model.
final class SupervisorMachine extends StateMachine {
  WatchSupervisor state = const WatchSupervisor.initial();
  WatchSupervisor? stoppedAt;

  int _generation(TestCase tc) => tc.draw(
    oneOf([just(state.generation), integers(min: 0, max: state.generation + 1)]),
    name: 'generation',
  );

  @override
  List<Rule> get rules => [
    Rule('open', (tc) => state = state.open()),
    Rule('line', (tc) {
      final event = tc.draw(
        sampledFrom<WatchEvent>(const [Heartbeat(), Resync(), WatchRefused('forbidden')]),
        name: 'event',
      );
      state = state.received(_generation(tc), event);
    }),
    Rule('ended', (tc) {
      final exit = tc.draw(sampledFrom<PorscheExit?>([null, ...PorscheExit.values]), name: 'exit');
      state = state.ended(_generation(tc), exit);
    }),
    Rule('close', (tc) => state = state.close()),
  ];

  @override
  List<Invariant> get invariants => [
    Invariant('stopped is final', (tc) {
      if (stoppedAt != null) expect(state.phase, WatchPhase.stopped);
      if (state.phase == WatchPhase.stopped) stoppedAt ??= state;
    }),
    Invariant('authority failures never retry', (tc) {
      if (state.stop == WatchStop.authority) expect(state.phase, WatchPhase.stopped);
    }),
    Invariant('waiting always has a bounded delay', (tc) {
      if (state.phase == WatchPhase.waiting) {
        expect(state.attempts, greaterThan(0));
        expect(
          WatchSupervisor.backoff.ceiling(state.attempts),
          lessThanOrEqualTo(WatchSupervisor.backoff.cap),
        );
      }
    }),
  ];
}

void main() {
  test('every event kind decodes', () {
    final events = _lines.map(decodeWatchLine).toList();
    expect(events.map((e) => e.runtimeType), [
      Watching,
      ThreadChanged,
      MachineChanged,
      TerminalSessionsChanged,
      Resync,
      Heartbeat,
      SessionNotice,
      UnknownWatchEvent,
    ]);
    expect((events[6] as SessionNotice).authenticated, isTrue);
    expect(
      decodeWatchLine('{"version":1,"status":"error","error":"forbidden"}'),
      isA<WatchRefused>().having((e) => e.error, 'error', 'forbidden'),
    );
  });

  test('envelopes and identifiers are strict', () {
    for (final line in [
      '{"version":2,"event":"heartbeat"}',
      '{"event":"heartbeat"}',
      '{"version":1,"event":"thread","id":"not-a-uuid"}',
      '{"version":1,"event":7}',
      '[1]',
      'heartbeat',
      '{"version":1,"event":"watching","session_id":"$_session","machines":"x","threads":[]}',
    ]) {
      expect(() => decodeWatchLine(line), throwsA(isA<WatchFormatException>()), reason: line);
    }
  });

  property('framing is independent of chunk boundaries', (tc) {
    final picked = tc.draw(lists(sampledFrom(_lines), maxLength: 10), name: 'lines');
    final stream = utf8.encode(picked.map((l) => '$l\n').join());
    final cuts = tc.draw(lists(integers(min: 0, max: stream.length), maxLength: 8), name: 'cuts')
      ..sort();
    final framer = LineFramer();
    final out = <String>[];
    var start = 0;
    for (final cut in [...cuts, stream.length]) {
      out.addAll(framer.add(stream.sublist(start, cut)));
      start = cut;
    }
    expect(out, picked);
    expect(framer.pending, 0);
  });

  test('a line longer than the limit is refused', () {
    final framer = LineFramer();
    expect(
      () => framer.add(List<int>.filled(maximumWatchLineBytes + 1, 0x61)),
      throwsA(isA<WatchFormatException>()),
    );
    expect(() => LineFramer().add([0xff, 0x0a]), throwsA(isA<WatchFormatException>()));
  });

  test('filters encode to a valid, bounded watch command', () {
    final filter = WatchFilter(machines: [_machine, _machine], threads: [_thread, _session]);
    final line = encodeCommand(filter.command());
    expect(line, 'watch --json --machine=$_machine --thread=$_session --thread=$_thread');
    expect(parseCommandLine(line), filter.command());
    final many = WatchFilter(
      threads: [
        for (var i = 0; i < 40; i++)
          '0d9cc041-9db2-4e4c-b28b-${i.toRadixString(16).padLeft(12, '0')}',
      ],
    );
    expect(many.threads, hasLength(maximumWatchFilters));
    expect(validateCommand(many.command()), isNull);
    expect(WatchFilter().isEmpty, isTrue);
    expect(validateCommand(WatchFilter().command()), CommandRefusal.invalidOption);
  });

  test('the supervisor retries transport loss and stops on authority loss', () {
    var s = const WatchSupervisor.initial().open();
    s = s.received(1, const Heartbeat());
    expect((s.phase, s.attempts), (WatchPhase.live, 0));
    s = s.ended(1, PorscheExit.unavailable);
    expect((s.phase, s.attempts), (WatchPhase.waiting, 1));
    s = s.open().ended(2, null);
    expect(s.attempts, 2);
    s = s.open().ended(3, PorscheExit.authority);
    expect((s.phase, s.stop), (WatchPhase.stopped, WatchStop.authority));
    expect(identical(s.open(), s), isTrue);
  });

  property('the watch supervisor matches its model', (tc) => runStateful(tc, SupervisorMachine()));
}
