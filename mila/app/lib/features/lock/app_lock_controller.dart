// Drives the pure `AppLock` policy from the app lifecycle and the platform
// prompt, and persists the user's lock settings.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mila_core/mila_core.dart';

import '../preferences.dart';
import '../session.dart';

/// Authenticates the user for the app lock.
abstract interface class LockAuthenticator {
  Future<LockAvailability> availability();

  /// Shows the platform prompt with [reason]; true only on success.
  Future<bool> authenticate(String reason);
}

/// No way to authenticate: Linux, tests and the demo flavour.
final class UnavailableLockAuthenticator implements LockAuthenticator {
  const UnavailableLockAuthenticator();
  @override
  Future<LockAvailability> availability() async => LockAvailability.unavailable;
  @override
  Future<bool> authenticate(String reason) async => false;
}

final lockAuthenticatorProvider = Provider<LockAuthenticator>(
  (ref) => const UnavailableLockAuthenticator(),
);

const String _enabledKey = 'lock.enabled';
const String _delayKey = 'lock.delay';

final appLockProvider = NotifierProvider<AppLockController, AppLock>(AppLockController.new);

final class AppLockController extends Notifier<AppLock> {
  @override
  AppLock build() {
    // Closed until the saved setting and availability are known: a saved
    // lock is in force from the first frame.
    unawaited(_start());
    return AppLock.start(enabled: true);
  }

  Future<void> _start() async {
    final preferences = ref.read(preferencesProvider.notifier);
    await preferences.loaded;
    final saved = ref.read(preferencesProvider) ?? const {};
    final delayName = saved[_delayKey];
    state = AppLock.start(
      enabled: saved[_enabledKey] == true,
      delay: (delayName is String ? LockDelay.fromName(delayName) : null) ?? LockDelay.immediately,
    );
    final availability = await ref.read(lockAuthenticatorProvider).availability();
    state = state.apply(LockAvailabilityKnown(availability));
  }

  DateTime _now() => ref.read(clockProvider)();

  void backgrounded() => state = state.apply(AppBackgrounded(_now()));
  void foregrounded() => state = state.apply(AppForegrounded(_now()));

  /// Shows the platform prompt and applies its result.
  Future<void> unlock(String reason) async {
    state = state.apply(const UnlockRequested());
    if (state.phase != LockPhase.authenticating) return;
    final attempt = state.attempt;
    final success = await ref.read(lockAuthenticatorProvider).authenticate(reason);
    state = state.apply(UnlockFinished(attempt, success: success));
  }

  /// Turns the lock on once the user proves they can unlock.
  Future<bool> enable(String reason) async {
    if (state.availability != LockAvailability.available || state.obscured) return false;
    if (!await ref.read(lockAuthenticatorProvider).authenticate(reason)) return false;
    state = state.apply(const LockEnabled());
    await ref.read(preferencesProvider.notifier).put(_enabledKey, state.enabled);
    return state.enabled;
  }

  Future<void> disable() async {
    state = state.apply(const LockDisabled());
    await ref.read(preferencesProvider.notifier).put(_enabledKey, state.enabled);
  }

  Future<void> chooseDelay(LockDelay delay) async {
    state = state.apply(LockDelayChosen(delay));
    await ref.read(preferencesProvider.notifier).put(_delayKey, state.delay.name);
  }
}
