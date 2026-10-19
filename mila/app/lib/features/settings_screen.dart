import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:mila_core/mila_core.dart';

import '../l10n/app_localizations.dart';
import '../ui/theme.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'lock/app_lock_controller.dart';
import 'routes.dart';
import 'session.dart';

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
          ],
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
