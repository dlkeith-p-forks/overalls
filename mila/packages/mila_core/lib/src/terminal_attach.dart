/// The terminal attach state machine (ADR-0223): one shared terminal session
/// viewed over successive `terminal attach` PTY channels, resuming from a
/// byte cursor after transport failures.
///
/// The state holds only positions, counters and closed values. Output bytes
/// pass through the caller straight to the terminal emulator; events carry
/// their length, never the bytes (`mila-terminal-bytes-never-at-rest`).
///
/// **Cursor rule.** The cursor is the byte offset of the next output byte.
/// It only grows, by the length of each output chunk, except at one point:
/// when an attached header names a `from` different from the cursor Mila
/// asked to resume at. Porsche's replay buffer may have dropped the bytes
/// Mila missed (`from` ahead) or the session may have restarted (`from`
/// behind); either way the cursor jumps to `from`, [TerminalAttach.jumps]
/// counts the jump and the screen must be reset before replayed output is
/// drawn, so nothing is drawn twice or spliced across a gap.
library;

import 'ssh_command.dart';
import 'terminal.dart';

/// Where an attachment stands.
enum AttachPhase {
  /// Not attached yet.
  idle,

  /// An attach channel is opening; waiting for its header.
  attaching,

  /// Attached; output is flowing.
  attached,

  /// The channel failed in a way a reattach may fix; waiting to retry.
  waiting,

  /// Finished: closed, refused, invalid, an authority failure, or retries
  /// exhausted. Only an explicit user retry leaves this phase.
  ended,
}

/// Consecutive failed attaches before Mila stops retrying on its own.
const int maximumAttachAttempts = 8;

/// An input to the state machine.
sealed class AttachEvent {
  const AttachEvent();
}

/// Open a new attach channel (first attach, scheduled retry or user retry).
final class AttachRequested extends AttachEvent {
  const AttachRequested();
}

/// The channel for [generation] wrote its stderr header (null: invalid).
final class HeaderReceived extends AttachEvent {
  const HeaderReceived(this.generation, this.header);
  final int generation;
  final AttachHeader? header;
}

/// [length] output bytes arrived on [generation]'s channel.
final class OutputReceived extends AttachEvent {
  const OutputReceived(this.generation, this.length);
  final int generation;
  final int length;
}

/// [generation]'s channel closed with [outcome].
final class ChannelEnded extends AttachEvent {
  const ChannelEnded(this.generation, this.outcome);
  final int generation;
  final AttachOutcome outcome;
}

/// The caller drew the reset the last jump asked for.
final class ScreenReset extends AttachEvent {
  const ScreenReset();
}

/// The user switched read-only viewing on or off. Turning it on takes
/// effect at once; turning it off needs a new attachment.
final class ReadOnlyChanged extends AttachEvent {
  const ReadOnlyChanged(this.readOnly);
  final bool readOnly;
}

/// The user left the terminal.
final class Detached extends AttachEvent {
  const Detached();
}

/// An immutable snapshot of one terminal view.
final class TerminalAttach {
  const TerminalAttach._({
    required this.phase,
    required this.generation,
    required this.cursor,
    required this.cursorKnown,
    required this.readOnlyRequested,
    required this.attempts,
    required this.jumps,
    required this.resetPending,
    this.mode,
    this.outcome,
    this.error,
  });

  /// A view that has not attached yet.
  const TerminalAttach.initial({bool readOnly = false})
    : this._(
        phase: AttachPhase.idle,
        generation: 0,
        cursor: 0,
        cursorKnown: false,
        readOnlyRequested: readOnly,
        attempts: 0,
        jumps: 0,
        resetPending: false,
      );

  final AttachPhase phase;

  /// Which attach channel is current; events from older ones are ignored.
  final int generation;

  /// The byte offset of the next output byte.
  final int cursor;

  /// False until the first attached header: the first attach asks for the
  /// server's whole replay buffer rather than a cursor.
  final bool cursorKnown;
  final bool readOnlyRequested;

  /// Consecutive failed attaches since the last success.
  final int attempts;

  /// How many documented cursor jumps happened.
  final int jumps;

  /// The screen must be cleared before the next output is drawn.
  final bool resetPending;

  /// What the server granted, while attached.
  final AttachMode? mode;

  /// Why the view ended, in [AttachPhase.ended] or [AttachPhase.waiting].
  final AttachOutcome? outcome;

  /// The refusal reason a header named, if any.
  final AttachError? error;

  // @cc [owner:ghuntley,label:security] mila-read-only-never-sends
  // A read-only view MUST NOT send input or resize the shared session: only
  // an attached read-write view the user has not made read-only may.
  /// Whether user input may be sent now.
  bool get canSendInput =>
      phase == AttachPhase.attached && mode == AttachMode.readWrite && !readOnlyRequested;

  /// Whether a window change may resize the shared session now.
  bool get canResize => canSendInput;

  /// Whether output on [generation]'s channel belongs on screen.
  bool acceptsOutput(int generation) =>
      phase == AttachPhase.attached && generation == this.generation;

  /// Whether the view is read-only for the user, by choice or by grant.
  bool get readOnly => readOnlyRequested || mode == AttachMode.readOnly;

  /// The attach command for the next channel.
  PorscheCommand command(String machine, String session) => PorscheCommand(
    'terminal attach',
    arguments: [machine, session],
    options: {if (cursorKnown) 'cursor': '$cursor', if (readOnlyRequested) 'read-only': true},
  );

  /// The state's values, for checks that it holds no byte payloads.
  Map<String, Object?> describe() => {
    'phase': phase,
    'generation': generation,
    'cursor': cursor,
    'cursorKnown': cursorKnown,
    'readOnlyRequested': readOnlyRequested,
    'attempts': attempts,
    'jumps': jumps,
    'resetPending': resetPending,
    'mode': mode,
    'outcome': outcome,
    'error': error,
  };

  TerminalAttach _copy({
    AttachPhase? phase,
    int? generation,
    int? cursor,
    bool? cursorKnown,
    bool? readOnlyRequested,
    int? attempts,
    int? jumps,
    bool? resetPending,
    AttachMode? mode,
    bool clearMode = false,
    AttachOutcome? outcome,
    bool clearOutcome = false,
    AttachError? error,
    bool clearError = false,
  }) => TerminalAttach._(
    phase: phase ?? this.phase,
    generation: generation ?? this.generation,
    cursor: cursor ?? this.cursor,
    cursorKnown: cursorKnown ?? this.cursorKnown,
    readOnlyRequested: readOnlyRequested ?? this.readOnlyRequested,
    attempts: attempts ?? this.attempts,
    jumps: jumps ?? this.jumps,
    resetPending: resetPending ?? this.resetPending,
    mode: clearMode ? null : mode ?? this.mode,
    outcome: clearOutcome ? null : outcome ?? this.outcome,
    error: clearError ? null : error ?? this.error,
  );

  bool _current(int generation) =>
      generation == this.generation &&
      (phase == AttachPhase.attaching || phase == AttachPhase.attached);

  /// Applies [event]. Events for an older channel leave the state identical.
  TerminalAttach apply(AttachEvent event) {
    switch (event) {
      case AttachRequested():
        if (phase == AttachPhase.attaching || phase == AttachPhase.attached) return this;
        return _copy(
          phase: AttachPhase.attaching,
          generation: generation + 1,
          // A user retry after the view ended starts a fresh retry budget.
          attempts: phase == AttachPhase.ended ? 0 : attempts,
          clearMode: true,
          clearOutcome: true,
          clearError: true,
        );
      case HeaderReceived(:final generation, :final header) when _current(generation):
        if (phase != AttachPhase.attaching) return this;
        switch (header) {
          case AttachedHeader(:final from, :final mode):
            final jumped = cursorKnown && from != cursor;
            return _copy(
              phase: AttachPhase.attached,
              cursor: from,
              cursorKnown: true,
              attempts: 0,
              jumps: jumped ? jumps + 1 : jumps,
              resetPending: jumped || resetPending,
              mode: mode,
            );
          case RefusedHeader(:final error):
            return _fail(error.outcome, error);
          case null:
            return _fail(AttachOutcome.invalid, null);
        }
      case OutputReceived(:final generation, :final length) when _current(generation):
        // Bytes before the header have no position and are not shown.
        if (phase != AttachPhase.attached || length <= 0) return this;
        return _copy(cursor: cursor + length);
      case ChannelEnded(:final generation, :final outcome) when _current(generation):
        return _fail(outcome, error);
      case ScreenReset():
        return resetPending ? _copy(resetPending: false) : this;
      case ReadOnlyChanged(:final readOnly):
        return readOnly == readOnlyRequested ? this : _copy(readOnlyRequested: readOnly);
      case Detached():
        if (phase == AttachPhase.ended) return this;
        return _copy(phase: AttachPhase.ended, outcome: AttachOutcome.closed, clearMode: true);
      case HeaderReceived() || OutputReceived() || ChannelEnded():
        return this;
    }
  }

  TerminalAttach _fail(AttachOutcome outcome, AttachError? error) {
    final retry = outcome.retryable && attempts + 1 < maximumAttachAttempts;
    return _copy(
      phase: retry ? AttachPhase.waiting : AttachPhase.ended,
      attempts: attempts + 1,
      outcome: outcome,
      error: error,
      clearMode: true,
    );
  }
}
