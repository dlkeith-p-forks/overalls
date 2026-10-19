/// Agent threads as `thread ls|show|turns --json` report them, the results
/// of thread mutations, answers to agent questions, and the unread, ordering
/// and search helpers the thread screens present (ADR-0222).
///
/// Identity fields are decoded strictly; descriptive fields are optional so
/// newer servers stay readable (ADR-0220 tolerant results).
library;

import 'dart:convert';

import 'app_route.dart';
import 'ssh_command.dart';

/// `Marshall.Threads.Thread.status`; null when the server sent a newer one.
enum ThreadStatus { pending, provisioning, ready, failed, deleting, archived }

/// Plan or work collaboration.
enum CollaborationMode { plan, work }

/// Why a thread result could not be decoded.
final class ThreadFormatException implements Exception {
  const ThreadFormatException(this.field);
  final String field;
  @override
  String toString() => 'ThreadFormatException($field)';
}

T? _enum<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

String _uuid(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! String || !isCanonicalUuid(field)) throw ThreadFormatException(key);
  return field;
}

String? _optionalUuid(Map<String, Object?> value, String key) {
  final field = value[key];
  return field is String && isCanonicalUuid(field) ? field : null;
}

int _count(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! int || field < 0) throw ThreadFormatException(key);
  return field;
}

DateTime? _time(Object? value) =>
    value is String && value.length <= 40 ? DateTime.tryParse(value)?.toUtc() : null;

String? _string(Object? value, {int maximum = 65536}) =>
    value is String && value.length <= maximum ? value : null;

/// Unread position for one reader: the server's ReadMarker and the latest
/// transcript sequence.
final class UnreadState {
  const UnreadState({required this.readSequence, required this.lastSequence});

  /// The highest sequence this reader has marked read.
  final int readSequence;

  /// The highest sequence in the transcript.
  final int lastSequence;

  /// Events after the marker; never negative.
  int get unread => lastSequence > readSequence ? lastSequence - readSequence : 0;

  bool get hasUnread => unread > 0;

  /// The marker after reading up to [sequence]. Markers never move back, as
  /// `Marshall.Threads.ReadMarker` never does.
  UnreadState markRead(int sequence) => UnreadState(
    readSequence: sequence > readSequence ? sequence : readSequence,
    lastSequence: sequence > lastSequence ? sequence : lastSequence,
  );

  /// Merges a newer server observation: both positions only move forward.
  UnreadState merge(UnreadState other) => UnreadState(
    readSequence: other.readSequence > readSequence ? other.readSequence : readSequence,
    lastSequence: other.lastSequence > lastSequence ? other.lastSequence : lastSequence,
  );

  @override
  bool operator ==(Object other) =>
      other is UnreadState &&
      other.readSequence == readSequence &&
      other.lastSequence == lastSequence;

  @override
  int get hashCode => Object.hash(readSequence, lastSequence);
}

/// Whether Mila should send `thread read T SEQ` after showing transcript up
/// to [shown]: only when it moves the server marker forward.
int? readMarkerToSend(UnreadState state, int shown) =>
    shown > state.readSequence && shown >= 0 ? shown : null;

/// One `thread ls` row, also the common part of `thread show`.
final class ThreadSummary {
  const ThreadSummary({
    required this.id,
    required this.title,
    required this.status,
    required this.mode,
    required this.unread,
    this.machineId,
    this.teamId,
    this.mine = false,
    this.archived = false,
    this.failureReason,
    this.insertedAt,
    this.updatedAt,
    this.route,
  });

  final String id;

  /// Free text from the server; empty while a title is being generated.
  final String title;

  /// Null when the server sent a status this client does not know.
  final ThreadStatus? status;
  final CollaborationMode? mode;
  final UnreadState unread;
  final String? machineId;
  final String? teamId;
  final bool mine;
  final bool archived;
  final String? failureReason;
  final DateTime? insertedAt;
  final DateTime? updatedAt;
  final MilaRoute? route;

  ThreadSummary withUnread(UnreadState next) => ThreadSummary(
    id: id,
    title: title,
    status: status,
    mode: mode,
    unread: next,
    machineId: machineId,
    teamId: teamId,
    mine: mine,
    archived: archived,
    failureReason: failureReason,
    insertedAt: insertedAt,
    updatedAt: updatedAt,
    route: route,
  );
}

ThreadSummary _summary(Map<String, Object?> value) {
  final id = _uuid(value, 'id');
  final routeText = value['route'];
  final route = routeText is String ? parseMilaRoute(routeText) : null;
  final page = route?.page;
  // A route naming another thread is ignored rather than followed.
  final safeRoute =
      (page is ThreadPage && page.threadId == id) ||
          (page is MachineThreadPage && page.threadId == id)
      ? route
      : null;
  final read = _count(value, 'read_sequence');
  final last = _count(value, 'last_sequence');
  return ThreadSummary(
    id: id,
    title: _string(value['title'], maximum: 1024) ?? '',
    status: _enum(ThreadStatus.values, value['status']),
    mode: _enum(CollaborationMode.values, value['collaboration_mode']),
    unread: UnreadState(readSequence: read, lastSequence: last),
    machineId: _optionalUuid(value, 'machine_id'),
    teamId: _optionalUuid(value, 'team_id'),
    mine: value['mine'] == true,
    archived: value['archived'] == true,
    failureReason: _string(value['failure_reason'], maximum: 64),
    insertedAt: _time(value['inserted_at']),
    updatedAt: _time(value['updated_at']),
    route: safeRoute,
  );
}

/// One `thread ls` page.
final class ThreadListing {
  const ThreadListing(this.items, this.nextCursor);
  final List<ThreadSummary> items;
  final String? nextCursor;
}

/// Decodes a `thread ls --json` result. Rows failing strict fields are
/// skipped and counted, never shown half-decoded.
(ThreadListing, int skipped) decodeThreadList(Map<String, Object?> result) {
  final items = result['items'];
  if (items is! List<Object?>) throw const ThreadFormatException('items');
  final threads = <ThreadSummary>[];
  var skipped = 0;
  for (final item in items) {
    try {
      if (item is! Map<String, Object?>) throw const ThreadFormatException('item');
      threads.add(_summary(item));
    } on ThreadFormatException {
      skipped++;
    }
  }
  final next = result['next_cursor'];
  return (
    ThreadListing(
      List.unmodifiable(threads),
      next is String && isCanonicalUuid(next) ? next : null,
    ),
    skipped,
  );
}

/// One option an agent offers for a question.
final class QuestionOption {
  const QuestionOption(this.label, this.description);
  final String label;
  final String description;
}

/// One question in a pending request.
final class AgentQuestion {
  const AgentQuestion({
    required this.id,
    required this.header,
    required this.question,
    required this.options,
  });

  /// The agent's key for this question; answers are keyed by it.
  final String id;
  final String header;
  final String question;
  final List<QuestionOption> options;
}

/// A pending request for input: one to three questions.
final class PendingQuestion {
  const PendingQuestion(this.id, this.questions);
  final String id;
  final List<AgentQuestion> questions;
}

/// The latest proposed plan.
final class PlanProposal {
  const PlanProposal({
    required this.id,
    required this.text,
    required this.implemented,
    this.eventSequence,
  });
  final String id;
  final String text;
  final bool implemented;
  final int? eventSequence;
}

/// `thread show`: a summary plus what the thread is waiting for.
final class ThreadDetail {
  const ThreadDetail({
    required this.summary,
    required this.busy,
    this.pendingQuestion,
    this.latestPlan,
  });
  final ThreadSummary summary;

  /// A turn is running; a new prompt would be refused.
  final bool busy;
  final PendingQuestion? pendingQuestion;
  final PlanProposal? latestPlan;
}

AgentQuestion? _question(Object? value) {
  if (value is! Map<String, Object?>) return null;
  final id = _string(value['id'], maximum: 128);
  final question = _string(value['question'], maximum: 4096);
  final options = value['options'];
  if (id == null || id.isEmpty || question == null || options is! List<Object?>) return null;
  final decoded = <QuestionOption>[];
  for (final option in options) {
    if (option is! Map<String, Object?>) return null;
    final label = _string(option['label'], maximum: 256);
    if (label == null || label.isEmpty) return null;
    decoded.add(QuestionOption(label, _string(option['description'], maximum: 1024) ?? ''));
  }
  return AgentQuestion(
    id: id,
    header: _string(value['header'], maximum: 64) ?? '',
    question: question,
    options: List.unmodifiable(decoded),
  );
}

PendingQuestion? _pending(Object? value) {
  if (value is! Map<String, Object?>) return null;
  final id = _optionalUuid(value, 'id');
  final questions = value['questions'];
  if (id == null || questions is! List<Object?> || questions.isEmpty) return null;
  final decoded = <AgentQuestion>[];
  for (final q in questions) {
    final question = _question(q);
    // A question this client cannot render is not answered half-way.
    if (question == null) return null;
    decoded.add(question);
  }
  return PendingQuestion(id, List.unmodifiable(decoded));
}

PlanProposal? _plan(Object? value) {
  if (value is! Map<String, Object?>) return null;
  final id = _optionalUuid(value, 'id');
  final text = _string(value['text']);
  if (id == null || text == null) return null;
  final sequence = value['event_sequence'];
  return PlanProposal(
    id: id,
    text: text,
    implemented: value['implemented'] == true,
    eventSequence: sequence is int && sequence >= 0 ? sequence : null,
  );
}

/// Decodes a `thread show --json` result.
ThreadDetail decodeThreadDetail(Map<String, Object?> result) => ThreadDetail(
  summary: _summary(result),
  busy: result['busy'] == true,
  pendingQuestion: _pending(result['pending_question']),
  latestPlan: _plan(result['latest_plan']),
);

/// `Marshall.Agents.Event.kind`; null when the server sent a newer kind.
enum TurnEventKind {
  prompt,
  turnStarted('turn_started'),
  assistant,
  modelOutput('model_output'),
  toolQueued('tool_queued'),
  toolResult('tool_result'),
  childSpawned('child_spawned'),
  turnFinished('turn_finished'),
  turnFailed('turn_failed'),
  waitingForVm('waiting_for_vm'),
  questionsRequested('questions_requested'),
  questionsAnswered('questions_answered'),
  questionsCancelled('questions_cancelled'),
  planProposed('plan_proposed'),
  contextCaptured('context_captured'),
  contextCompacted('context_compacted'),
  maintenanceFinished('maintenance_finished');

  const TurnEventKind([this._wire]);
  final String? _wire;

  String get wire => _wire ?? name;

  static TurnEventKind? fromWire(Object? value) {
    for (final kind in values) {
      if (kind.wire == value) return kind;
    }
    return null;
  }
}

/// One transcript event. Only prompt and assistant text is kept; every
/// other body is reduced to its kind.
final class TurnEvent {
  const TurnEvent({required this.sequence, required this.kind, this.turnId, this.text, this.at});
  final int sequence;
  final TurnEventKind? kind;
  final String? turnId;

  /// The prompt or assistant message text, when the event carries one.
  final String? text;
  final DateTime? at;
}

/// One `thread turns` page.
final class TurnPage {
  const TurnPage(this.threadId, this.items, this.nextAfter);
  final String threadId;

  /// Strictly increasing by sequence.
  final List<TurnEvent> items;

  /// Ask again with `--after` this sequence; null when the page was the end.
  final int? nextAfter;
}

/// Decodes a `thread turns --json` result. Events must be strictly
/// increasing and after [after]; an out-of-order page is refused whole.
TurnPage decodeTurnPage(Map<String, Object?> result, {required String threadId, int after = 0}) {
  if (_uuid(result, 'thread_id') != threadId) throw const ThreadFormatException('thread_id');
  final items = result['items'];
  if (items is! List<Object?>) throw const ThreadFormatException('items');
  final events = <TurnEvent>[];
  var previous = after;
  for (final item in items) {
    if (item is! Map<String, Object?>) throw const ThreadFormatException('item');
    final sequence = item['sequence'];
    if (sequence is! int || sequence <= previous) throw const ThreadFormatException('sequence');
    previous = sequence;
    final kind = TurnEventKind.fromWire(item['kind']);
    final body = item['body'];
    final text = body is Map<String, Object?>
        ? switch (kind) {
            TurnEventKind.prompt => _string(body['prompt']),
            TurnEventKind.assistant => _string(body['text']),
            _ => null,
          }
        : null;
    events.add(
      TurnEvent(
        sequence: sequence,
        kind: kind,
        turnId: _optionalUuid(item, 'turn_id'),
        text: text,
        at: _time(item['inserted_at']),
      ),
    );
  }
  final next = result['next_after'];
  return TurnPage(
    threadId,
    List.unmodifiable(events),
    next is int && next > after && events.isNotEmpty ? next : null,
  );
}

/// Appends [page] to [shown], keeping sequences strictly increasing and
/// dropping any event already present (a watch can race a page read).
List<TurnEvent> appendTurns(List<TurnEvent> shown, TurnPage page) {
  final last = shown.isEmpty ? 0 : shown.last.sequence;
  return List.unmodifiable([...shown, ...page.items.where((e) => e.sequence > last)]);
}

/// The result of a thread mutation that Mila reads back.
final class ThreadMutationResult {
  const ThreadMutationResult({
    required this.threadId,
    this.turnId,
    this.planId,
    this.questionId,
    this.mode,
    this.busy,
    this.unread,
  });
  final String threadId;
  final String? turnId;
  final String? planId;
  final String? questionId;
  final CollaborationMode? mode;
  final bool? busy;
  final UnreadState? unread;
}

/// Decodes the result of `thread prompt|answer|plan approve|plan revise|
/// mode|read`; only `thread_id` is required.
ThreadMutationResult decodeThreadMutation(Map<String, Object?> result) {
  final read = result['read_sequence'];
  final last = result['last_sequence'];
  final busy = result['busy'];
  return ThreadMutationResult(
    threadId: _uuid(result, 'thread_id'),
    turnId: _optionalUuid(result, 'turn_id'),
    planId: _optionalUuid(result, 'plan_id'),
    questionId: _optionalUuid(result, 'question_id'),
    mode: _enum(CollaborationMode.values, result['collaboration_mode']),
    busy: busy is bool ? busy : null,
    unread: read is int && last is int && read >= 0 && last >= 0
        ? UnreadState(readSequence: read, lastSequence: last)
        : null,
  );
}

/// One answer: a chosen option label, free text, or both.
final class QuestionAnswer {
  const QuestionAnswer({this.selected, this.text = ''});
  final String? selected;
  final String text;

  /// Marshall requires a selection or non-blank text.
  bool get complete => selected != null || text.trim().isNotEmpty;
}

/// Encodes answers as the JSON object `thread answer` reads on stdin, or
/// null when they do not answer every question exactly once with a valid
/// option. Marshall re-validates against the stored question.
String? encodeAnswers(PendingQuestion pending, Map<String, QuestionAnswer> answers) {
  final ids = pending.questions.map((q) => q.id).toSet();
  if (answers.length != ids.length || !answers.keys.every(ids.contains)) return null;
  final body = <String, Object?>{};
  for (final question in pending.questions) {
    final answer = answers[question.id]!;
    if (!answer.complete) return null;
    if (answer.selected != null && !question.options.any((o) => o.label == answer.selected)) {
      return null;
    }
    if (utf8.encode(answer.text).length > 16384) return null;
    body[question.id] = {'selected': answer.selected, 'text': answer.text};
  }
  final encoded = jsonEncode(body);
  return validatePayload(PayloadKind.answers, encoded) == null ? encoded : null;
}

/// Most recently updated first, then by id for a total order. Threads
/// without a time sort last.
int compareRecent(ThreadSummary a, ThreadSummary b) {
  final at = a.updatedAt, bt = b.updatedAt;
  if (at != null && bt != null && at != bt) return bt.compareTo(at);
  if (at != null && bt == null) return -1;
  if (at == null && bt != null) return 1;
  return a.id.compareTo(b.id);
}

/// Filters [threads] by a case-insensitive query over title, status and
/// mode (and `unread`), then orders them with [compareRecent].
List<ThreadSummary> searchThreads(Iterable<ThreadSummary> threads, String query) {
  final terms = query.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  bool matches(ThreadSummary thread) {
    final haystack = [
      thread.title,
      thread.status?.name ?? '',
      thread.mode?.name ?? '',
      if (thread.unread.hasUnread) 'unread',
    ].join(' ').toLowerCase();
    return terms.every(haystack.contains);
  }

  return threads.where(matches).toList()..sort(compareRecent);
}

/// Total unread events across [threads].
int totalUnread(Iterable<ThreadSummary> threads) =>
    threads.fold(0, (sum, thread) => sum + thread.unread.unread);
