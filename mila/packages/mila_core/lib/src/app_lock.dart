/// The biometric app lock policy, as a pure state machine. The app feeds it
/// lifecycle changes and the platform's authentication results; it decides
/// whether Mila's content may be shown.
///
/// The lock is a guard against casual access to an unlocked phone, not an
/// authority boundary: deployments authorize every command themselves.
library;

/// Whether this device can authenticate the user for the lock.
enum LockAvailability {
  /// Not probed yet. An enabled lock stays closed until it is known.
  unknown,

  /// Biometrics or a device passcode are available.
  available,

  /// Nothing to authenticate with (no passcode, or Linux). The lock cannot
  /// work, so it is off and the setting says so.
  unavailable,
}

/// How long Mila may stay in the background before it locks.
enum LockDelay {
  immediately(Duration.zero),
  oneMinute(Duration(minutes: 1)),
  fiveMinutes(Duration(minutes: 5));

  const LockDelay(this.duration);

  final Duration duration;

  static LockDelay? fromName(String name) {
    for (final delay in values) {
      if (delay.name == name) return delay;
    }
    return null;
  }
}

/// Whether content is shown.
enum LockPhase {
  unlocked,
  locked,

  /// The platform prompt is up; content stays hidden.
  authenticating,
}

sealed class LockEvent {
  const LockEvent();
}

final class LockAvailabilityKnown extends LockEvent {
  const LockAvailabilityKnown(this.availability);
  final LockAvailability availability;
}

/// The user turned the lock on, after proving they can unlock.
final class LockEnabled extends LockEvent {
  const LockEnabled();
}

/// The user turned the lock off from an unlocked app.
final class LockDisabled extends LockEvent {
  const LockDisabled();
}

final class LockDelayChosen extends LockEvent {
  const LockDelayChosen(this.delay);
  final LockDelay delay;
}

/// Mila left the foreground at [at].
final class AppBackgrounded extends LockEvent {
  const AppBackgrounded(this.at);
  final DateTime at;
}

/// Mila returned to the foreground at [at].
final class AppForegrounded extends LockEvent {
  const AppForegrounded(this.at);
  final DateTime at;
}

/// The user asked to unlock; the platform prompt opens.
final class UnlockRequested extends LockEvent {
  const UnlockRequested();
}

/// The prompt for [attempt] finished.
final class UnlockFinished extends LockEvent {
  const UnlockFinished(this.attempt, {required this.success});
  final int attempt;
  final bool success;
}

/// An immutable lock snapshot.
final class AppLock {
  const AppLock._({
    required this.enabled,
    required this.delay,
    required this.availability,
    required this.phase,
    required this.attempt,
    this.backgroundedAt,
    this.lastFailed = false,
  });

  /// The lock as Mila starts: closed when it was enabled, whatever the
  /// availability turns out to be, until availability is known.
  factory AppLock.start({required bool enabled, LockDelay delay = LockDelay.immediately}) =>
      AppLock._(
        enabled: enabled,
        delay: delay,
        availability: LockAvailability.unknown,
        phase: enabled ? LockPhase.locked : LockPhase.unlocked,
        attempt: 0,
      );

  /// The user's setting, kept even while the lock cannot work.
  final bool enabled;
  final LockDelay delay;
  final LockAvailability availability;
  final LockPhase phase;

  /// The current prompt's number; stale results are ignored.
  final int attempt;
  final DateTime? backgroundedAt;

  /// The last prompt failed or was cancelled.
  final bool lastFailed;

  /// Whether the lock is in force.
  bool get effective => enabled && availability != LockAvailability.unavailable;

  /// Whether content must be hidden.
  bool get obscured => phase != LockPhase.unlocked;

  AppLock _copy({
    bool? enabled,
    LockDelay? delay,
    LockAvailability? availability,
    LockPhase? phase,
    int? attempt,
    DateTime? backgroundedAt,
    bool clearBackground = false,
    bool? lastFailed,
  }) => AppLock._(
    enabled: enabled ?? this.enabled,
    delay: delay ?? this.delay,
    availability: availability ?? this.availability,
    phase: phase ?? this.phase,
    attempt: attempt ?? this.attempt,
    backgroundedAt: clearBackground ? null : backgroundedAt ?? this.backgroundedAt,
    lastFailed: lastFailed ?? this.lastFailed,
  );

  // @cc [owner:ghuntley,label:security] mila-lock-fails-closed
  // While the lock is in force, content MUST stay hidden from start and after
  // a background stay of at least the chosen delay until the platform prompt
  // for the current attempt succeeds. Stale or failed results MUST NOT
  // unlock. Only a device that cannot authenticate at all turns it off.
  /// Applies one event.
  AppLock apply(LockEvent event) => switch (event) {
    LockAvailabilityKnown(:final availability) =>
      availability == LockAvailability.unavailable
          ? _copy(availability: availability, phase: LockPhase.unlocked, lastFailed: false)
          : _copy(availability: availability),
    LockEnabled() when phase == LockPhase.unlocked && availability == LockAvailability.available =>
      _copy(enabled: true),
    LockEnabled() => this,
    LockDisabled() when phase == LockPhase.unlocked => _copy(enabled: false),
    LockDisabled() => this,
    LockDelayChosen(:final delay) when phase == LockPhase.unlocked => _copy(delay: delay),
    LockDelayChosen() => this,
    // The platform prompt itself can background the app; it never relocks.
    AppBackgrounded() when phase == LockPhase.authenticating => this,
    AppBackgrounded(:final at) =>
      effective && delay == LockDelay.immediately
          ? _copy(phase: LockPhase.locked, backgroundedAt: at)
          : _copy(backgroundedAt: at),
    AppForegrounded() when phase == LockPhase.authenticating => this,
    AppForegrounded(:final at) => _foreground(at),
    UnlockRequested()
        when phase == LockPhase.locked && availability == LockAvailability.available =>
      _copy(phase: LockPhase.authenticating, attempt: attempt + 1),
    UnlockRequested() => this,
    UnlockFinished(:final attempt, :final success)
        when attempt == this.attempt && phase == LockPhase.authenticating =>
      success
          ? _copy(phase: LockPhase.unlocked, lastFailed: false, clearBackground: true)
          : _copy(phase: LockPhase.locked, lastFailed: true),
    UnlockFinished() => this,
  };

  AppLock _foreground(DateTime at) {
    final left = backgroundedAt;
    if (!effective || left == null) return _copy(clearBackground: true);
    // A clock that went backwards counts as a long absence.
    final away = at.difference(left);
    final lock = away.isNegative || away >= delay.duration;
    return _copy(phase: lock ? LockPhase.locked : phase, clearBackground: true);
  }
}
