import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../l10n/app_localizations.dart';
import '../ui/theme.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'forget_deployment.dart';
import 'lock/app_lock_controller.dart';
import 'routes.dart';
import 'session.dart';
import 'ssh_keys/ssh_keys_screen.dart' show sshKeysPath;

final appearanceProvider = NotifierProvider<AppearanceNotifier, Appearance>(AppearanceNotifier.new);

final class AppearanceNotifier extends Notifier<Appearance> {
  @override
  Appearance build() => Appearance.system;

  void set(Appearance value) => state = value;
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = MilaLocalizations.of(context);
    final appearance = ref.watch(appearanceProvider);
    final deployments = ref.watch(deploymentsProvider);
    String name(Appearance a) => switch (a) {
      Appearance.system => l.appearanceSystem,
      Appearance.light => l.appearanceLight,
      Appearance.dark => l.appearanceDark,
    };
    return Scaffold(
      appBar: AppBar(
        leading: TextButton(
          onPressed: () => context.go(deploymentsPath),
          child: BackGlyph(label: l.back),
        ),
        title: Text(l.settingsTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.all(MonoScale.fontSize),
        children: [
          Panel(
            title: l.appearance,
            child: Wrap(
              spacing: MonoScale.fontSize / 2,
              children: [
                for (final a in Appearance.values)
                  ConsoleButton(
                    key: Key('appearance-${a.name}'),
                    label: a == appearance ? '${Glyph.check.char} ${name(a)}' : name(a),
                    onPressed: () => ref.read(appearanceProvider.notifier).set(a),
                  ),
              ],
            ),
          ),
          const SizedBox(height: MonoScale.line),
          const _LockPanel(),
          if (deployments.isNotEmpty) ...[
            const SizedBox(height: MonoScale.line),
            Panel(
              title: l.notificationsTitle,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final d in deployments)
                    TextButton(
                      key: Key('settings-notifications-$d'),
                      onPressed: () => context.go(notificationsPath(d)),
                      child: Text(d.toString(), textDirection: TextDirection.ltr),
                    ),
                ],
              ),
            ),
            const SizedBox(height: MonoScale.line),
            Panel(
              title: l.deploymentsTitle,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final d in deployments)
                    _DeploymentRow(deployment: d, onRemove: () => _confirmRemove(context, ref, d)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref, Deployment deployment) async {
    final l = MilaLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l.deploymentRemoveConfirm(deployment.toString())),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.cancel.toUpperCase()),
          ),
          TextButton(
            key: const Key('confirm-deployment-remove'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.notificationsRemoveDevice.toUpperCase()),
          ),
        ],
      ),
    );
    if (confirmed == true) await forgetDeployment(ref, deployment);
  }
}

/// One added deployment: its account and connection, and what can be done
/// with it on this device.
class _DeploymentRow extends ConsumerWidget {
  const _DeploymentRow({required this.deployment, required this.onRemove});

  final Deployment deployment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = MilaLocalizations.of(context);
    final d = deployment;
    final flow = ref.watch(signInProvider(d)).flow;
    final controller = ref.read(signInProvider(d).notifier);
    final signedIn = flow.phase == SignInPhase.signedIn;
    final email = flow.email;
    return Padding(
      padding: const EdgeInsets.only(bottom: MonoScale.line / 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(d.toString(), textDirection: TextDirection.ltr),
          Row(
            children: [
              StatusLabel(
                signedIn ? l.settingsSignedIn : l.settingsOffline,
                key: Key('deployment-state-$d'),
                tone: signedIn ? StateTone.success : null,
              ),
              if (email != null) ...[
                const SizedBox(width: MonoScale.fontSize),
                Flexible(
                  child: Text(
                    email,
                    key: Key('deployment-account-$d'),
                    textDirection: TextDirection.ltr,
                    style: TextStyle(color: MonoTheme.of(context).textAlt),
                  ),
                ),
              ],
            ],
          ),
          Wrap(
            children: [
              if (signedIn)
                TextButton(
                  key: Key('ssh-keys-$d'),
                  onPressed: () => context.go(sshKeysPath(d)),
                  child: Text(l.sshKeysTitle.toUpperCase()),
                ),
              if (flow.phase == SignInPhase.disconnected)
                TextButton(
                  key: Key('reconnect-deployment-$d'),
                  onPressed: () {
                    unawaited(controller.start());
                    context.go(signInPath(d));
                  },
                  child: Text(l.signInReconnect.toUpperCase()),
                ),
              if (signedIn || flow.phase == SignInPhase.disconnected)
                TextButton(
                  key: Key('sign-out-deployment-$d'),
                  onPressed: controller.signOut,
                  child: Text(l.signInSignOut.toUpperCase()),
                ),
              TextButton(
                key: Key('remove-deployment-$d'),
                onPressed: onRemove,
                child: Text(l.notificationsRemoveDevice.toUpperCase()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LockPanel extends ConsumerWidget {
  const _LockPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = MilaLocalizations.of(context);
    final lock = ref.watch(appLockProvider);
    final controller = ref.read(appLockProvider.notifier);
    final unavailable = lock.availability == LockAvailability.unavailable;
    String delayName(LockDelay d) => switch (d) {
      LockDelay.immediately => l.lockImmediately,
      LockDelay.oneMinute => l.lockAfterOneMinute,
      LockDelay.fiveMinutes => l.lockAfterFiveMinutes,
    };
    return Panel(
      title: l.lockTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (unavailable)
            Text(l.lockUnavailable, key: const Key('lock-unavailable'))
          else ...[
            Text(l.lockExplain),
            const SizedBox(height: MonoScale.line / 2),
            StatusLabel(
              lock.enabled ? l.pushStateOn : l.pushStateOff,
              key: const Key('lock-state'),
              tone: lock.enabled ? StateTone.success : null,
            ),
            const SizedBox(height: MonoScale.line / 2),
            if (lock.enabled)
              ConsoleButton(
                key: const Key('lock-off'),
                label: l.notificationsTurnOff,
                onPressed: controller.disable,
              )
            else
              ConsoleButton(
                key: const Key('lock-on'),
                label: l.notificationsTurnOn,
                onPressed: lock.availability == LockAvailability.available
                    ? () => controller.enable(l.lockReason)
                    : null,
              ),
            if (lock.enabled) ...[
              const SizedBox(height: MonoScale.line / 2),
              Text(l.lockAfter),
              Wrap(
                spacing: MonoScale.fontSize / 2,
                children: [
                  for (final d in LockDelay.values)
                    ConsoleButton(
                      key: Key('lock-delay-${d.name}'),
                      label: d == lock.delay ? '${Glyph.check.char} ${delayName(d)}' : delayName(d),
                      onPressed: () => controller.chooseDelay(d),
                    ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}
