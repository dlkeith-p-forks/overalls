// Push registration per deployment: drives the pure `PushRegistration`
// state machine with a `PushRegistrar`, persists its record, and lists the
// account's registered devices.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../preferences.dart';
import '../session.dart';

/// The platform push service; null where there is none (Linux, tests).
final pushPlatformProvider = Provider<PushPlatform?>((ref) => null);

/// Where poke keys live; null where there is no push service.
final pokeKeyStoreProvider = Provider<PokeKeyStore?>((ref) => null);

/// The name this device registers with, shown in the device list; null
/// registers without one.
final deviceLabelProvider = Provider<String?>((ref) => null);

/// The relay client at its fixed origin.
final susanClientProvider = Provider<SusanClient>((ref) => SusanClient());

/// How often registration re-checks retries and key rotation.
const Duration pushTickInterval = Duration(minutes: 1);

/// Everything the notifications screen shows for one deployment.
final class PushView {
  const PushView(this.registration, {this.devices, this.busy = false});

  final PushRegistration registration;

  /// The account's registered devices, once listed.
  final List<RegisteredDevice>? devices;
  final bool busy;

  PushView copyWith({
    PushRegistration? registration,
    List<RegisteredDevice>? devices,
    bool? busy,
  }) => PushView(
    registration ?? this.registration,
    devices: devices ?? this.devices,
    busy: busy ?? this.busy,
  );
}

/// The preferences key holding [deployment]'s registration record.
String pushRecordKey(Deployment deployment) => 'push.$deployment';

final pushProvider = NotifierProvider.family<PushController, PushView, Deployment>(
  PushController.new,
);

final class PushController extends Notifier<PushView> {
  PushController(this.deployment);

  final Deployment deployment;
  PushRegistrar? _registrar;
  Timer? _tick;
  StreamSubscription<String>? _tokens;
  bool _pumping = false;
  bool _again = false;

  @override
  PushView build() {
    ref.onDispose(() {
      _tick?.cancel();
      unawaited(_tokens?.cancel());
    });
    final platform = ref.watch(pushPlatformProvider);
    final keys = ref.watch(pokeKeyStoreProvider);
    if (platform == null || keys == null) return const PushView(PushRegistration.unsupported());
    _registrar = PushRegistrar(
      deployment: deployment,
      platform: platform,
      susan: ref.watch(susanClientProvider),
      pokeKeys: keys,
      label: ref.read(deviceLabelProvider),
      random: ref.read(randomProvider),
    );
    _tokens = platform.tokenChanges.listen(
      (token) => _apply(PushTokenReceived(pushTokenDigest(token))),
    );
    _tick = Timer.periodic(pushTickInterval, (_) => _apply(PushTick(ref.read(clockProvider)())));
    // Sessions come and go; steps that need Porsche wait for the next one.
    ref.listen(sessionProvider(deployment), (previous, next) {
      if (next != null) unawaited(_signedIn());
    });
    unawaited(_restore());
    return const PushView(PushRegistration.initial(), busy: true);
  }

  Future<void> _restore() async {
    await ref.read(preferencesProvider.notifier).loaded;
    final saved = ref.read(preferencesProvider)?[pushRecordKey(deployment)];
    final registration = saved is Map<String, Object?>
        ? PushRegistration.restore(saved)
        : const PushRegistration.initial();
    state = PushView(registration.apply(PushTick(ref.read(clockProvider)())));
    if (ref.read(sessionProvider(deployment)) != null) await _signedIn();
  }

  Future<void> _signedIn() async {
    await refreshDevices();
    await _pump();
  }

  void _apply(PushEvent event) {
    final before = state.registration;
    state = state.copyWith(registration: before.apply(event));
    unawaited(_save(before));
    unawaited(_pump());
  }

  Future<void> _save(PushRegistration before) async {
    final record = state.registration.record;
    if (_same(before.record, record)) return;
    await ref.read(preferencesProvider.notifier).put(pushRecordKey(deployment), record);
  }

  static bool _same(Map<String, Object?> a, Map<String, Object?> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  /// Runs steps until the machine waits. One pump at a time; a request to
  /// pump while running runs another round afterwards.
  Future<void> _pump() async {
    final registrar = _registrar;
    if (registrar == null) return;
    if (_pumping) {
      _again = true;
      return;
    }
    _pumping = true;
    try {
      do {
        _again = false;
        while (true) {
          final action = state.registration.next;
          if (action is PushWait) break;
          final session = ref.read(sessionProvider(deployment));
          final needsPorsche = action is PushRegisterDevice || action is PushRemoveDevice;
          if (needsPorsche && session == null) break;
          final before = state.registration;
          state = state.copyWith(registration: before.took(action));
          final event = await registrar.perform(action, session);
          if (registrar.unavailable) {
            state = const PushView(PushRegistration.unsupported());
            return;
          }
          if (event == null) break;
          final taken = state.registration;
          state = state.copyWith(registration: taken.apply(event));
          await _save(taken);
          if (needsPorsche && session != null) await _listDevices(session);
        }
      } while (_again);
    } finally {
      _pumping = false;
    }
  }

  /// Turns notifications on for this device.
  Future<void> enable() async => _apply(const PushEnable());

  /// Turns them off, removing this device from the deployment.
  Future<void> disable() async => _apply(const PushDisable());

  /// Lists the account's devices and notices when this one was revoked.
  Future<void> refreshDevices() async {
    final session = ref.read(sessionProvider(deployment));
    if (session == null) return;
    state = state.copyWith(busy: true);
    await _listDevices(session);
    if (!ref.mounted) return;
    if (state.busy) state = state.copyWith(busy: false);
    final mine = state.registration.deviceId;
    final devices = state.devices;
    if (devices != null &&
        state.registration.phase == PushPhase.active &&
        !devices.any((d) => d.id == mine)) {
      _apply(const PushRevoked());
    }
  }

  Future<void> _listDevices(PorscheSession session) async {
    final registrar = _registrar;
    if (registrar == null) return;
    final devices = await registrar.listDevices(session);
    if (devices == null) return;
    state = state.copyWith(devices: List.unmodifiable(devices), busy: false);
  }

  /// Turns notifications for any of the account's devices on or off.
  Future<void> setDeviceEnabled(String deviceId, {required bool enabled}) async {
    final session = ref.read(sessionProvider(deployment));
    final registrar = _registrar;
    if (session == null || registrar == null) return;
    state = state.copyWith(busy: true);
    await registrar.setEnabled(session, deviceId, enabled: enabled);
    await refreshDevices();
  }

  /// Removes another of the account's devices; this device uses [disable].
  Future<void> removeDevice(String deviceId) async {
    if (deviceId == state.registration.deviceId) return disable();
    final session = ref.read(sessionProvider(deployment));
    final registrar = _registrar;
    if (session == null || registrar == null) return;
    state = state.copyWith(busy: true);
    await registrar.remove(session, deviceId);
    await refreshDevices();
  }
}
