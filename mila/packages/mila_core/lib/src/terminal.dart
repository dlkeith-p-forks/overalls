/// Terminal sessions as `terminal ls|new|kill --json` report them, and the
/// `terminal attach` stderr header and exit-status table (ADR-0223). Both are
/// tested against `protocol/test/fixtures/{porsche_client_results,
/// terminal_attach}.json`.
library;

import 'dart:convert';

import 'app_route.dart';

/// Why a terminal result could not be decoded.
final class TerminalFormatException implements Exception {
  const TerminalFormatException(this.field);
  final String field;
  @override
  String toString() => 'TerminalFormatException($field)';
}

/// Whether a session is being closed.
enum KillStatus { idle, closing }

/// One `terminal ls` row.
final class TerminalSession {
  const TerminalSession({
    required this.id,
    required this.columns,
    required this.rows,
    required this.viewers,
    required this.mine,
    required this.canKill,
    this.guestUser,
    this.createdAt,
    this.lastActiveAt,
    this.killStatus,
    this.route,
  });

  final String id;
  final int columns;
  final int rows;
  final int viewers;
  final bool mine;
  final bool canKill;

  /// The guest account the shell runs as; an identifier, shown LTR.
  final String? guestUser;
  final DateTime? createdAt;
  final DateTime? lastActiveAt;
  final KillStatus? killStatus;
  final MilaRoute? route;
}

int _bounded(Object? value, String field, int maximum) {
  if (value is! int || value < 0 || value > maximum) throw TerminalFormatException(field);
  return value;
}

DateTime? _millis(Object? value) => value is int && value >= 0 && value < 1 << 50
    ? DateTime.fromMillisecondsSinceEpoch(value, isUtc: true)
    : null;

String _uuid(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! String || !isCanonicalUuid(field)) throw TerminalFormatException(key);
  return field;
}

MilaRoute? _terminalRoute(Object? text, String machineId, String sessionId) {
  final route = text is String ? parseMilaRoute(text) : null;
  final page = route?.page;
  return page is MachineTerminalPage && page.machineId == machineId && page.sessionId == sessionId
      ? route
      : null;
}

/// A `terminal ls` result.
final class TerminalListing {
  const TerminalListing(this.machineId, this.items);
  final String machineId;
  final List<TerminalSession> items;
}

/// Decodes `terminal ls --json`. Rows failing strict fields are skipped.
(TerminalListing, int skipped) decodeTerminalList(Map<String, Object?> result) {
  final machineId = _uuid(result, 'machine_id');
  final items = result['items'];
  if (items is! List<Object?>) throw const TerminalFormatException('items');
  final sessions = <TerminalSession>[];
  var skipped = 0;
  for (final item in items) {
    try {
      if (item is! Map<String, Object?>) throw const TerminalFormatException('item');
      final id = _uuid(item, 'id');
      final user = item['guest_user'];
      sessions.add(
        TerminalSession(
          id: id,
          columns: _bounded(item['cols'], 'cols', 4096),
          rows: _bounded(item['rows'], 'rows', 512),
          viewers: _bounded(item['viewers'], 'viewers', 1 << 20),
          mine: item['mine'] == true,
          canKill: item['can_kill'] == true,
          guestUser: user is String && user.length <= 64 ? user : null,
          createdAt: _millis(item['created_ms']),
          lastActiveAt: _millis(item['last_ms']),
          killStatus: switch (item['kill_status']) {
            'idle' => KillStatus.idle,
            'closing' => KillStatus.closing,
            _ => null,
          },
          route: _terminalRoute(item['route'], machineId, id),
        ),
      );
    } on TerminalFormatException {
      skipped++;
    }
  }
  return (TerminalListing(machineId, List.unmodifiable(sessions)), skipped);
}

/// The result of `terminal new`: the personal session to attach to.
final class OpenedTerminal {
  const OpenedTerminal(this.machineId, this.sessionId);
  final String machineId;
  final String sessionId;
}

OpenedTerminal decodeTerminalNew(Map<String, Object?> result) =>
    OpenedTerminal(_uuid(result, 'machine_id'), _uuid(result, 'session_id'));

/// The result of `terminal kill`.
bool decodeTerminalKill(Map<String, Object?> result, String sessionId) =>
    _uuid(result, 'session_id') == sessionId && result['closed'] == true;

/// The closed refusal names an attach header may carry.
enum AttachError {
  invalidCommand('invalid_command'),
  attachRequiresPty('attach_requires_pty'),
  approvalRequired('approval_required'),
  unauthorized('unauthorized'),
  authorityCredential('authority_credential'),
  forbidden('forbidden'),
  notFound('not_found'),
  terminalUnavailable('terminal_unavailable'),
  conflict('conflict'),
  temporarilyUnavailable('temporarily_unavailable'),
  transportError('transport_error');

  const AttachError(this.wire);
  final String wire;

  static AttachError? fromWire(Object? value) {
    for (final error in values) {
      if (error.wire == value) return error;
    }
    return null;
  }

  /// The outcome this refusal denotes, as `TerminalAttach.error_outcome/1`.
  AttachOutcome get outcome => switch (this) {
    invalidCommand || attachRequiresPty => AttachOutcome.invalid,
    approvalRequired || unauthorized || authorityCredential => AttachOutcome.authority,
    forbidden || notFound || terminalUnavailable || conflict => AttachOutcome.refused,
    temporarilyUnavailable || transportError => AttachOutcome.transport,
  };
}

/// How an attachment ended, from its exit status.
enum AttachOutcome {
  /// The session ended or the client detached.
  closed(0),

  /// Marshall refused the attachment.
  refused(1),

  /// The invocation was invalid, including a missing pty request.
  invalid(2),

  /// Account, key or session authority failed or was revoked.
  authority(3),

  /// Transport or service failure; retrying may succeed.
  transport(5);

  const AttachOutcome(this.status);
  final int status;

  /// The outcome for an exit status. A status outside the closed table, or
  /// none at all (a dropped connection), is a transport failure.
  static AttachOutcome fromStatus(int? status) {
    for (final outcome in values) {
      if (outcome.status == status) return outcome;
    }
    return transport;
  }

  /// Whether reattaching from the cursor may succeed.
  bool get retryable => this == transport;
}

/// Whether the attachment may write.
enum AttachMode { readWrite, readOnly }

/// The single stderr header line.
sealed class AttachHeader {
  const AttachHeader();
}

/// Attached: output replays from byte offset [from]; [replayBytes] of it
/// precede live output.
final class AttachedHeader extends AttachHeader {
  const AttachedHeader({required this.from, required this.replayBytes, required this.mode});
  final int from;
  final int replayBytes;
  final AttachMode mode;
}

/// Refused with a closed reason.
final class RefusedHeader extends AttachHeader {
  const RefusedHeader(this.error);
  final AttachError error;
}

/// The longest header line Porsche writes.
const int maximumHeaderBytes = 512;

// @cc [owner:ghuntley,label:protocol;security] mila-attach-header-closed
// Mila MUST accept only the closed attach header: exactly the attached
// object (version, attached, from, replay_bytes, mode) or a refusal naming a
// known error. Anything else, including an extra key, is invalid.
/// Decodes one header line, or returns null when it is outside the schema.
AttachHeader? decodeAttachHeader(String line) {
  if (utf8.encode(line).length > maximumHeaderBytes) return null;
  final trimmed = line.endsWith('\n') ? line.substring(0, line.length - 1) : line;
  final Object? value;
  try {
    value = jsonDecode(trimmed);
  } on FormatException {
    return null;
  }
  if (value is! Map<String, Object?> || value['version'] != 1) return null;
  switch (value['attached']) {
    case true when value.length == 5:
      final from = value['from'];
      final replay = value['replay_bytes'];
      final mode = switch (value['mode']) {
        'rw' => AttachMode.readWrite,
        'ro' => AttachMode.readOnly,
        _ => null,
      };
      if (from is! int || from < 0 || replay is! int || replay < 0 || mode == null) return null;
      return AttachedHeader(from: from, replayBytes: replay, mode: mode);
    case false when value.length == 3:
      final error = AttachError.fromWire(value['error']);
      return error == null ? null : RefusedHeader(error);
  }
  return null;
}
