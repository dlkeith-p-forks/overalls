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
import 'machines_controller.dart';

/// One machine's Info tab.
class MachineScreen extends ConsumerWidget {
  const MachineScreen({super.key, required this.deployment, required this.machineId});

  final Deployment deployment;
  final String machineId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = MilaLocalizations.of(context);
    final view = ref.watch(machinesProvider(deployment));
    Machine? machine;
    for (final m in view.machines) {
      if (m.id == machineId) machine = m;
    }
    return Scaffold(
      appBar: AppBar(
        leading: TextButton(
          onPressed: () => context.go(machinesPath(deployment)),
          child: BackGlyph(label: l.back),
        ),
        title: Text(machine?.name ?? machineId, textDirection: TextDirection.ltr),
      ),
      body: ListView(
        padding: const EdgeInsets.all(MonoScale.fontSize),
        children: [
          if (machine == null)
            Text(l.machinesNoMatch)
          else
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
                    Kv(l.kvDisk, Text(l.diskGib(machine.diskBytes! ~/ (1024 * 1024 * 1024)))),
                  if (machine.sshHost != null)
                    Kv(
                      l.kvSshHost,
                      SelectableText(machine.sshHost!, textDirection: TextDirection.ltr),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
