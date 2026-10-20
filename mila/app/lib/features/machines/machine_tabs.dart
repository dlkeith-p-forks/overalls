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
String machineName(WidgetRef ref, Deployment deployment, String machineId) =>
    ref.watch(machinesProvider(deployment)).find(machineId)?.name ?? machineId;

class MachineScaffold extends ConsumerWidget {
  const MachineScaffold({
    super.key,
    required this.deployment,
    required this.machineId,
    required this.tab,
    required this.children,
    this.actions = const [],
    this.body,
    this.onRefresh,
  });

  final Deployment deployment;
  final String machineId;
  final MachineTab tab;
  final List<Widget> children;
  final List<Widget> actions;

  /// Replaces the scrolling [children] when a page needs the whole area.
  final Widget? body;

  /// When set, the page offers REFRESH and pull to refresh, which run it.
  final Future<void> Function()? onRefresh;

  Widget _list() {
    final list = ListView(
      padding: const EdgeInsets.all(MonoScale.fontSize),
      physics: const AlwaysScrollableScrollPhysics(),
      children: children,
    );
    return onRefresh == null ? list : RefreshIndicator(onRefresh: onRefresh!, child: list);
  }

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
        actions: [
          ...actions,
          if (onRefresh != null)
            TextButton(
              key: const Key('machine-refresh'),
              onPressed: onRefresh,
              child: Text(l.refresh.toUpperCase()),
            ),
          // One glyph wide: the app bar already holds the page's own actions.
          Tooltip(
            message: l.settingsTitle,
            child: TextButton(
              key: const Key('machine-settings'),
              onPressed: () => context.go(settingsPath),
              child: GlyphText(Glyph.menu, label: l.settingsTitle),
            ),
          ),
        ],
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
          Expanded(child: body ?? _list()),
        ],
      ),
    );
  }
}
