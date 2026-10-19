import 'package:hegel/hegel.dart';
import 'package:mila_core/src/push_registration.dart';
import 'package:test/test.dart';

/// One outcome the driver has produced but not yet delivered to the machine,
/// so user actions and token changes can interleave with steps in flight.
final class PendingOutcome {
  PendingOutcome(this.event, this.kind);
  final PushEvent event;
  final String kind;
}

/// A model of the deployment, the relay and the platform around the machine.
/// Server effects happen when a step is performed, before its outcome is
/// delivered, exactly as a reply lost in transit would leave them.
final class PushMachine extends StateMachine {
  // Starts switched on: the interesting histories begin there.
  PushRegistration state = const PushRegistration.initial().apply(const PushEnable());
  DateTime now = DateTime.utc(2026, 10, 18);
  int tokens = 0;
  int keys = 0;
  int devices = 0;

  /// The server's registered device for this SSH key and its push key id.
  String? serverDevice;
  String? serverKey;
  final List<PendingOutcome> pending = [];
  final List<PushEvent> delivered = [];
  int lastOperation = 0;
  void _apply(PushEvent event) {
    state = state.apply(event);
    expect(state.operation, greaterThanOrEqualTo(lastOperation));
    lastOperation = state.operation;
  }

  static final Generator<PushStepFailure> _failure = sampledFrom(PushStepFailure.values);

  /// Performs the step the machine asks for, applying its server effect,
  /// and returns its outcome undelivered.
  PendingOutcome? _perform(TestCase tc) {
    final action = state.next;
    state = state.took(action);
    switch (action) {
      case PushWait() || PushRequestToken():
        return null;
      case PushIssueKey(:final operation):
        if (tc.draw(booleans(probability: 0.8), name: 'issued')) {
          keys++;
          return PendingOutcome(
            PushKeyIssued(
              operation,
              keyId: 'key-$keys',
              expiresAt: now.add(const Duration(days: 90)),
            ),
            'issue',
          );
        }
        return PendingOutcome(
          PushKeyFailed(operation, tc.draw(_failure, name: 'failure')),
          'issue',
        );
      case PushRegisterDevice(:final operation):
        expect(state.keyId, isNotNull, reason: 'registration always carries a push key');
        if (tc.draw(booleans(probability: 0.8), name: 'registered')) {
          serverDevice ??= 'device-${++devices}';
          serverKey = state.keyId;
          return PendingOutcome(PushRegistered(operation, serverDevice!), 'register');
        }
        // A transient failure is a request Porsche never admitted.
        final failure = tc.draw(_failure, name: 'failure');
        if (failure == PushStepFailure.revoked) {
          serverDevice = null;
          serverKey = null;
        }
        return PendingOutcome(PushRegisterFailed(operation, failure), 'register');
      case PushRemoveDevice(:final operation, :final deviceId):
        final ok = tc.draw(booleans(probability: 0.8), name: 'removed');
        if (ok && serverDevice == deviceId) {
          serverDevice = null;
          serverKey = null;
        }
        // Removing a device the server no longer has is a success too.
        return PendingOutcome(PushRemoveFinished(operation, removed: ok), 'remove');
    }
  }

  void _deliver(PendingOutcome outcome) {
    delivered.add(outcome.event);
    _apply(outcome.event);
  }

  @override
  List<Rule> get rules => [
    Rule('user toggles notifications', (tc) {
      _apply(tc.draw(booleans(), name: 'on') ? const PushEnable() : const PushDisable());
    }),
    Rule('platform answers', (tc) {
      if (tc.draw(booleans(probability: 0.1), name: 'denied')) {
        _apply(const PushPermissionDenied());
        return;
      }
      if (tc.draw(booleans(probability: 0.3), name: 'fresh') || tokens == 0) tokens++;
      _apply(PushTokenReceived('token-$tokens'));
    }),
    Rule('server revokes the device', (tc) {
      serverDevice = null;
      serverKey = null;
      _apply(const PushRevoked());
    }),
    Rule('time passes', (tc) {
      // Mostly short gaps, so steps in flight usually answer before the key
      // is due; sometimes a jump past the rotation window.
      final hours = tc.draw(oneOf([integers(min: 0, max: 48), just(77 * 24)]), name: 'hours');
      now = now.add(Duration(hours: hours));
      _apply(PushTick(now));
    }),
    Rule('step and answer', (tc) {
      final outcome = _perform(tc);
      if (outcome != null) _deliver(outcome);
    }),
    Rule('step, answer later', (tc) {
      final outcome = _perform(tc);
      if (outcome != null) pending.add(outcome);
    }),
    Rule('deliver a late outcome', (tc) {
      if (pending.isEmpty) return;
      _deliver(pending.removeAt(tc.draw(integers(min: 0, max: pending.length - 1), name: 'which')));
    }),
    Rule('replay a stale outcome', (tc) {
      if (delivered.isEmpty) return;
      // Usually the latest answer: a duplicate of a failed attempt arriving
      // while its retry is in flight is the case that matters most.
      final latest = tc.draw(booleans(probability: 0.7), name: 'latest');
      final index = latest
          ? delivered.length - 1
          : tc.draw(integers(min: 0, max: delivered.length - 1), name: 'which');
      final before = state;
      _apply(delivered[index]);
      expect(identical(state, before), isTrue, reason: 'a delivered outcome never applies twice');
    }),
  ];

  @override
  List<Invariant> get invariants => [
    Invariant('in flight exactly while an outcome for this step is pending', (tc) {
      final current = pending.where((p) => _operation(p.event) == state.operation);
      expect(current.length, lessThanOrEqualTo(1));
      expect(state.inFlight, current.isNotEmpty);
    }),
    Invariant('active means a key, an expiry, a token and a device', (tc) {
      if (state.phase == PushPhase.active) {
        expect(state.keyId, isNotNull);
        expect(state.expiresAt, isNotNull);
        expect(state.tokenDigest, isNotNull);
        expect(state.deviceId, isNotNull);
      }
    }),
    Invariant('an active device is the one the server holds, with the current key', (tc) {
      if (state.phase == PushPhase.active) {
        expect(state.deviceId, serverDevice);
        expect(state.keyId, serverKey);
      }
    }),
    Invariant('off and settled means nothing stays registered', (tc) {
      final settled = pending.isEmpty;
      if (settled && (state.phase == PushPhase.disabled || state.phase == PushPhase.revoked)) {
        expect(state.deviceId, isNull);
        expect(state.keyId, isNull);
        expect(serverDevice, isNull);
      }
    }),
    Invariant('a removal always names the device it removes', (tc) {
      final action = state.next;
      if (action is PushRemoveDevice) expect(action.deviceId, state.deviceId);
      if (state.phase == PushPhase.removing && !state.inFlight && pending.isEmpty) {
        expect(state.deviceId, isNotNull);
      }
    }),
    Invariant('failures name a reason and nothing else does', (tc) {
      expect(state.phase == PushPhase.failed, state.failure != null);
    }),
    Invariant('a key due for rotation is never left active', (tc) {
      if (state.phase == PushPhase.active && state.now != null) {
        expect(state.now!.isBefore(state.expiresAt!.subtract(pushKeyRotationWindow)), isTrue);
      }
    }),
  ];

  static int? _operation(PushEvent event) => switch (event) {
    PushKeyIssued(:final operation) ||
    PushKeyFailed(:final operation) ||
    PushRegistered(:final operation) ||
    PushRegisterFailed(:final operation) ||
    PushRemoveFinished(:final operation) => operation,
    _ => null,
  };
}

PushRegistration _drive(PushRegistration state, List<PushEvent Function(int)> steps) {
  var s = state;
  for (final step in steps) {
    s = s.took(s.next).apply(step(s.operation));
  }
  return s;
}

void main() {
  final now = DateTime.utc(2026, 10, 18);

  test('a token, a push key and a registration make the device active', () {
    var s = const PushRegistration.initial().apply(PushTick(now)).apply(const PushEnable());
    expect(s.next, isA<PushRequestToken>());
    s = s.apply(const PushTokenReceived('t1'));
    expect(s.next, isA<PushIssueKey>());
    s = _drive(s, [
      (op) => PushKeyIssued(op, keyId: 'k1', expiresAt: now.add(const Duration(days: 90))),
      (op) => PushRegistered(op, 'd1'),
    ]);
    expect(s.phase, PushPhase.active);
    expect(s.deviceId, 'd1');
    expect(s.next, isA<PushWait>());
  });

  test('the key rotates before expiry and keeps the device id', () {
    var s = _drive(
      const PushRegistration.initial()
          .apply(PushTick(now))
          .apply(const PushEnable())
          .apply(const PushTokenReceived('t1')),
      [
        (op) => PushKeyIssued(op, keyId: 'k1', expiresAt: now.add(const Duration(days: 90))),
        (op) => PushRegistered(op, 'd1'),
      ],
    );
    s = s.apply(PushTick(now.add(const Duration(days: 75))));
    expect(s.phase, PushPhase.active);
    s = s.apply(PushTick(now.add(const Duration(days: 76))));
    expect(s.phase, PushPhase.issuing);
    expect(s.deviceId, 'd1');
  });

  test('turning off removes the device; the operator switch fails closed', () {
    var s = _drive(
      const PushRegistration.initial()
          .apply(PushTick(now))
          .apply(const PushEnable())
          .apply(const PushTokenReceived('t1')),
      [
        (op) => PushKeyIssued(op, keyId: 'k1', expiresAt: now.add(const Duration(days: 90))),
        (op) => PushRegisterFailed(op, PushStepFailure.pushDisabled),
      ],
    );
    expect(s.phase, PushPhase.failed);
    expect(s.failure, PushFailure.pushDisabled);
    expect(s.next, isA<PushWait>());
    s = s.apply(const PushDisable());
    expect(s.phase, PushPhase.disabled);
  });

  test('a transient failure waits for its backoff before retrying', () {
    var s = const PushRegistration.initial()
        .apply(PushTick(now))
        .apply(const PushEnable())
        .apply(const PushTokenReceived('t1'));
    s = _drive(s, [(op) => PushKeyFailed(op, PushStepFailure.transient)]);
    expect(s.next, isA<PushWait>());
    expect(s.retryAt, isNotNull);
    s = s.apply(PushTick(s.retryAt!));
    expect(s.next, isA<PushIssueKey>());
  });

  test('a saved record restores without the token or push key', () {
    final active = _drive(
      const PushRegistration.initial()
          .apply(PushTick(now))
          .apply(const PushEnable())
          .apply(const PushTokenReceived('t1')),
      [
        (op) => PushKeyIssued(op, keyId: 'k1', expiresAt: now.add(const Duration(days: 90))),
        (op) => PushRegistered(op, 'd1'),
      ],
    );
    final restored = PushRegistration.restore(active.record);
    expect(restored.phase, PushPhase.active);
    expect(restored.deviceId, 'd1');
    expect(restored.keyId, 'k1');
    expect(restored.expiresAt, active.expiresAt);
    expect(
      active.record.keys,
      unorderedEquals(['version', 'wanted', 'device_id', 'key_id', 'expires_at', 'token_digest']),
    );
    final removing = PushRegistration.restore(active.apply(const PushDisable()).record);
    expect(removing.phase, PushPhase.removing);
    expect(removing.next, isA<PushRemoveDevice>());
    expect(PushRegistration.restore({'version': 1, 'wanted': true}).next, isA<PushRequestToken>());
    for (final bad in [
      <String, Object?>{},
      {'version': 2, 'wanted': true},
      {'version': 1, 'wanted': true, 'push_key': 'secret'},
    ]) {
      expect(PushRegistration.restore(bad).phase, PushPhase.disabled);
    }
  });

  test('Linux has no push and ignores every request', () {
    var s = const PushRegistration.unsupported();
    for (final e in [const PushEnable(), const PushTokenReceived('t'), const PushRevoked()]) {
      s = s.apply(e);
      expect(s.phase, PushPhase.unsupported);
      expect(s.next, isA<PushWait>());
    }
  });

  property(
    'push registration matches its model',
    (tc) => runStateful(tc, PushMachine()),
    // Disabling mid-registration needs a dozen specific steps to reach.
    settings: const Settings(testCases: 1500, statefulStepCount: 80),
  );
}
