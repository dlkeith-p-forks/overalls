/// In-app paths and the mapping from `overalls://` links onto them. A link
/// only ever navigates: it never signs in, mutates or launches by itself.
///
/// Pure Dart, so its property tests run without the Flutter app (and the app
/// builds without the property-test engine).
library;

import 'package:mila_core/mila_core.dart';

import 'mila_transport.dart';

const String deploymentsPath = '/';
const String settingsPath = '/settings';

String _d(Deployment deployment) => '/d/${Uri.encodeComponent(deployment.toString())}';

String signInPath(Deployment deployment) => '${_d(deployment)}/sign-in';
String machinesPath(Deployment deployment) => '${_d(deployment)}/machines';
String machinePath(Deployment deployment, String id) => '${_d(deployment)}/machines/$id';
String notificationsPath(Deployment deployment) => '${_d(deployment)}/notifications';

/// Every in-app page of [deployment] starts with this prefix.
String deploymentRoot(Deployment deployment) => '${_d(deployment)}/';
String machineTerminalsPath(Deployment deployment, String id) =>
    '${machinePath(deployment, id)}/terminals';
String machineTerminalPath(Deployment deployment, String id, String session) =>
    '${machineTerminalsPath(deployment, id)}/$session';
String machineThreadsPath(Deployment deployment, String id) =>
    '${machinePath(deployment, id)}/threads';
String machineThreadPath(Deployment deployment, String id, String thread) =>
    '${machineThreadsPath(deployment, id)}/$thread';
String machineWebPath(Deployment deployment, String id) => '${machinePath(deployment, id)}/web';
String threadsPath(Deployment deployment) => '${_d(deployment)}/threads';
String threadPath(Deployment deployment, String thread) => '${threadsPath(deployment)}/$thread';

/// Decodes the deployment segment of an in-app path.
Deployment? deploymentFromSegment(String? segment) =>
    segment == null ? null : parseDeployment(Uri.decodeComponent(segment));

/// Where a link leads, or why it cannot be followed.
sealed class LinkTarget {
  const LinkTarget();
}

/// Navigate to [path].
final class OpenPath extends LinkTarget {
  const OpenPath(this.path);
  final String path;
}

/// The link names a deployment the user has not added.
final class UnknownDeployment extends LinkTarget {
  const UnknownDeployment(this.host);
  final String host;
}

/// The link is outside the closed table.
final class RefusedLink extends LinkTarget {
  const RefusedLink();
}

/// Maps [link] to an in-app target given the added [deployments] and which
/// of them are signed in.
LinkTarget linkTarget(
  String link,
  List<Deployment> deployments, {
  required bool Function(Deployment) signedIn,
}) {
  final route = parseMilaRoute(link);
  if (route == null) return const RefusedLink();
  Deployment? deployment;
  for (final d in deployments) {
    if (d.host == route.host && d.port == route.port) deployment = d;
  }
  if (deployment == null) return UnknownDeployment(route.host);
  if (!signedIn(deployment)) return OpenPath(signInPath(deployment));
  return switch (route.page) {
    MachinePage(:final machineId, :final tab) => OpenPath(switch (tab) {
      MachineTab.overview || MachineTab.info => machinePath(deployment, machineId),
      MachineTab.web => machineWebPath(deployment, machineId),
      MachineTab.terminals => machineTerminalsPath(deployment, machineId),
      MachineTab.threads => machineThreadsPath(deployment, machineId),
    }),
    MachineTerminalPage(:final machineId, :final sessionId) => OpenPath(
      machineTerminalPath(deployment, machineId, sessionId),
    ),
    MachineThreadPage(:final machineId, :final threadId) => OpenPath(
      machineThreadPath(deployment, machineId, threadId),
    ),
    ThreadsPage() => OpenPath(threadsPath(deployment)),
    ThreadPage(:final threadId) => OpenPath(threadPath(deployment, threadId)),
    SettingsPage() => const OpenPath(settingsPath),
    // Opening a terminal or thread only navigates: attaching and reading
    // happen on the page, never as a side effect of the link. A launch link
    // never creates a machine without the user confirming it.
    MachinesPage() || LaunchPage() || SshApprovedPage() => OpenPath(machinesPath(deployment)),
  };
}
