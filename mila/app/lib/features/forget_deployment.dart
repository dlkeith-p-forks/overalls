import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import 'machines/machines_controller.dart';
import 'notifications/push_controller.dart';
import 'preferences.dart';
import 'session.dart';

/// How long removal waits for the deployment to drop this device's
/// notification registration before forgetting it locally anyway.
const Duration forgetPushTimeout = Duration(seconds: 10);

/// Removes [deployment] from Mila on this device.
///
/// Notifications are turned off first, while a session may still be open, so
/// the deployment removes this device and the poke key is deleted. Then the
/// session ends and the saved machine list and notification record go. The
/// account, its machines and the device key's approval on the deployment are
/// not changed; adding the deployment again signs in with the same key.
Future<void> forgetDeployment(WidgetRef ref, Deployment deployment) async {
  final push = ref.read(pushProvider(deployment));
  final phase = push.registration.phase;
  if (phase != PushPhase.unsupported && phase != PushPhase.disabled) {
    final done = Completer<void>();
    final sub = ref.listenManual(pushProvider(deployment), (_, next) {
      final p = next.registration.phase;
      if ((p == PushPhase.disabled || p == PushPhase.unsupported) && !done.isCompleted) {
        done.complete();
      }
    });
    await ref.read(pushProvider(deployment).notifier).disable();
    await done.future.timeout(forgetPushTimeout, onTimeout: () {});
    sub.close();
  }
  await ref.read(pokeKeyStoreProvider)?.delete(deployment.host);
  await ref.read(preferencesProvider.notifier).put(pushRecordKey(deployment), null);
  await ref.read(snapshotStoreProvider)?.delete(deployment);
  await ref.read(signInProvider(deployment).notifier).signOut();
  ref.read(deploymentsProvider.notifier).remove(deployment);
  ref
    ..invalidate(pushProvider(deployment))
    ..invalidate(signInProvider(deployment))
    ..invalidate(savedSnapshotProvider(deployment));
}
