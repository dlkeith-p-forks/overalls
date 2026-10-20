import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../routes.dart';
import '../session.dart';
import '../sign_in_screen.dart';
import 'push_controller.dart';

/// The deployment's notifications documentation, on its own web origin.
Uri notificationsDocs(Deployment deployment) =>
    Uri(scheme: 'https', host: deployment.host, path: '/docs/notifications');

/// The bracketed status for this device's registration.
String pushStateText(MilaLocalizations l, PushRegistration registration) =>
    switch (registration.phase) {
      PushPhase.active => l.pushStateOn,
      PushPhase.awaitingToken ||
      PushPhase.issuing ||
      PushPhase.registering => l.pushStateRegistering,
      PushPhase.removing => l.pushStateRemoving,
      PushPhase.revoked => l.pushStateRevoked,
      PushPhase.failed => l.pushStateFailed,
      PushPhase.disabled || PushPhase.denied || PushPhase.unsupported => l.pushStateOff,
    };

StateTone? _tone(PushPhase phase) => switch (phase) {
  PushPhase.active => StateTone.success,
  PushPhase.awaitingToken ||
  PushPhase.issuing ||
  PushPhase.registering ||
  PushPhase.removing => StateTone.pending,
  PushPhase.failed || PushPhase.revoked => StateTone.danger,
  _ => null,
};

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key, required this.deployment});

  final Deployment deployment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = MilaLocalizations.of(context);
    final session = ref.watch(sessionProvider(deployment));
    final view = ref.watch(pushProvider(deployment));
    final registration = view.registration;
    final controller = ref.read(pushProvider(deployment).notifier);
    final tokens = MonoTheme.of(context);
    final unsupported = registration.phase == PushPhase.unsupported;
    final explanation = switch (registration.phase) {
      PushPhase.unsupported => l.pushUnsupported,
      PushPhase.denied => l.pushDenied,
      PushPhase.revoked => l.pushRevokedExplain,
      PushPhase.failed => switch (registration.failure) {
        PushFailure.pushDisabled => l.pushFailedDisabled,
        PushFailure.refused => l.pushFailedRefused,
        PushFailure.protocol || null => l.pushFailedProtocol,
      },
      _ => null,
    };
    final changing = switch (registration.phase) {
      PushPhase.removing => true,
      PushPhase.registering => registration.inFlight,
      _ => false,
    };
    return Scaffold(
      appBar: AppBar(
        leading: TextButton(
          onPressed: () => context.go(machinesPath(deployment)),
          child: BackGlyph(label: l.back),
        ),
        title: Text(l.notificationsTitle),
        actions: [
          if (session != null && !unsupported)
            TextButton(
              key: const Key('notifications-refresh'),
              onPressed: view.busy ? null : controller.refreshDevices,
              child: Text(l.refresh.toUpperCase()),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(MonoScale.fontSize),
        children: [
          Text(deployment.toString(), textDirection: TextDirection.ltr),
          const SizedBox(height: MonoScale.line),
          Text(l.notificationsExplain),
          const SizedBox(height: MonoScale.line / 2),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const Key('notifications-docs'),
              onPressed: () => ref.read(openExternalProvider)(notificationsDocs(deployment)),
              child: Text('${Glyph.arrowUpRight.char} ${l.notificationsPrivacyLink}'),
            ),
          ),
          const SizedBox(height: MonoScale.line),
          if (session == null && !unsupported)
            Text(l.notificationsSignInFirst, key: const Key('notifications-sign-in'))
          else ...[
            Panel(
              title: l.notificationsThisDevice,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StatusLabel(
                    pushStateText(l, registration),
                    key: const Key('push-state'),
                    tone: _tone(registration.phase),
                  ),
                  if (explanation != null) ...[
                    const SizedBox(height: MonoScale.line / 2),
                    Text(explanation, key: const Key('push-explanation')),
                  ],
                  if (!unsupported) ...[
                    const SizedBox(height: MonoScale.line / 2),
                    if (registration.wanted)
                      ConsoleButton(
                        key: const Key('push-off'),
                        label: l.notificationsTurnOff,
                        onPressed: changing ? null : controller.disable,
                      )
                    else
                      ConsoleButton(
                        key: const Key('push-on'),
                        label: l.notificationsTurnOn,
                        onPressed: changing ? null : controller.enable,
                      ),
                  ],
                ],
              ),
            ),
            if (!unsupported) ...[
              const SizedBox(height: MonoScale.line),
              Panel(
                title: l.notificationsDevices,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (view.devices?.isEmpty ?? false) Text(l.notificationsDevicesEmpty),
                    for (final device in view.devices ?? const <RegisteredDevice>[])
                      _DeviceRow(
                        device: device,
                        current: device.id == registration.deviceId,
                        busy: view.busy,
                        deployment: deployment,
                        tokens: tokens,
                      ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _DeviceRow extends ConsumerWidget {
  const _DeviceRow({
    required this.device,
    required this.current,
    required this.busy,
    required this.deployment,
    required this.tokens,
  });

  final RegisteredDevice device;
  final bool current;
  final bool busy;
  final Deployment deployment;
  final MonoTokens tokens;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = MilaLocalizations.of(context);
    final controller = ref.read(pushProvider(deployment).notifier);
    return Padding(
      key: Key('device-${device.id}'),
      padding: const EdgeInsets.only(bottom: MonoScale.line / 2),
      child: Wrap(
        spacing: MonoScale.fontSize,
        runSpacing: MonoScale.line / 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (device.label case final label?) ...[
            Text(
              label,
              key: Key('device-label-${device.id}'),
              style: const TextStyle(fontWeight: MonoScale.bold),
            ),
            Text(
              device.platform,
              textDirection: TextDirection.ltr,
              style: TextStyle(color: tokens.textAlt),
            ),
          ] else
            Text(device.platform, textDirection: TextDirection.ltr),
          StatusLabel(device.enabled ? l.pushStateOn : l.pushStateOff),
          if (current)
            Text(
              '${Glyph.bullet.char} ${l.notificationsCurrentDevice}',
              style: TextStyle(color: tokens.textAlt),
            ),
          ConsoleButton(
            key: Key('device-toggle-${device.id}'),
            label: device.enabled ? l.notificationsTurnOff : l.notificationsTurnOn,
            onPressed: busy
                ? null
                : () => controller.setDeviceEnabled(device.id, enabled: !device.enabled),
          ),
          ConsoleButton(
            key: Key('device-remove-${device.id}'),
            label: l.notificationsRemoveDevice,
            onPressed: busy ? null : () => controller.removeDevice(device.id),
          ),
        ],
      ),
    );
  }
}
