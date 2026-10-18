// The boundary between Mila's features and its SSH transport. Features only
// see validated command lines going out and decoded outcomes coming back;
// they never hold sockets, keys or raw channel bytes.
import 'package:mila_core/mila_core.dart';

/// A deployment Mila can sign in to: a management host and optional port.
final class Deployment {
  const Deployment(this.host, {this.port});

  final String host;

  /// Null means Porsche's default port.
  final int? port;

  @override
  bool operator ==(Object other) => other is Deployment && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => port == null ? host : '$host:$port';
}

/// Parses a user-entered deployment, accepting only a DNS host and port.
Deployment? parseDeployment(String input) {
  final value = input.trim().toLowerCase();
  final colon = value.lastIndexOf(':');
  if (colon < 0) return isHostname(value) ? Deployment(value) : null;
  final host = value.substring(0, colon);
  final port = int.tryParse(value.substring(colon + 1));
  if (!isHostname(host) || port == null || port < 1 || port > 65535) return null;
  return Deployment(host, port: port);
}

/// One authenticated-or-pending Porsche connection.
abstract interface class PorscheSession {
  /// Which connection this is; changes on every reconnect.
  int get generation;

  /// Runs [command] on a fresh exec channel. [stdin] is sent then closed.
  Future<ChannelOutcome> exec(PorscheCommand command, {List<int>? stdin});

  /// Completes when the connection closes, for any reason.
  Future<void> get closed;

  Future<void> close();
}

/// Why a connection could not be opened.
enum ConnectFailure { hostUntrusted, unreachable }

final class ConnectException implements Exception {
  const ConnectException(this.failure);
  final ConnectFailure failure;
  @override
  String toString() => 'ConnectException(${failure.name})';
}

/// Opens verified connections to a deployment's Porsche gateway.
abstract interface class PorscheConnector {
  /// Fetches and pins the deployment's trust document, opens SSH with the
  /// device key, and verifies the host certificate. Throws [ConnectException].
  Future<PorscheSession> connect(Deployment deployment, {required int generation});
}
