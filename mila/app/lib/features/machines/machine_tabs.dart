// The frame every machine page shares: back to the list, the machine's name
// (an identifier, always left to right) and the Info/Terminals/Threads/Web
// tabs, which only navigate.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../../l10n/app_localizations.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../routes.dart';
import 'machines_controller.dart';

const List<MachineTab> machineTabs = [
  MachineTab.info,
  MachineTab.terminals,
  MachineTab.threads,
  MachineTab.web,
];

String machineTabLabel(MilaLocalizations l, MachineTab tab) => switch (tab) {
  MachineTab.overview || MachineTab.info => l.tabInfo,
  MachineTab.terminals => l.tabTerminals,
  MachineTab.threads => l.tabThreads,
  MachineTab.web => l.tabWeb,
};

String machineTabPath(Deployment deployment, String machineId, MachineTab tab) => switch (tab) {
  MachineTab.overview || MachineTab.info => machinePath(deployment, machineId),
  MachineTab.terminals => machineTerminalsPath(deployment, machineId),
  MachineTab.threads => machineThreadsPath(deployment, machineId),
  MachineTab.web => machineWebPath(deployment, machineId),
};

/// The machine's display name, or its id until the list has loaded.
String machineName(WidgetRef ref, Deployment deployment, String machineId) {
  for (final m in ref.watch(machinesProvider(deployment)).machines) {
    if (m.id == machineId) return m.name;
  }
  return machineId;
}

class MachineScaffold extends ConsumerWidget {
  const MachineScaffold({
    super.key,
    required this.deployment,
    required this.machineId,
    required this.tab,
    required this.children,
    this.actions = const [],
    this.body,
  });

  final Deployment deployment;
  final String machineId;
  final MachineTab tab;
  final List<Widget> children;
  final List<Widget> actions;

  /// Replaces the scrolling [children] when a page needs the whole area.
  final Widget? body;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = MilaLocalizations.of(context);
    final selected = machineTabs.indexOf(tab == MachineTab.overview ? MachineTab.info : tab);
    return Scaffold(
      appBar: AppBar(
        leading: TextButton(
          key: const Key('machine-back'),
          onPressed: () => context.go(machinesPath(deployment)),
          child: BackGlyph(label: l.back),
        ),
        title: Text(machineName(ref, deployment, machineId), textDirection: TextDirection.ltr),
        actions: actions,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TopTabs(
            labels: [for (final t in machineTabs) machineTabLabel(l, t)],
            selected: selected,
            onSelected: (index) =>
                context.go(machineTabPath(deployment, machineId, machineTabs[index])),
          ),
          Expanded(
            child:
                body ??
                ListView(padding: const EdgeInsets.all(MonoScale.fontSize), children: children),
          ),
        ],
      ),
    );
  }
}
