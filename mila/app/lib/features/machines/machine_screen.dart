import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../../l10n/app_localizations.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../labels.dart';
import 'machine_form.dart';
import 'machine_tabs.dart';
import 'machines_controller.dart';
import 'sharing_controller.dart';

/// One machine's Info tab: its shape, resize and clone, and its sharing.
class MachineScreen extends ConsumerWidget {
  const MachineScreen({super.key, required this.deployment, required this.machineId});

  final Deployment deployment;
  final String machineId;

  Future<void> _reshape(
    BuildContext context,
    WidgetRef ref,
    Machine machine,
    MachineFormKind kind,
  ) async {
    final form = await showMachineForm(context, kind, machine: machine);
    if (form == null) return;
    final machines = ref.read(machinesProvider(deployment).notifier);
    if (kind == MachineFormKind.resize) {
      await machines.resize(machine, form.shape);
    } else {
      await machines.clone(machine, name: form.name);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = MilaLocalizations.of(context);
    final view = ref.watch(machinesProvider(deployment));
    Machine? machine;
    for (final m in view.machines) {
      if (m.id == machineId) machine = m;
    }
    final request = view.requests[machineId];
    final busy = (request != null && !request.terminal) || view.savedAt != null;
    return MachineScaffold(
      deployment: deployment,
      machineId: machineId,
      tab: MachineTab.info,
      children: [
        if (machine == null)
          Text(l.machinesNoMatch)
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
                if (machine.imageName != null) Kv(l.kvImage, Text(machine.imageName!)),
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
                if (request != null) Text(request.text(l), key: Key('request-$machineId')),
                const SizedBox(height: MonoScale.line / 2),
                Wrap(
                  spacing: MonoScale.fontSize / 2,
                  runSpacing: MonoScale.line / 2,
                  children: [
                    if (machine.permissions.manage)
                      ConsoleButton(
                        key: const Key('machine-resize'),
                        label: l.actionResize,
                        onPressed: busy
                            ? null
                            : () => _reshape(context, ref, machine!, MachineFormKind.resize),
                      ),
                    if (machine.permissions.write)
                      ConsoleButton(
                        key: const Key('machine-clone'),
                        label: l.actionClone,
                        onPressed: busy
                            ? null
                            : () => _reshape(context, ref, machine!, MachineFormKind.clone),
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
          if (view.failed && listing == null) Text(l.sharingFailed, key: const Key('share-failed')),
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
