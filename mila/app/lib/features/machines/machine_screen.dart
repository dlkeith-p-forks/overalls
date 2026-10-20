import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../../l10n/app_localizations.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../labels.dart';
import '../routes.dart';
import '../session.dart';
import 'machine_actions.dart';
import 'machine_form.dart';
import 'machine_tabs.dart';
import 'machines_controller.dart';
import 'machines_screen.dart' show formatSavedAt;
import 'sharing_controller.dart';

/// One machine's Info tab: its state and shape, its lifecycle actions,
/// resize and clone, and its sharing. A machine no loaded page lists, such
/// as one opened from a link, is read on its own with `show`.
class MachineScreen extends ConsumerStatefulWidget {
  const MachineScreen({super.key, required this.deployment, required this.machineId});

  final Deployment deployment;
  final String machineId;

  @override
  ConsumerState<MachineScreen> createState() => _MachineScreenState();
}

class _MachineScreenState extends ConsumerState<MachineScreen> {
  String? _requested;

  Deployment get deployment => widget.deployment;
  String get machineId => widget.machineId;

  Future<void> _reshape(Machine machine, MachineFormKind kind) async {
    final form = await showMachineForm(context, kind, machine: machine);
    if (form == null) return;
    final machines = ref.read(machinesProvider(deployment).notifier);
    if (kind == MachineFormKind.resize) {
      await machines.resize(machine, form.shape);
    } else {
      await machines.clone(machine, name: form.name);
    }
  }

  Future<void> _refresh() async {
    final machines = ref.read(machinesProvider(deployment).notifier);
    await machines.refresh();
    await machines.fetch(machineId);
    if (!mounted) return;
    final machine = ref.read(machinesProvider(deployment)).find(machineId);
    if (machine != null && machine.permissions.manage) {
      await ref.read(sharingProvider((deployment, machineId)).notifier).refresh();
    }
  }

  String _desired(MilaLocalizations l, DesiredState desired) => switch (desired) {
    DesiredState.running => l.stateRunning,
    DesiredState.stopped => l.stateStopped,
    DesiredState.paused => l.statePaused,
    DesiredState.deleted => l.stateDeleted,
  };

  @override
  Widget build(BuildContext context) {
    final l = MilaLocalizations.of(context);
    final view = ref.watch(machinesProvider(deployment));
    final machine = view.find(machineId);
    final live = ref.watch(sessionProvider(deployment)) != null;
    final missing = view.missing.contains(machineId);
    // Once the first page is in without this machine, read it by id once.
    if (machine == null && live && !view.loading && !missing && _requested != machineId) {
      _requested = machineId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(machinesProvider(deployment).notifier).fetch(machineId);
      });
    }
    final request = view.requests[machineId];
    final busy = (request != null && !request.terminal) || view.savedAt != null;
    return MachineScaffold(
      deployment: deployment,
      machineId: machineId,
      tab: MachineTab.info,
      onRefresh: live ? _refresh : null,
      children: [
        if (machine == null)
          Text(
            missing || !live ? l.machineNotFound : l.machineLoading,
            key: const Key('machine-not-loaded'),
          )
        else ...[
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Kv(
                  l.kvState,
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: StatusLabel(machine.label.text(l), tone: machine.tone),
                  ),
                ),
                Kv(l.machineDesired, Text(_desired(l, machine.desired))),
                if (machine.failureReason != null)
                  Kv(
                    l.machineFailure,
                    SelectableText(
                      machine.failureReason!,
                      key: const Key('machine-failure'),
                      textDirection: TextDirection.ltr,
                    ),
                  ),
                if (machine.resizing || machine.relocating)
                  Kv(
                    l.machineChanging,
                    Text(
                      [
                        if (machine.resizing) l.machineResizing,
                        if (machine.relocating) l.machineRelocating,
                      ].join(' · '),
                    ),
                  ),
                Kv(
                  l.machineAccess,
                  Text(machine.owner ? l.machineAccessOwner : l.machineAccessShared),
                ),
                if (machine.imageName != null) Kv(l.kvImage, Text(machine.imageName!)),
                if (machine.architecture != null)
                  Kv(
                    l.machineArchitecture,
                    Text(machine.architecture!, textDirection: TextDirection.ltr),
                  ),
                if (machine.profile != null)
                  Kv(l.machineProfile, Text(machine.profile!, textDirection: TextDirection.ltr)),
                if (machine.vcpu != null) Kv(l.kvCpu, Text(l.cpuCount(machine.vcpu!))),
                if (machine.memoryBytes != null)
                  Kv(l.kvMemory, Text(l.memoryMib(machine.memoryBytes! ~/ (1024 * 1024)))),
                if (machine.diskBytes != null)
                  Kv(l.kvDisk, Text(l.diskGib(machine.diskBytes! ~/ gibibyte))),
                if (machine.sshHost != null)
                  Kv(
                    l.kvSshHost,
                    SelectableText(machine.sshHost!, textDirection: TextDirection.ltr),
                  ),
                if (machine.createdAt != null)
                  Kv(
                    l.machineCreated,
                    Text(formatSavedAt(machine.createdAt!), textDirection: TextDirection.ltr),
                  ),
                Kv(
                  l.machineId,
                  SelectableText(
                    machine.id,
                    key: const Key('machine-id'),
                    textDirection: TextDirection.ltr,
                  ),
                ),
                RequestStatus(deployment: deployment, requestKey: machineId),
                const SizedBox(height: MonoScale.line / 2),
                MachineActions(
                  deployment: deployment,
                  machine: machine,
                  enabled: !busy,
                  onDeleted: () {
                    if (mounted) context.go(machinesPath(deployment));
                  },
                ),
                const SizedBox(height: MonoScale.line / 2),
                Wrap(
                  spacing: MonoScale.fontSize / 2,
                  runSpacing: MonoScale.line / 2,
                  children: [
                    if (machine.permissions.manage)
                      ConsoleButton(
                        key: const Key('machine-resize'),
                        label: l.actionResize,
                        onPressed: busy ? null : () => _reshape(machine, MachineFormKind.resize),
                      ),
                    if (machine.permissions.write)
                      ConsoleButton(
                        key: const Key('machine-clone'),
                        label: l.actionClone,
                        onPressed: busy ? null : () => _reshape(machine, MachineFormKind.clone),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (machine.permissions.manage) ...[
            const SizedBox(height: MonoScale.line),
            _SharingPanel(deployment: deployment, machineId: machineId),
          ],
        ],
      ],
    );
  }
}

/// Who the machine is shared with, and adding or removing a grant.
class _SharingPanel extends ConsumerStatefulWidget {
  const _SharingPanel({required this.deployment, required this.machineId});

  final Deployment deployment;
  final String machineId;

  @override
  ConsumerState<_SharingPanel> createState() => _SharingPanelState();
}

class _SharingPanelState extends ConsumerState<_SharingPanel> {
  final TextEditingController _email = TextEditingController();
  ShareRole _role = ShareRole.viewer;
  bool _emailInvalid = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  String _roleText(MilaLocalizations l, ShareRole role) => switch (role) {
    ShareRole.viewer => l.shareRoleViewer,
    ShareRole.operator => l.shareRoleOperator,
    ShareRole.manager => l.shareRoleManager,
  };

  Future<void> _add(SharingController controller) async {
    final email = _email.text.trim();
    final valid = isShareEmail(email);
    setState(() => _emailInvalid = !valid);
    if (!valid) return;
    if (await controller.add(email, _role) && mounted) _email.clear();
  }

  Future<void> _remove(SharingController controller, String email) async {
    final l = MilaLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l.sharingRemoveConfirm(email)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.cancel.toUpperCase()),
          ),
          TextButton(
            key: const Key('confirm-share-remove'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.sharingRemove.toUpperCase()),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.remove(email);
  }

  @override
  Widget build(BuildContext context) {
    final l = MilaLocalizations.of(context);
    final key = (widget.deployment, widget.machineId);
    final view = ref.watch(sharingProvider(key));
    final controller = ref.read(sharingProvider(key).notifier);
    final listing = view.listing;
    Widget email(String text) => Text(text, textDirection: TextDirection.ltr);
    return Panel(
      title: l.sharingTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (view.failed && listing == null)
            Wrap(
              spacing: MonoScale.fontSize / 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(l.sharingFailed, key: const Key('share-failed')),
                TextButton(
                  key: const Key('share-retry'),
                  onPressed: controller.refresh,
                  child: Text(l.retry.toUpperCase()),
                ),
              ],
            ),
          if (listing != null) ...[
            MonoTable(
              key: const Key('share-table'),
              headers: [l.sharingEmail, l.sharingRole, ''],
              rows: [
                [email(listing.ownerEmail), StatusLabel(l.shareRoleOwner), const SizedBox.shrink()],
                for (final grant in listing.grants)
                  [
                    email(grant.email),
                    Text(_roleText(l, grant.role)),
                    TextButton(
                      key: Key('share-remove-${grant.userId}'),
                      onPressed: view.saving ? null : () => _remove(controller, grant.email),
                      child: Text(l.sharingRemove.toUpperCase()),
                    ),
                  ],
              ],
            ),
            if (listing.grants.isEmpty) Text(l.sharingEmpty, key: const Key('share-empty')),
            if (listing.nextCursor != null)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  key: const Key('share-more'),
                  onPressed: controller.more,
                  child: Text(l.sharingMore.toUpperCase()),
                ),
              ),
          ],
          const SizedBox(height: MonoScale.line / 2),
          TextField(
            key: const Key('share-email'),
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
              labelText: l.sharingEmail,
              errorText: _emailInvalid ? l.sharingEmailInvalid : null,
            ),
          ),
          const SizedBox(height: MonoScale.line / 2),
          Segmented<ShareRole>(
            keyPrefix: 'share-role',
            options: ShareRole.values,
            selected: _role,
            label: (role) => _roleText(l, role),
            onSelected: view.saving ? null : (role) => setState(() => _role = role),
          ),
          const SizedBox(height: MonoScale.line / 2),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: ConsoleButton(
              key: const Key('share-add'),
              label: l.sharingAdd,
              glyph: Glyph.plus,
              onPressed: view.saving ? null : () => _add(controller),
            ),
          ),
          if (view.saving) Text(l.requestWaiting),
          if (view.failure != null)
            Text(
              switch (view.failure!) {
                ShareChangeFailure.refused => l.requestRefused,
                ShareChangeFailure.failed => l.requestFailed,
              },
              key: const Key('share-change-failed'),
              style: const TextStyle(fontWeight: MonoScale.bold),
            ),
        ],
      ),
    );
  }
}
