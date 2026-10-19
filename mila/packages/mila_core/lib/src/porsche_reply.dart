/// Decoding of Porsche `--json` replies and exit statuses.
///
/// Envelopes are decoded strictly: an unknown status or a missing field is a
/// protocol error. `result` objects are decoded tolerantly by each feature,
/// because store clients lag servers (ADR-0220).
library;

import 'dart:convert';

import 'app_route.dart' show isCanonicalUuid;

/// What a Porsche channel's exit status means.
enum PorscheExit {
  /// The command succeeded or was accepted.
  ok(0),

  /// A receipt reported failed or superseded.
  failed(1),

  /// Invalid command, not found or conflict: retrying unchanged will not help.
  invalid(2),

  /// Not authorized, forbidden or approval pending.
  authority(3),

  /// A physical wait reached its deadline; the request is still admitted.
  timedOut(4),

  /// Transport or service unavailable; safe to poll the receipt again.
  unavailable(5),

  /// The channel was interrupted by a signal or Ctrl-C.
  interrupted(130);

  const PorscheExit(this.code);

  final int code;

  /// Maps an exit status, or null for a status Porsche never sends.
  static PorscheExit? fromCode(int code) {
    for (final exit in values) {
      if (exit.code == code) return exit;
    }
    return null;
  }
}

/// Receipt statuses for mutations.
enum ReceiptStatus { accepted, succeeded, failed, superseded }

/// One decoded Porsche reply.
sealed class PorscheReply {
  const PorscheReply();
}

/// A read-only command succeeded.
final class ReadReply extends PorscheReply {
  const ReadReply(this.result);
  final Map<String, Object?> result;
}

/// A mutation's receipt, possibly after waiting.
final class ReceiptReply extends PorscheReply {
  const ReceiptReply({
    required this.requestId,
    required this.status,
    required this.operationId,
    required this.result,
    this.waitTimedOut = false,
  });

  final String requestId;
  final ReceiptStatus status;

  /// Null only for durable mutations that have no physical operation.
  final String? operationId;
  final Map<String, Object?> result;

  /// Porsche stopped waiting; poll `request show` to learn the outcome.
  final bool waitTimedOut;

  /// Whether the request reached a terminal state.
  bool get terminal => status != ReceiptStatus.accepted;
}

/// The key is not yet approved. [approvalUrl] stays valid while the
/// connection that produced it remains open.
final class ApprovalReply extends PorscheReply {
  const ApprovalReply({required this.fingerprint, required this.approvalUrl});
  final String fingerprint;
  final Uri approvalUrl;
}

/// A closed refusal. [error] is a server reason identifier, never user text;
/// [hint] is fixed server copy.
final class ErrorReply extends PorscheReply {
  const ErrorReply({required this.error, this.requestId, this.hint});
  final String error;
  final String? requestId;
  final String? hint;
}

/// Why a reply could not be decoded.
final class ReplyFormatException implements Exception {
  const ReplyFormatException(this.message);
  final String message;
  @override
  String toString() => 'ReplyFormatException($message)';
}

final RegExp _reason = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
final RegExp _fingerprint = RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$');

/// Decodes one newline-terminated JSON reply line.
PorscheReply decodeReplyLine(String line) {
  final trimmed = line.endsWith('\n') ? line.substring(0, line.length - 1) : line;
  if (trimmed.contains('\n')) throw const ReplyFormatException('multiple lines');
  final Object? value;
  try {
    value = jsonDecode(trimmed);
  } on FormatException {
    throw const ReplyFormatException('not json');
  }
  return decodeReply(value);
}

/// Decodes a parsed reply envelope.
PorscheReply decodeReply(Object? value) {
  if (value is! Map<String, Object?>) throw const ReplyFormatException('not an object');
  if (value['version'] != 1) throw const ReplyFormatException('version');
  final status = value['status'];
  switch (status) {
    case 'error':
      _only(value, const {'version', 'status', 'error'}, const {'request_id', 'hint'});
      final error = value['error'];
      if (error is! String || !_reason.hasMatch(error)) {
        throw const ReplyFormatException('error');
      }
      return ErrorReply(
        error: error,
        requestId: _optionalString(value, 'request_id'),
        hint: _optionalString(value, 'hint'),
      );
    case 'approval_required':
      _only(value, const {'version', 'status', 'fingerprint', 'approval_url'}, const {'message'});
      final fingerprint = value['fingerprint'];
      final url = value['approval_url'];
      if (fingerprint is! String || !_fingerprint.hasMatch(fingerprint)) {
        throw const ReplyFormatException('fingerprint');
      }
      final uri = url is String ? Uri.tryParse(url) : null;
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
        throw const ReplyFormatException('approval_url');
      }
      return ApprovalReply(fingerprint: fingerprint, approvalUrl: uri);
    case 'succeeded' when !value.containsKey('request_id'):
      _only(value, const {'version', 'status', 'result'}, const {});
      return ReadReply(_result(value));
    case 'accepted' || 'succeeded' || 'failed' || 'superseded':
      _only(
        value,
        const {'version', 'status', 'request_id', 'operation_id', 'result'},
        const {'wait_status'},
      );
      final requestId = value['request_id'];
      if (requestId is! String || requestId.isEmpty) {
        throw const ReplyFormatException('request_id');
      }
      final operation = value['operation_id'];
      final receiptStatus = ReceiptStatus.values.byName(status! as String);
      if (operation == null) {
        if (receiptStatus != ReceiptStatus.succeeded) {
          throw const ReplyFormatException('operation_id');
        }
      } else if (operation is! String || !isCanonicalUuid(operation)) {
        throw const ReplyFormatException('operation_id');
      }
      final wait = value['wait_status'];
      if (wait != null && wait != 'timed_out') throw const ReplyFormatException('wait_status');
      return ReceiptReply(
        requestId: requestId,
        status: receiptStatus,
        operationId: operation as String?,
        result: _result(value),
        waitTimedOut: wait == 'timed_out',
      );
  }
  throw const ReplyFormatException('status');
}

void _only(Map<String, Object?> value, Set<String> required, Set<String> optional) {
  for (final key in required) {
    if (!value.containsKey(key)) throw ReplyFormatException('missing $key');
  }
  for (final key in value.keys) {
    if (!required.contains(key) && !optional.contains(key)) {
      throw ReplyFormatException('unexpected $key');
    }
  }
}

String? _optionalString(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field == null) return null;
  if (field is! String) throw ReplyFormatException(key);
  return field;
}

Map<String, Object?> _result(Map<String, Object?> value) {
  final result = value['result'];
  if (result is! Map<String, Object?>) throw const ReplyFormatException('result');
  return result;
}

/// The outcome of one exec channel: its exit and the decoded reply, if any.
final class ChannelOutcome {
  const ChannelOutcome(this.exit, this.reply);
  final PorscheExit exit;
  final PorscheReply? reply;

  /// Whether the same request may be polled again with `request show`.
  /// Never true for a resubmission: Porsche never repeats mutations.
  bool get pollable =>
      exit == PorscheExit.timedOut ||
      exit == PorscheExit.unavailable ||
      (reply is ReceiptReply && !(reply! as ReceiptReply).terminal);
}
