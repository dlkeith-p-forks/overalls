// In-app paths and the mapping from `overalls://` links onto them. A link
// only ever navigates: it never signs in, mutates or launches by itself.
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

const String deploymentsPath = '/';
const String settingsPath = '/settings';

String _d(Deployment deployment) => '/d/${Uri.encodeComponent(deployment.toString())}';

String signInPath(Deployment deployment) => '${_d(deployment)}/sign-in';
String machinesPath(Deployment deployment) => '${_d(deployment)}/machines';
String machinePath(Deployment deployment, String id) => '${_d(deployment)}/machines/$id';
String notificationsPath(Deployment deployment) => '${_d(deployment)}/notifications';

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
    MachinePage(:final machineId) ||
    MachineTerminalPage(:final machineId) ||
    MachineThreadPage(:final machineId) => OpenPath(machinePath(deployment, machineId)),
    SettingsPage() => const OpenPath(settingsPath),
    // Pages later milestones add land on the machine list for now; a launch
    // link never creates a machine without the user confirming it.
    MachinesPage() ||
    ThreadsPage() ||
    ThreadPage() ||
    LaunchPage() ||
    SshApprovedPage() => OpenPath(machinesPath(deployment)),
  };
}
