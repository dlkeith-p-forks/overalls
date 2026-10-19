import 'package:hegel/hegel.dart';
import 'package:mila_core/src/app_lock.dart';
import 'package:test/test.dart';

/// A model of the app around the lock: the lifecycle, the platform prompt
/// and the user's settings. It tracks when content must be hidden and checks
/// the lock never shows it early.
final class LockMachine extends StateMachine {
  LockMachine(bool enabled) : lock = AppLock.start(enabled: enabled), mustHide = enabled;

  AppLock lock;
  DateTime now = DateTime.utc(2026, 10, 18);

  /// The model's own view: content must stay hidden until a prompt for the
  /// current attempt succeeds, or the device turns out unable to lock.
  bool mustHide;
  DateTime? leftAt;
  final List<UnlockFinished> answered = [];

  void _apply(LockEvent event) {
    final before = lock;
    lock = lock.apply(event);
    if (!before.obscured && lock.obscured) mustHide = true;
    if (before.obscured && !lock.obscured) {
      // The only ways out: a current successful prompt, or no way to lock.
      final current = event is UnlockFinished && event.success && event.attempt == before.attempt;
      final unable =
          event is LockAvailabilityKnown && event.availability == LockAvailability.unavailable;
      expect(current || unable, isTrue, reason: 'unlocked by $event');
      mustHide = false;
    }
  }

  @override
  List<Rule> get rules => [
    Rule('availability probed', (tc) {
      _apply(LockAvailabilityKnown(tc.draw(sampledFrom(LockAvailability.values), name: 'a')));
    }),
    Rule('user toggles the lock', (tc) {
      _apply(tc.draw(booleans(), name: 'on') ? const LockEnabled() : const LockDisabled());
    }),
    Rule('user picks a delay', (tc) {
      _apply(LockDelayChosen(tc.draw(sampledFrom(LockDelay.values), name: 'delay')));
    }),
    Rule('app goes to the background', (tc) {
      _apply(AppBackgrounded(now));
      leftAt ??= now;
    }),
    Rule('time passes', (tc) {
      now = now.add(Duration(seconds: tc.draw(integers(min: 0, max: 400), name: 'seconds')));
    }),
    Rule('app returns', (tc) {
      final before = lock;
      _apply(AppForegrounded(now));
      final left = before.backgroundedAt;
      if (before.effective &&
          before.phase != LockPhase.authenticating &&
          left != null &&
          !now.difference(left).isNegative &&
          now.difference(left) >= before.delay.duration) {
        expect(lock.obscured, isTrue, reason: 'a long absence always relocks');
      }
      leftAt = null;
    }),
    Rule('user asks to unlock', (tc) => _apply(const UnlockRequested())),
    Rule('prompt answers', (tc) {
      final success = tc.draw(booleans(), name: 'success');
      final answer = UnlockFinished(lock.attempt, success: success);
      answered.add(answer);
      _apply(answer);
    }),
    Rule('a stale prompt answers', (tc) {
      if (lock.attempt == 0) return;
      final stale = tc.draw(integers(min: 0, max: lock.attempt - 1), name: 'attempt');
      final before = lock;
      _apply(UnlockFinished(stale, success: true));
      expect(identical(lock, before), isTrue);
    }),
  ];

  @override
  List<Invariant> get invariants => [
    Invariant('content is hidden whenever the model says it must be', (tc) {
      if (mustHide) expect(lock.obscured, isTrue);
    }),
    Invariant('a lock that cannot work is never in force', (tc) {
      if (lock.availability == LockAvailability.unavailable) {
        expect(lock.effective, isFalse);
        expect(lock.obscured, isFalse);
      }
    }),
    Invariant('a disabled lock is never closed after it opens', (tc) {
      if (!lock.enabled && lock.phase == LockPhase.unlocked) expect(lock.obscured, isFalse);
    }),
  ];
}

void main() {
  final t0 = DateTime.utc(2026, 10, 18, 12);

  test('an enabled lock starts closed and opens only on a current success', () {
    var lock = AppLock.start(enabled: true);
    expect(lock.obscured, isTrue);
    lock = lock.apply(const UnlockRequested());
    expect(lock.phase, LockPhase.locked, reason: 'no prompt before availability is known');
    lock = lock.apply(const LockAvailabilityKnown(LockAvailability.available));
    lock = lock.apply(const UnlockRequested());
    expect(lock.phase, LockPhase.authenticating);
    lock = lock.apply(UnlockFinished(lock.attempt, success: false));
    expect(lock.phase, LockPhase.locked);
    expect(lock.lastFailed, isTrue);
    lock = lock.apply(const UnlockRequested());
    lock = lock.apply(UnlockFinished(lock.attempt, success: true));
    expect(lock.obscured, isFalse);
  });

  test('the delay decides whether returning relocks', () {
    var lock = AppLock.start(
      enabled: true,
      delay: LockDelay.oneMinute,
    ).apply(const LockAvailabilityKnown(LockAvailability.available)).apply(const UnlockRequested());
    lock = lock.apply(UnlockFinished(lock.attempt, success: true));
    lock = lock
        .apply(AppBackgrounded(t0))
        .apply(AppForegrounded(t0.add(const Duration(seconds: 59))));
    expect(lock.obscured, isFalse);
    lock = lock
        .apply(AppBackgrounded(t0))
        .apply(AppForegrounded(t0.add(const Duration(minutes: 1))));
    expect(lock.obscured, isTrue);
  });

  test('Linux and passcode-less devices show the lock as unavailable', () {
    final lock = AppLock.start(
      enabled: true,
    ).apply(const LockAvailabilityKnown(LockAvailability.unavailable));
    expect(lock.effective, isFalse);
    expect(lock.obscured, isFalse);
    expect(lock.apply(const LockEnabled()).effective, isFalse);
  });

  test('the platform prompt backgrounding the app does not relock it', () {
    var lock = AppLock.start(
      enabled: true,
    ).apply(const LockAvailabilityKnown(LockAvailability.available)).apply(const UnlockRequested());
    lock = lock.apply(AppBackgrounded(t0)).apply(AppForegrounded(t0.add(const Duration(hours: 1))));
    expect(lock.phase, LockPhase.authenticating);
    lock = lock.apply(UnlockFinished(lock.attempt, success: true));
    expect(lock.obscured, isFalse);
  });

  property(
    'the lock never shows content early (enabled at start)',
    (tc) => runStateful(tc, LockMachine(true)),
  );
  property(
    'the lock never shows content early (disabled at start)',
    (tc) => runStateful(tc, LockMachine(false)),
  );
}
