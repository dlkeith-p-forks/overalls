import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../failure_notice.dart';
import '../labels.dart';
import '../machines/machine_tabs.dart';
import '../routes.dart';
import 'terminals_controller.dart';

/// A machine's terminal sessions: open yours, attach to one, close one.
class TerminalsScreen extends ConsumerWidget {
  const TerminalsScreen({super.key, required this.deployment, required this.machineId});

  final Deployment deployment;
  final String machineId;

  Future<void> _kill(BuildContext context, WidgetRef ref, TerminalSession session) async {
    final l = MilaLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l.terminalCloseConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.cancel.toUpperCase()),
          ),
          TextButton(
            key: const Key('confirm-terminal-close'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.terminalClose.toUpperCase()),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(terminalsProvider((deployment, machineId)).notifier).kill(session.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = MilaLocalizations.of(context);
    final tokens = MonoTheme.of(context);
    final view = ref.watch(terminalsProvider((deployment, machineId)));
    final controller = ref.read(terminalsProvider((deployment, machineId)).notifier);
    final busy = view.request != null && !view.request!.terminal;
    return MachineScaffold(
      deployment: deployment,
      machineId: machineId,
      tab: MachineTab.terminals,
      actions: [
        TextButton(
          key: const Key('terminals-refresh'),
          onPressed: controller.refresh,
          child: Text(l.refresh.toUpperCase()),
        ),
      ],
      children: [
        Wrap(
          spacing: MonoScale.fontSize,
          children: [
            ConsoleButton(
              key: const Key('terminal-new'),
              label: l.terminalNew,
              glyph: Glyph.plus,
              onPressed: busy
                  ? null
                  : () async {
                      final id = await controller.open();
                      if (id != null && context.mounted) {
                        context.go(machineTerminalPath(deployment, machineId, id));
                      }
                    },
            ),
          ],
        ),
        if (view.request != null) Text(view.request!.text(l), key: const Key('terminals-request')),
        const SizedBox(height: MonoScale.line),
        if (view.failed)
          FailureNotice(
            message: l.terminalsFailed,
            messageKey: const Key('terminals-failed'),
            retryKey: const Key('terminals-retry'),
            onRetry: controller.refresh,
          ),
        if (!view.loading && !view.failed && view.sessions.isEmpty) Text(l.terminalsEmpty),
        for (final session in view.sessions)
          Padding(
            key: Key('terminal-${session.id}'),
            padding: const EdgeInsets.only(bottom: MonoScale.line / 2),
            child: InkWell(
              onTap: () => context.go(machineTerminalPath(deployment, machineId, session.id)),
              child: Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: MonoScale.fontSize,
                      children: [
                        Text(
                          session.guestUser ?? session.id.substring(0, 8),
                          textDirection: TextDirection.ltr,
                          style: const TextStyle(fontWeight: MonoScale.bold),
                        ),
                        Text(
                          '${session.columns}${Glyph.cross.char}${session.rows}',
                          textDirection: TextDirection.ltr,
                        ),
                        if (session.mine) StatusLabel(l.terminalMine),
                        if (session.killStatus == KillStatus.closing)
                          StatusLabel(l.terminalClosing, tone: StateTone.pending),
                      ],
                    ),
                    Text(
                      l.terminalViewers(session.viewers),
                      style: TextStyle(color: tokens.textAlt),
                    ),
                    const SizedBox(height: MonoScale.line / 2),
                    Wrap(
                      spacing: MonoScale.fontSize / 2,
                      children: [
                        ConsoleButton(
                          key: Key('terminal-open-${session.id}'),
                          label: l.terminalAttach,
                          onPressed: () =>
                              context.go(machineTerminalPath(deployment, machineId, session.id)),
                        ),
                        if (session.canKill)
                          ConsoleButton(
                            key: Key('terminal-kill-${session.id}'),
                            label: l.terminalClose,
                            onPressed: busy ? null : () => _kill(context, ref, session),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
