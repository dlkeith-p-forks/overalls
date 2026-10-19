/// Tracking one mutation from submission to a terminal receipt.
///
/// Mirrors `porsche-wait-only-observes`: a mutation is submitted at most once
/// under a request id allocated before submission. Every uncertainty —
/// timeout, transport loss, an unreadable reply — is resolved by polling
/// `request show` with that same id, never by submitting again.
library;

import 'porsche_reply.dart';

/// Where a tracked request stands.
enum PollPhase {
  /// Submitted; no reply read yet.
  submitting,

  /// The outcome of submission is unknown; poll to learn whether it landed.
  uncertain,

  /// Admitted and still running.
  accepted,

  /// Terminal: succeeded.
  succeeded,

  /// Terminal: failed or superseded.
  failed,

  /// Terminal: the server refused the command or the request is unknown.
  refused,
}

/// Polls an uncertain request may answer `request_not_found` before Mila
/// concludes the submission never landed.
const int notFoundPolls = 5;

/// What the caller should do next.
sealed class PollAction {
  const PollAction();
}

/// Run `request show <requestId> --json` after [attempt]'s backoff.
final class PollAgain extends PollAction {
  const PollAgain(this.attempt);
  final int attempt;
}

/// Nothing more to send.
final class PollDone extends PollAction {
  const PollDone();
}

/// An immutable snapshot of one tracked request.
final class RequestPoll {
  const RequestPoll._({
    required this.requestId,
    required this.phase,
    required this.attempts,
    this.operationId,
    this.error,
    this.result = const {},
  });

  /// Starts tracking a request whose id was allocated before submission.
  factory RequestPoll.submitted(String requestId) =>
      RequestPoll._(requestId: requestId, phase: PollPhase.submitting, attempts: 0);

  final String requestId;
  final PollPhase phase;

  /// Polls issued so far.
  final int attempts;

  /// Fixed once the server names it; a different id is a protocol error.
  final String? operationId;

  /// The closed refusal reason when [phase] is [PollPhase.refused].
  final String? error;
  final Map<String, Object?> result;

  bool get terminal =>
      phase == PollPhase.succeeded || phase == PollPhase.failed || phase == PollPhase.refused;

  /// What to do in this state.
  PollAction get next => terminal ? const PollDone() : PollAgain(attempts);

  RequestPoll _copy({
    PollPhase? phase,
    int? attempts,
    String? operationId,
    String? error,
    Map<String, Object?>? result,
  }) => RequestPoll._(
    requestId: requestId,
    phase: phase ?? this.phase,
    attempts: attempts ?? this.attempts,
    operationId: operationId ?? this.operationId,
    error: error ?? this.error,
    result: result ?? this.result,
  );

  /// Records that a poll was sent.
  RequestPoll polled() => terminal ? this : _copy(attempts: attempts + 1);

  /// Applies the outcome of submission or of one poll. Terminal states absorb
  /// every later outcome, so a late or duplicated reply cannot reopen them.
  RequestPoll observe(ChannelOutcome outcome) {
    if (terminal) return this;
    final reply = outcome.reply;
    switch (reply) {
      case ReceiptReply(:final requestId) when requestId != this.requestId:
        return _uncertain();
      case ReceiptReply(:final operationId)
          when this.operationId != null && operationId != null && operationId != this.operationId:
        return _uncertain();
      case ReceiptReply(:final status, :final operationId, :final result):
        final phase = switch (status) {
          ReceiptStatus.accepted => PollPhase.accepted,
          ReceiptStatus.succeeded => PollPhase.succeeded,
          ReceiptStatus.failed || ReceiptStatus.superseded => PollPhase.failed,
        };
        return _copy(phase: phase, operationId: operationId, result: result);
      case ErrorReply(:final error)
          when outcome.exit == PorscheExit.invalid || outcome.exit == PorscheExit.authority:
        // Before admission is known, not_found may only mean "not yet visible";
        // after [notFoundPolls] polls the submission is taken not to have landed.
        if (error == 'request_not_found' &&
            phase == PollPhase.uncertain &&
            attempts < notFoundPolls) {
          return _uncertain();
        }
        return _copy(phase: PollPhase.refused, error: error);
      case ErrorReply() || ApprovalReply() || ReadReply() || null:
        return _uncertain();
    }
  }

  RequestPoll _uncertain() =>
      phase == PollPhase.accepted ? this : _copy(phase: PollPhase.uncertain);
}
