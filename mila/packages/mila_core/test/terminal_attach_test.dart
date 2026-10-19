import 'package:hegel/hegel.dart';
import 'package:mila_core/mila_core.dart';
import 'package:test/test.dart';

const String _machine = '019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a';
const String _session = '019a0f73-3d4e-7f5a-8b6c-7d8e9f0a1b2c';

final Generator<AttachHeader?> _header = oneOf<AttachHeader?>([
  tuple3(
    integers(min: 0, max: 1 << 20),
    integers(min: 0, max: 4096),
    sampledFrom(AttachMode.values),
  ).map((v) => AttachedHeader(from: v.$1, replayBytes: v.$2, mode: v.$3)),
  sampledFrom(AttachError.values).map(RefusedHeader.new),
  just<AttachHeader?>(null),
]);

/// A model of one terminal view driven by a fake attach channel. The model
/// remembers what it sent so invariants can check the machine against it.
final class AttachMachine extends StateMachine {
  TerminalAttach state = const TerminalAttach.initial();
  int previousCursor = 0;
  int previousJumps = 0;
  int previousGeneration = 0;

  /// Input the view let through while it was read-only; must stay empty.
  final List<int> leakedInput = [];

  void _apply(AttachEvent event) {
    previousCursor = state.cursor;
    previousJumps = state.jumps;
    previousGeneration = state.generation;
    state = state.apply(event);
  }

  int _generation(TestCase tc) => tc.draw(
    oneOf([just(state.generation), integers(min: 0, max: state.generation + 1)]),
    name: 'generation',
  );

  @override
  List<Rule> get rules => [
    Rule('attach', (tc) => _apply(const AttachRequested())),
    Rule('header', (tc) => _apply(HeaderReceived(_generation(tc), tc.draw(_header, name: 'h')))),
    Rule('output', (tc) {
      // The bytes themselves never reach the state machine, only a length.
      final chunk = tc.draw(bytes(maxLength: 64), name: 'chunk');
      _apply(OutputReceived(_generation(tc), chunk.length));
    }),
    Rule('end', (tc) {
      final outcome = tc.draw(sampledFrom(AttachOutcome.values), name: 'outcome');
      _apply(ChannelEnded(_generation(tc), outcome));
    }),
    Rule('reset drawn', (tc) => _apply(const ScreenReset())),
    Rule('toggle read-only', (tc) {
      _apply(ReadOnlyChanged(tc.draw(booleans(), name: 'ro')));
    }),
    Rule('user types', (tc) {
      final typed = tc.draw(bytes(minLength: 1, maxLength: 8), name: 'typed');
      if (state.canSendInput && state.readOnly) leakedInput.addAll(typed);
    }),
    Rule('detach', (tc) => _apply(const Detached())),
  ];

  @override
  List<Invariant> get invariants => [
    Invariant('the cursor only moves back at a counted jump', (tc) {
      if (state.cursor < previousCursor) expect(state.jumps, previousJumps + 1);
    }),
    Invariant('a jump always asks for a screen reset', (tc) {
      if (state.jumps > previousJumps) expect(state.resetPending, isTrue);
    }),
    Invariant('generations never go backwards', (tc) {
      expect(state.generation, greaterThanOrEqualTo(previousGeneration));
    }),
    Invariant('read-only never sends input or resizes', (tc) {
      if (state.readOnly) {
        expect(state.canSendInput, isFalse);
        expect(state.canResize, isFalse);
      }
      expect(leakedInput, isEmpty);
    }),
    Invariant('input flows only while attached read-write', (tc) {
      if (state.canSendInput) {
        expect(state.phase, AttachPhase.attached);
        expect(state.mode, AttachMode.readWrite);
      }
    }),
    Invariant('the state holds no byte payloads', (tc) {
      for (final value in state.describe().values) {
        expect(value is int || value is bool || value is Enum || value == null, isTrue);
      }
    }),
    Invariant('the attach command matches the state', (tc) {
      final command = state.command(_machine, _session);
      expect(validateCommand(command), isNull);
      expect(command.options.containsKey('cursor'), state.cursorKnown);
      expect(command.options['read-only'] == true, state.readOnlyRequested);
      expect(parseCommandLine(encodeCommand(command)), command);
    }),
    Invariant('retries are bounded', (tc) {
      expect(state.attempts, lessThanOrEqualTo(maximumAttachAttempts));
      if (state.phase == AttachPhase.waiting) expect(state.outcome, AttachOutcome.transport);
    }),
  ];
}

void main() {
  property('terminal attach matches its model', (tc) => runStateful(tc, AttachMachine()));

  test('a reattach resumes at the cursor without a reset when nothing was lost', () {
    var s = const TerminalAttach.initial().apply(const AttachRequested());
    expect(s.command(_machine, _session).options, isEmpty);
    s = s.apply(
      HeaderReceived(
        1,
        const AttachedHeader(from: 100, replayBytes: 20, mode: AttachMode.readWrite),
      ),
    );
    expect((s.phase, s.cursor, s.resetPending), (AttachPhase.attached, 100, false));
    s = s.apply(const OutputReceived(1, 50));
    expect(s.cursor, 150);
    s = s.apply(const ChannelEnded(1, AttachOutcome.transport));
    expect(s.phase, AttachPhase.waiting);
    expect(s.canSendInput, isFalse);
    s = s.apply(const AttachRequested());
    expect(
      encodeCommand(s.command(_machine, _session)),
      'terminal attach --cursor=150 $_machine $_session',
    );
    // Output from the dead channel is ignored.
    expect(identical(s.apply(const OutputReceived(1, 10)), s), isTrue);
    s = s.apply(
      HeaderReceived(
        2,
        const AttachedHeader(from: 150, replayBytes: 0, mode: AttachMode.readWrite),
      ),
    );
    expect((s.cursor, s.jumps, s.resetPending, s.attempts), (150, 0, false, 0));
  });

  test('a replay gap or a restarted session is a documented jump', () {
    var s = const TerminalAttach.initial()
        .apply(const AttachRequested())
        .apply(
          const HeaderReceived(
            1,
            AttachedHeader(from: 0, replayBytes: 0, mode: AttachMode.readWrite),
          ),
        )
        .apply(const OutputReceived(1, 500))
        .apply(const ChannelEnded(1, AttachOutcome.transport))
        .apply(const AttachRequested())
        .apply(
          const HeaderReceived(
            2,
            AttachedHeader(from: 10, replayBytes: 10, mode: AttachMode.readWrite),
          ),
        );
    expect((s.cursor, s.jumps, s.resetPending), (10, 1, true));
    s = s.apply(const ScreenReset());
    expect(s.resetPending, isFalse);
  });

  test('read-only by choice or by grant never sends', () {
    final ro = const TerminalAttach.initial(readOnly: true).apply(const AttachRequested());
    expect(ro.command(_machine, _session).options['read-only'], true);
    final granted = const TerminalAttach.initial()
        .apply(const AttachRequested())
        .apply(
          const HeaderReceived(
            1,
            AttachedHeader(from: 0, replayBytes: 0, mode: AttachMode.readOnly),
          ),
        );
    expect(granted.canSendInput, isFalse);
    expect(granted.readOnly, isTrue);
    final rw = const TerminalAttach.initial()
        .apply(const AttachRequested())
        .apply(
          const HeaderReceived(
            1,
            AttachedHeader(from: 0, replayBytes: 0, mode: AttachMode.readWrite),
          ),
        );
    expect(rw.canSendInput, isTrue);
    expect(rw.apply(const ReadOnlyChanged(true)).canSendInput, isFalse);
  });

  test('refusals and authority failures end the view; transport retries are bounded', () {
    final refused = const TerminalAttach.initial()
        .apply(const AttachRequested())
        .apply(const HeaderReceived(1, RefusedHeader(AttachError.forbidden)));
    expect((refused.phase, refused.outcome), (AttachPhase.ended, AttachOutcome.refused));
    final revoked = const TerminalAttach.initial()
        .apply(const AttachRequested())
        .apply(const ChannelEnded(1, AttachOutcome.authority));
    expect(revoked.phase, AttachPhase.ended);
    var s = const TerminalAttach.initial();
    for (var i = 1; i <= maximumAttachAttempts; i++) {
      s = s.apply(const AttachRequested()).apply(ChannelEnded(i, AttachOutcome.transport));
    }
    expect(s.phase, AttachPhase.ended);
    expect(s.outcome, AttachOutcome.transport);
    // A user retry starts a fresh budget.
    s = s.apply(const AttachRequested());
    expect((s.phase, s.attempts), (AttachPhase.attaching, 0));
  });

  test('output before the header has no position and is not shown', () {
    final s = const TerminalAttach.initial().apply(const AttachRequested());
    expect(s.acceptsOutput(1), isFalse);
    expect(identical(s.apply(const OutputReceived(1, 10)), s), isTrue);
  });
}
