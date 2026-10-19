import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mila_core/mila_core.dart';

import '../../l10n/app_localizations.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'app_lock_controller.dart';

/// Covers Mila while the app lock is closed. The content below is kept
/// offstage: not painted, not in the semantics tree, not in snapshots.
class LockGate extends ConsumerWidget {
  const LockGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lock = ref.watch(appLockProvider);
    if (!lock.obscured) return child;
    return Stack(
      children: [
        Offstage(child: ExcludeSemantics(child: child)),
        const Positioned.fill(child: _LockScreen()),
      ],
    );
  }
}

class _LockScreen extends ConsumerWidget {
  const _LockScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = MilaLocalizations.of(context);
    final lock = ref.watch(appLockProvider);
    return Scaffold(
      key: const Key('lock-screen'),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(MonoScale.fontSize),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l.lockedTitle, style: const TextStyle(fontWeight: MonoScale.bold)),
              const SizedBox(height: MonoScale.line),
              if (lock.lastFailed) ...[
                Text(l.lockFailed, key: const Key('lock-failed')),
                const SizedBox(height: MonoScale.line),
              ],
              ConsoleButton(
                key: const Key('unlock'),
                label: l.unlock,
                onPressed:
                    lock.phase == LockPhase.locked &&
                        lock.availability == LockAvailability.available
                    ? () => ref.read(appLockProvider.notifier).unlock(l.lockReason)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
