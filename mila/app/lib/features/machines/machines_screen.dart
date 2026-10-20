import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../labels.dart';
import '../routes.dart';
import 'machine_actions.dart';
import 'machine_form.dart';
import 'machines_controller.dart';

/// A snapshot time as an identifier-like UTC timestamp, the same in every
/// locale: `2026-10-18 14:05 UTC`.
String formatSavedAt(DateTime at) {
  final utc = at.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${utc.year}-${two(utc.month)}-${two(utc.day)} ${two(utc.hour)}:${two(utc.minute)} UTC';
}

class MachinesScreen extends ConsumerStatefulWidget {
  const MachinesScreen({super.key, required this.deployment});

  final Deployment deployment;

  @override
  ConsumerState<MachinesScreen> createState() => _MachinesScreenState();
}

class _MachinesScreenState extends ConsumerState<MachinesScreen> {
  String _query = '';

  Future<void> _create() async {
    final machines = ref.read(machinesProvider(widget.deployment).notifier);
    final form = await showMachineForm(
      context,
      MachineFormKind.create,
      choices: (machines.images(), machines.teams()),
    );
    if (form == null || !mounted) return;
    await machines.create(
      name: form.name,
      source: form.source,
      image: form.image,
      team: form.team,
      shape: form.shape,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = MilaLocalizations.of(context);
    final view = ref.watch(machinesProvider(widget.deployment));
    final shown = searchMachines(view.machines, _query);
    final controller = ref.read(machinesProvider(widget.deployment).notifier);
    final creating =
        view.requests[newMachineRequest] != null && !view.requests[newMachineRequest]!.terminal;
    return Scaffold(
      appBar: AppBar(
        leading: TextButton(
          onPressed: () => context.go(deploymentsPath),
          child: BackGlyph(label: l.back),
        ),
        title: Text(l.machinesTitle),
        actions: [
          TextButton(
            key: const Key('open-threads'),
            onPressed: () => context.go(threadsPath(widget.deployment)),
            child: Text(l.tabThreads.toUpperCase()),
          ),
          TextButton(
            key: const Key('open-notifications'),
            onPressed: () => context.go(notificationsPath(widget.deployment)),
            child: Text(l.notificationsTitle.toUpperCase()),
          ),
          TextButton(
            key: const Key('machines-refresh'),
            onPressed: controller.refresh,
            child: Text(l.refresh.toUpperCase()),
          ),
          // One glyph wide: the app bar already holds the page's own actions.
          Tooltip(
            message: l.settingsTitle,
            child: TextButton(
              key: const Key('machines-settings'),
              onPressed: () => context.go(settingsPath),
              child: GlyphText(Glyph.menu, label: l.settingsTitle),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: controller.refresh,
        child: ListView(
          padding: const EdgeInsets.all(MonoScale.fontSize),
          children: [
            TextField(
              key: const Key('machines-search'),
              decoration: InputDecoration(
                hintText: l.machinesSearch,
                prefixText: '${Glyph.search.char} ',
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: MonoScale.line / 2),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: ConsoleButton(
                key: const Key('machine-new'),
                label: l.actionNew,
                glyph: Glyph.plus,
                onPressed: creating || view.savedAt != null ? null : _create,
              ),
            ),
            RequestStatus(deployment: widget.deployment, requestKey: newMachineRequest),
            const SizedBox(height: MonoScale.line),
            if (view.failed || view.savedAt != null)
              Wrap(
                spacing: MonoScale.fontSize / 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(l.machinesOffline, key: const Key('machines-offline')),
                  TextButton(
                    key: const Key('machines-retry'),
                    onPressed: view.loading ? null : controller.refresh,
                    child: Text(l.retry.toUpperCase()),
                  ),
                ],
              ),
            if (view.savedAt != null)
              Text(
                l.machinesSavedAt(formatSavedAt(view.savedAt!)),
                key: const Key('machines-saved-at'),
                style: TextStyle(color: MonoTheme.of(context).textAlt),
              ),
            if (!view.loading && view.machines.isEmpty) Text(l.machinesEmpty),
            if (view.machines.isNotEmpty && shown.isEmpty) Text(l.machinesNoMatch),
            for (final machine in shown)
              _MachineRow(
                deployment: widget.deployment,
                machine: machine,
                request: view.requests[machine.id],
                offline: view.savedAt != null,
              ),
            if (view.nextCursor != null && view.savedAt == null)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  key: const Key('machines-more'),
                  onPressed: view.loadingMore ? null : controller.more,
                  child: Text(l.machineMore.toUpperCase()),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MachineRow extends ConsumerWidget {
  const _MachineRow({
    required this.deployment,
    required this.machine,
    this.request,
    this.offline = false,
  });

  /// The row comes from the offline snapshot: shown, not acted on.
  final bool offline;

  final Deployment deployment;
  final Machine machine;
  final RequestPoll? request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = MilaLocalizations.of(context);
    final tokens = MonoTheme.of(context);
    final busy = request != null && !request!.terminal;
    return Padding(
      key: Key('machine-${machine.id}'),
      padding: const EdgeInsets.only(bottom: MonoScale.line / 2),
      child: InkWell(
        onTap: () => context.go(machinePath(deployment, machine.id)),
        child: Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: MonoScale.fontSize,
                children: [
                  Text(
                    machine.name,
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(fontWeight: MonoScale.bold),
                  ),
                  StatusLabel(machine.label.text(l), tone: machine.tone),
                  if (machine.pinned)
                    Text(
                      '${Glyph.star.char} ${l.machinesPinned}',
                      style: TextStyle(color: tokens.textAlt),
                    ),
                ],
              ),
              if (machine.imageName != null)
                Text(machine.imageName!, style: TextStyle(color: tokens.textAlt)),
              if (machine.failureReason != null && machine.observed == ObservedState.failed)
                Text(
                  l.machineFailureReason(machine.failureReason!),
                  key: Key('machine-failure-${machine.id}'),
                ),
              RequestStatus(deployment: deployment, requestKey: machine.id),
              const SizedBox(height: MonoScale.line / 2),
              MachineActions(deployment: deployment, machine: machine, enabled: !busy && !offline),
            ],
          ),
        ),
      ),
    );
  }
}
