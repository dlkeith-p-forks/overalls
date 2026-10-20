// What a machine row and its Info tab both offer: the lifecycle actions,
// with the delete confirmation, and a tracked request's status with its
// Retry and Cancel controls where Porsche accepts them.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../../l10n/app_localizations.dart';
import '../../ui/tokens.dart';
import '../labels.dart';
import '../../ui/widgets.dart';
import 'machines_controller.dart';

/// The lifecycle buttons [MachineAction.available] allows on [machine].
class MachineActions extends ConsumerWidget {
  const MachineActions({
    super.key,
    required this.deployment,
    required this.machine,
    this.enabled = true,
    this.onDeleted,
  });

  final Deployment deployment;
  final Machine machine;

  /// False while a request runs or the list is the offline snapshot.
  final bool enabled;

  /// Called once a delete has succeeded.
  final VoidCallback? onDeleted;

  Future<void> _act(BuildContext context, WidgetRef ref, MachineAction action) async {
    final l = MilaLocalizations.of(context);
    if (action == MachineAction.delete) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(l.confirmDelete(machine.name)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l.cancel.toUpperCase()),
            ),
            TextButton(
              key: const Key('confirm-delete'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l.actionDelete.toUpperCase()),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    final poll = await ref.read(machinesProvider(deployment).notifier).perform(machine, action);
    if (action == MachineAction.delete && poll.phase == PollPhase.succeeded) onDeleted?.call();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = MilaLocalizations.of(context);
    return Wrap(
      spacing: MonoScale.fontSize / 2,
      runSpacing: MonoScale.line / 2,
      children: [
        for (final action in MachineAction.available(machine))
          ConsoleButton(
            key: Key('action-${action.name}-${machine.id}'),
            label: action.text(l),
            onPressed: enabled ? () => _act(context, ref, action) : null,
          ),
      ],
    );
  }
}

/// A tracked request's status under [requestKey], with Cancel while an
/// admitted clone or resize runs and Retry once it has failed.
class RequestStatus extends ConsumerWidget {
  const RequestStatus({super.key, required this.deployment, required this.requestKey});

  final Deployment deployment;
  final String requestKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = MilaLocalizations.of(context);
    final view = ref.watch(machinesProvider(deployment));
    final poll = view.requests[requestKey];
    if (poll == null) return const SizedBox.shrink();
    final controllable = view.controls.containsKey(requestKey) && view.savedAt == null;
    final controller = ref.read(machinesProvider(deployment).notifier);
    final cancel = controllable && poll.phase == PollPhase.accepted;
    final retry = controllable && poll.phase == PollPhase.failed;
    return Wrap(
      spacing: MonoScale.fontSize / 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(poll.text(l), key: Key('request-$requestKey')),
        if (retry)
          TextButton(
            key: Key('request-retry-$requestKey'),
            onPressed: () => controller.control(requestKey, RequestControl.retry),
            child: Text(l.retry.toUpperCase()),
          ),
        if (cancel)
          TextButton(
            key: Key('request-cancel-$requestKey'),
            onPressed: () => controller.control(requestKey, RequestControl.cancel),
            child: Text(l.cancel.toUpperCase()),
          ),
      ],
    );
  }
}
