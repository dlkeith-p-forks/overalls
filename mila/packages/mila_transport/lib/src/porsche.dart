// The boundary between Mila's features and its SSH transport. Features only
// see validated command lines going out and decoded outcomes coming back;
// they never hold sockets, keys or raw channel bytes.
import 'dart:typed_data';

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

  /// Opens a PTY exec channel for `terminal attach` (ADR-0223) at [size].
  Future<TerminalChannel> attach(PorscheCommand command, {required TerminalSize size});

  /// Opens a long-lived exec channel whose stdout is `watch` JSON lines.
  Future<WatchChannel> watch(PorscheCommand command);

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

/// A terminal size in character cells, bounded as Porsche bounds it.
final class TerminalSize {
  const TerminalSize(this.columns, this.rows);
  final int columns;
  final int rows;

  /// Clamps to the gateway's range (1–4096 columns, 1–512 rows).
  TerminalSize get clamped => TerminalSize(columns.clamp(1, 4096), rows.clamp(1, 512));

  @override
  bool operator ==(Object other) =>
      other is TerminalSize && other.columns == columns && other.rows == rows;

  @override
  int get hashCode => Object.hash(columns, rows);
}

/// What an attach channel reports, in arrival order.
sealed class AttachSignal {
  const AttachSignal();
}

/// The stderr header line, decoded; null when it is outside the schema.
final class AttachHeaderSignal extends AttachSignal {
  const AttachHeaderSignal(this.header);
  final AttachHeader? header;
}

/// Terminal output. The bytes go straight to the emulator: callers MUST NOT
/// store or log them (`mila-terminal-bytes-never-at-rest`).
final class AttachOutputSignal extends AttachSignal {
  const AttachOutputSignal(this.bytes);
  final Uint8List bytes;
}

/// The channel closed; its exit status mapped through the closed table.
final class AttachEndSignal extends AttachSignal {
  const AttachEndSignal(this.outcome);
  final AttachOutcome outcome;
}

/// One `terminal attach` PTY channel.
abstract interface class TerminalChannel {
  /// Header, output and end signals; ends after [AttachEndSignal].
  Stream<AttachSignal> get signals;

  /// Sends input bytes. Callers check `TerminalAttach.canSendInput` first.
  void send(List<int> bytes);

  /// Sends an SSH window-change.
  void resize(TerminalSize size);

  /// Detaches: closes the channel (Porsche ends the attachment, exit 0).
  Future<void> close();
}

/// One `watch` exec channel.
abstract interface class WatchChannel {
  /// Decoded lines; errors with [WatchFormatException] on a bad line, then ends.
  Stream<WatchEvent> get events;

  /// The exit status once the channel closed; null when none was sent.
  Future<PorscheExit?> get exit;

  Future<void> close();
}
