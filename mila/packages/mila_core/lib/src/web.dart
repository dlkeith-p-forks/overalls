/// A machine's published web endpoint as `web show|set --json` report it,
/// and the `web set` change Mila sends (ADR-0222).
library;

import 'app_route.dart';
import 'ssh_command.dart';

/// Who may open the endpoint.
enum WebVisibility { public, private }

/// Why a web result could not be decoded.
final class WebFormatException implements Exception {
  const WebFormatException(this.field);
  final String field;
  @override
  String toString() => 'WebFormatException($field)';
}

/// One machine's web endpoint.
final class WebEndpoint {
  const WebEndpoint({
    required this.machineId,
    required this.port,
    required this.visibility,
    required this.revision,
    this.label,
    this.url,
    this.route,
  });

  final String machineId;

  /// The guest port the endpoint forwards to.
  final int port;
  final WebVisibility visibility;

  /// `policy_revision`: a change names it so a concurrent edit is refused.
  final int revision;

  /// The endpoint's DNS label; an identifier, shown LTR.
  final String? label;

  /// The HTTPS address, when the deployment publishes an ingress zone.
  final Uri? url;
  final MilaRoute? route;
}

final RegExp _label = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');

/// Accepts only an HTTPS URL on a DNS host, with no credentials, so a reply
/// cannot make Mila open another scheme or a lookalike with userinfo.
Uri? _httpsUrl(Object? value) {
  if (value is! String || value.length > 2048) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) return null;
  if (!isHostname(uri.host) || uri.hasFragment) return null;
  return uri;
}

/// Decodes `web show --json` and the result of `web set`.
WebEndpoint decodeWebEndpoint(Map<String, Object?> result) {
  final machineId = result['machine_id'];
  if (machineId is! String || !isCanonicalUuid(machineId)) {
    throw const WebFormatException('machine_id');
  }
  final port = result['port'];
  if (port is! int || port < 1 || port > 65535) throw const WebFormatException('port');
  final visibility = switch (result['visibility']) {
    'public' => WebVisibility.public,
    'private' => WebVisibility.private,
    _ => throw const WebFormatException('visibility'),
  };
  final revision = result['policy_revision'];
  if (revision is! int || revision < 1) throw const WebFormatException('policy_revision');
  final label = result['label'];
  final routeText = result['route'];
  final route = routeText is String ? parseMilaRoute(routeText) : null;
  final page = route?.page;
  return WebEndpoint(
    machineId: machineId,
    port: port,
    visibility: visibility,
    revision: revision,
    label: label is String && _label.hasMatch(label) ? label : null,
    url: _httpsUrl(result['url']),
    route: page is MachinePage && page.machineId == machineId && page.tab == MachineTab.web
        ? route
        : null,
  );
}

/// Whether [text] is a guest port Mila may ask for.
int? parsePort(String text) {
  final value = text.trim();
  if (value.isEmpty || value.length > 5) return null;
  final port = int.tryParse(value);
  return port != null && port >= 1 && port <= 65535 && '$port' == value ? port : null;
}

/// Builds the `web set` change from [current] to a new port and/or
/// visibility, at [current]'s revision. Null when nothing changes.
PorscheCommand? webChange(
  WebEndpoint current, {
  int? port,
  WebVisibility? visibility,
  required String requestId,
}) {
  final newPort = port != null && port != current.port ? port : null;
  final newVisibility = visibility != null && visibility != current.visibility ? visibility : null;
  if (newPort == null && newVisibility == null) return null;
  return PorscheCommand(
    'web set',
    arguments: [current.machineId],
    options: {
      'json': true,
      'request-id': requestId,
      'revision': '${current.revision}',
      'port': ?newPort?.toString(),
      if (newVisibility != null) newVisibility.name: true,
    },
  );
}

/// How Mila opens an endpoint.
enum WebOpening {
  /// An in-app webview: public endpoints on iOS and Android.
  inApp,

  /// The system browser, whose session already holds the Marshall sign-in
  /// that private endpoints need (`/audi/authorize`), and on Linux.
  externalBrowser,

  /// Nothing to open: the deployment publishes no address.
  unavailable,
}

/// Where [endpoint] opens on a platform with or without an in-app webview.
WebOpening webOpening(WebEndpoint endpoint, {required bool inAppWebView}) {
  if (endpoint.url == null) return WebOpening.unavailable;
  return endpoint.visibility == WebVisibility.public && inAppWebView
      ? WebOpening.inApp
      : WebOpening.externalBrowser;
}
