// One agent thread: its transcript, what it is waiting for, the composer,
// answers to agent questions, plan approval and revision, and the server
// read marker. Prompt, answer and revision text go on stdin only.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../mutation.dart';
import '../session.dart';
import 'threads_controller.dart';

/// Why the last thread action did not go through.
enum ThreadActionFailure { refused, failed, invalidText, tooLarge, busy }

final class ThreadView {
  const ThreadView({
    this.detail,
    this.turns = const [],
    this.loading = false,
    this.failed = false,
    this.sending = false,
    this.failure,
  });

  final ThreadDetail? detail;
  final List<TurnEvent> turns;
  final bool loading;
  final bool failed;

  /// A prompt, answer, plan decision or mode change is in flight.
  final bool sending;
  final ThreadActionFailure? failure;

  ThreadView copyWith({
    ThreadDetail? detail,
    List<TurnEvent>? turns,
    bool? loading,
    bool? failed,
    bool? sending,
    ThreadActionFailure? failure,
    bool clearFailure = false,
  }) => ThreadView(
    detail: detail ?? this.detail,
    turns: turns ?? this.turns,
    loading: loading ?? this.loading,
    failed: failed ?? this.failed,
    sending: sending ?? this.sending,
    failure: clearFailure ? null : failure ?? this.failure,
  );
}

typedef ThreadKey = (Deployment, String thread);

/// Transcript pages Mila reads in one refresh.
const int maximumTurnPages = 20;

final threadProvider = NotifierProvider.autoDispose.family<ThreadController, ThreadView, ThreadKey>(
  ThreadController.new,
);

final class ThreadController extends Notifier<ThreadView> {
  ThreadController(this.key);

  final ThreadKey key;
  WatchFeed? _feed;
  bool _refreshing = false;
  bool _again = false;

  String get _thread => key.$2;

  @override
  ThreadView build() {
    ref.onDispose(() => unawaited(_feed?.close()));
    final session = ref.watch(sessionProvider(key.$1));
    if (session != null) {
      Future.microtask(refresh);
      final feed = WatchFeed(
        open: session.watch,
        filter: WatchFilter(threads: [_thread]),
        random: ref.read(randomProvider),
      );
      feed.events.listen((event) {
        if (event is ThreadChanged || event is Resync) unawaited(refresh());
      });
      feed.start();
      _feed = feed;
    }
    return const ThreadView(loading: true);
  }

  PorscheSession? get _session => ref.read(sessionProvider(key.$1));

  /// Re-reads the thread and appends transcript after the last event shown.
  /// Overlapping calls coalesce into one more pass.
  Future<void> refresh() async {
    if (_refreshing) {
      _again = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _again = false;
        await _refreshOnce();
      } while (_again && ref.mounted);
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _refreshOnce() async {
    final session = _session;
    if (session == null || !ref.mounted) return;
    final shown = await readResult(
      session,
      PorscheCommand('thread show', arguments: [_thread], options: const {'json': true}),
    );
    if (!ref.mounted) return;
    ThreadDetail? detail;
    try {
      detail = shown == null ? null : decodeThreadDetail(shown);
    } on ThreadFormatException {
      detail = null;
    }
    if (detail == null || detail.summary.id != _thread) {
      state = state.copyWith(loading: false, failed: true);
      return;
    }
    var turns = state.turns;
    for (var page = 0; page < maximumTurnPages; page++) {
      final after = turns.isEmpty ? 0 : turns.last.sequence;
      final result = await readResult(
        session,
        PorscheCommand(
          'thread turns',
          arguments: [_thread],
          options: {'json': true, 'after': '$after'},
        ),
      );
      if (result == null || !ref.mounted) break;
      final TurnPage decoded;
      try {
        decoded = decodeTurnPage(result, threadId: _thread, after: after);
      } on ThreadFormatException {
        break;
      }
      turns = appendTurns(turns, decoded);
      if (decoded.nextAfter == null) break;
    }
    if (!ref.mounted) return;
    state = state.copyWith(detail: detail, turns: turns, loading: false, failed: false);
    await _markRead(session, detail, turns);
  }

  /// Moves the server read marker to the last event shown, never back.
  Future<void> _markRead(PorscheSession session, ThreadDetail detail, List<TurnEvent> turns) async {
    if (turns.isEmpty) return;
    final sequence = readMarkerToSend(detail.summary.unread, turns.last.sequence);
    if (sequence == null) return;
    final poll = await submitOnce(
      session,
      withRequestId(
        PorscheCommand('thread read', arguments: [_thread, '$sequence']),
        ref.read(randomProvider),
      ),
      random: ref.read(randomProvider),
    );
    if (!ref.mounted || poll.phase != PollPhase.succeeded) return;
    final unread = detail.summary.unread.markRead(sequence);
    // Lists already open show the new count at once rather than at their next
    // watch event; lists not open are not created for this.
    final d = key.$1;
    for (final list in <ThreadsKey>{(d, null), (d, detail.summary.machineId)}) {
      if (ref.exists(threadsProvider(list))) {
        ref.read(threadsProvider(list).notifier).markedRead(_thread, unread);
      }
    }
    final current = state.detail;
    if (current == null) return;
    state = state.copyWith(
      detail: ThreadDetail(
        summary: current.summary.withUnread(current.summary.unread.merge(unread)),
        busy: current.busy,
        pendingQuestion: current.pendingQuestion,
        latestPlan: current.latestPlan,
      ),
    );
  }

  Future<bool> _submit(PorscheCommand command, {String? text}) async {
    final session = _session;
    if (session == null) return false;
    final random = ref.read(randomProvider);
    final PorscheCommand withId;
    List<int>? stdin;
    try {
      withId = withRequestId(command, random);
      if (text != null) {
        final built = payloadCommand(withId, text);
        stdin = built.stdin;
      }
    } on PayloadRefused catch (e) {
      state = state.copyWith(
        failure: e.reason == PayloadRefusal.tooLarge
            ? ThreadActionFailure.tooLarge
            : ThreadActionFailure.invalidText,
      );
      return false;
    } on CommandRefused {
      state = state.copyWith(failure: ThreadActionFailure.invalidText);
      return false;
    }
    state = state.copyWith(sending: true, clearFailure: true);
    final poll = await submitOnce(session, withId, random: random, stdin: stdin);
    if (!ref.mounted) return false;
    final failure = switch (poll.phase) {
      PollPhase.succeeded => null,
      PollPhase.refused when poll.error == 'thread_busy' => ThreadActionFailure.busy,
      PollPhase.refused => ThreadActionFailure.refused,
      _ => ThreadActionFailure.failed,
    };
    state = state.copyWith(sending: false, failure: failure);
    unawaited(refresh());
    return failure == null;
  }

  /// Sends a prompt; true once Marshall accepted it.
  Future<bool> prompt(String text) =>
      _submit(PorscheCommand('thread prompt', arguments: [_thread, '-']), text: text);

  /// Switches plan/work collaboration.
  Future<bool> setMode(CollaborationMode mode) =>
      _submit(PorscheCommand('thread mode', arguments: [_thread, mode.name]));

  /// Answers the pending question; false when the answers are incomplete.
  Future<bool> answer(Map<String, QuestionAnswer> answers) async {
    final pending = state.detail?.pendingQuestion;
    if (pending == null) return false;
    final body = encodeAnswers(pending, answers);
    if (body == null) {
      state = state.copyWith(failure: ThreadActionFailure.invalidText);
      return false;
    }
    return _submit(
      PorscheCommand('thread answer', arguments: [_thread, pending.id, '-']),
      text: body,
    );
  }

  /// Approves the latest plan, starting implementation in work mode.
  Future<bool> approvePlan() async {
    final plan = state.detail?.latestPlan;
    if (plan == null || plan.implemented) return false;
    return _submit(PorscheCommand('thread plan approve', arguments: [_thread, plan.id]));
  }

  /// Asks for a revised plan with [feedback].
  Future<bool> revisePlan(String feedback) async {
    final plan = state.detail?.latestPlan;
    if (plan == null || plan.implemented) return false;
    return _submit(
      PorscheCommand('thread plan revise', arguments: [_thread, plan.id, '-']),
      text: feedback,
    );
  }
}
