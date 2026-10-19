/// The `watch` change-notice stream (ADR-0222): JSON lines on a long-lived
/// exec channel, a 15-second heartbeat, and the client-side liveness and
/// reconnect policy. Notices carry identifiers only; Mila re-reads through
/// the ordinary authorized commands.
library;

import 'dart:convert';

import 'app_route.dart';
import 'backoff.dart';
import 'porsche_reply.dart';
import 'ssh_command.dart';

/// Porsche's heartbeat interval.
const Duration watchHeartbeat = Duration(seconds: 15);

/// A watch with no line for this long is presumed dead and reopened: two
/// missed heartbeats plus slack for a slow link.
const Duration watchSilenceLimit = Duration(seconds: 40);

/// The longest line Mila reads from a watch; longer is a protocol error.
const int maximumWatchLineBytes = 65536;

/// One decoded watch line.
sealed class WatchEvent {
  const WatchEvent();
}

/// The subscription Marshall authorized: canonical ids only.
final class Watching extends WatchEvent {
  const Watching(this.sessionId, this.machines, this.threads);
  final String sessionId;
  final List<String> machines;
  final List<String> threads;
}

final class Heartbeat extends WatchEvent {
  const Heartbeat();
}

/// Something about a machine changed; re-read it.
final class MachineChanged extends WatchEvent {
  const MachineChanged(this.machineId);
  final String machineId;
}

/// A machine's terminal sessions changed; re-run `terminal ls`.
final class TerminalSessionsChanged extends WatchEvent {
  const TerminalSessionsChanged(this.machineId);
  final String machineId;
}

/// A thread changed; re-read it and its turns.
final class ThreadChanged extends WatchEvent {
  const ThreadChanged(this.threadId);
  final String threadId;
}

/// Hints may have been lost; re-read everything watched.
final class Resync extends WatchEvent {
  const Resync();
}

/// The SSH session's approval state (`--session`).
final class SessionNotice extends WatchEvent {
  const SessionNotice(this.sessionId, {required this.authenticated});
  final String sessionId;
  final bool authenticated;
}

/// A newer server's event this client does not know; ignored.
final class UnknownWatchEvent extends WatchEvent {
  const UnknownWatchEvent();
}

/// The stream ended with a Porsche refusal envelope.
final class WatchRefused extends WatchEvent {
  const WatchRefused(this.error);
  final String error;
}

/// A line outside the schema.
final class WatchFormatException implements Exception {
  const WatchFormatException(this.message);
  final String message;
  @override
  String toString() => 'WatchFormatException($message)';
}

List<String> _uuids(Object? value, String field) {
  if (value is! List<Object?> || value.length > maximumWatchFilters) {
    throw WatchFormatException(field);
  }
  return List.unmodifiable([
    for (final id in value)
      if (id is String && isCanonicalUuid(id)) id else throw WatchFormatException(field),
  ]);
}

String _id(Map<String, Object?> value, String key) {
  final id = value[key];
  if (id is! String || !isCanonicalUuid(id)) throw WatchFormatException(key);
  return id;
}

/// Decodes one watch line. The envelope (`version`, `event`) is strict and
/// so are the identifiers; an unknown event is tolerated. A Porsche error
/// envelope is the stream's last word.
WatchEvent decodeWatchLine(String line) {
  if (utf8.encode(line).length > maximumWatchLineBytes) {
    throw const WatchFormatException('too long');
  }
  final Object? value;
  try {
    value = jsonDecode(line);
  } on FormatException {
    throw const WatchFormatException('not json');
  }
  if (value is! Map<String, Object?>) throw const WatchFormatException('not an object');
  if (value['version'] != 1) throw const WatchFormatException('version');
  if (value.containsKey('status')) {
    final reply = decodeReply(value);
    return switch (reply) {
      ErrorReply(:final error) => WatchRefused(error),
      ApprovalReply() => const WatchRefused('approval_required'),
      _ => throw const WatchFormatException('status'),
    };
  }
  return switch (value['event']) {
    'watching' => Watching(
      _id(value, 'session_id'),
      _uuids(value['machines'], 'machines'),
      _uuids(value['threads'], 'threads'),
    ),
    'heartbeat' => const Heartbeat(),
    'machine' => MachineChanged(_id(value, 'id')),
    'terminal_session' => TerminalSessionsChanged(_id(value, 'machine_id')),
    'thread' => ThreadChanged(_id(value, 'id')),
    'resync' => const Resync(),
    'session' => SessionNotice(_id(value, 'id'), authenticated: value['status'] == 'authenticated'),
    final String _ => const UnknownWatchEvent(),
    _ => throw const WatchFormatException('event'),
  };
}

/// Splits a byte stream into newline-terminated lines, whatever the chunk
/// boundaries, refusing any line longer than [maximumWatchLineBytes].
final class LineFramer {
  final List<int> _pending = [];

  /// Feeds [chunk]; returns the complete lines it finished.
  List<String> add(List<int> chunk) {
    final lines = <String>[];
    for (final byte in chunk) {
      if (byte == 0x0a) {
        try {
          lines.add(utf8.decode(_pending));
        } on FormatException {
          throw const WatchFormatException('not utf-8');
        } finally {
          _pending.clear();
        }
      } else {
        _pending.add(byte);
        if (_pending.length > maximumWatchLineBytes) {
          throw const WatchFormatException('too long');
        }
      }
    }
    return lines;
  }

  /// Bytes received after the last newline.
  int get pending => _pending.length;
}

/// What a watch subscribes to.
final class WatchFilter {
  WatchFilter({Iterable<String> machines = const [], Iterable<String> threads = const []})
    : machines = List.unmodifiable(machines.toSet().take(maximumWatchFilters).toList()..sort()),
      threads = List.unmodifiable(threads.toSet().take(maximumWatchFilters).toList()..sort());

  final List<String> machines;
  final List<String> threads;

  bool get isEmpty => machines.isEmpty && threads.isEmpty;

  /// The `watch` command for this filter.
  PorscheCommand command() => PorscheCommand(
    'watch',
    options: {
      'json': true,
      if (machines.length == 1) 'machine': machines.single,
      if (machines.length > 1) 'machine': machines,
      if (threads.length == 1) 'thread': threads.single,
      if (threads.length > 1) 'thread': threads,
    },
  );

  @override
  bool operator ==(Object other) =>
      other is WatchFilter &&
      other.machines.join(',') == machines.join(',') &&
      other.threads.join(',') == threads.join(',');

  @override
  int get hashCode => Object.hash(machines.join(','), threads.join(','));
}

/// Where a watch supervisor stands.
enum WatchPhase { idle, opening, live, waiting, stopped }

/// Why a watch stopped for good.
enum WatchStop { refused, authority, invalid, closed }

/// The reconnect policy for one watch: pure, driven by the transport.
final class WatchSupervisor {
  const WatchSupervisor._(this.phase, this.generation, this.attempts, this.stop);

  const WatchSupervisor.initial() : this._(WatchPhase.idle, 0, 0, null);

  final WatchPhase phase;
  final int generation;

  /// Consecutive failed opens since the last line.
  final int attempts;
  final WatchStop? stop;

  static const Backoff backoff = Backoff(base: Duration(seconds: 1), cap: Duration(seconds: 60));

  /// Open a channel (first open or after the backoff).
  WatchSupervisor open() => phase == WatchPhase.stopped || phase == WatchPhase.opening
      ? this
      : WatchSupervisor._(WatchPhase.opening, generation + 1, attempts, null);

  /// A line arrived on [generation]'s channel.
  WatchSupervisor received(int generation, WatchEvent event) {
    if (generation != this.generation ||
        (phase != WatchPhase.opening && phase != WatchPhase.live)) {
      return this;
    }
    if (event is WatchRefused) return _ended(generation, PorscheExit.invalid, event.error);
    return WatchSupervisor._(WatchPhase.live, generation, 0, null);
  }

  /// [generation]'s channel ended with [exit] (null: the connection dropped
  /// or the stream went silent). [error] is the refusal reason, if any.
  WatchSupervisor ended(int generation, PorscheExit? exit, [String? error]) =>
      generation != this.generation || phase == WatchPhase.stopped
      ? this
      : _ended(generation, exit, error);

  WatchSupervisor _ended(int generation, PorscheExit? exit, String? error) {
    final stop = switch ((exit, error)) {
      (_, 'unauthorized' || 'approval_required') => WatchStop.authority,
      (_, 'forbidden' || 'not_found') => WatchStop.refused,
      (PorscheExit.authority, _) => WatchStop.authority,
      (PorscheExit.invalid, _) => WatchStop.invalid,
      _ => null,
    };
    if (stop != null) return WatchSupervisor._(WatchPhase.stopped, generation, attempts, stop);
    return WatchSupervisor._(WatchPhase.waiting, generation, attempts + 1, null);
  }

  /// The user closed the screen that needed the watch.
  WatchSupervisor close() =>
      WatchSupervisor._(WatchPhase.stopped, generation, attempts, WatchStop.closed);
}
