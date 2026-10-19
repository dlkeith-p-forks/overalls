import 'dart:convert';
import 'dart:math';

import 'package:hegel/hegel.dart';
import 'package:mila_core/mila_core.dart';
import 'package:test/test.dart';

const String _thread = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';
const String _question = '6f1e2d3c-4b5a-4987-8a6b-5c4d3e2f1a0b';
const String _plan = '3b8f4c2a-1d6e-4f70-9a5b-2c7d8e9f0a1b';

final Generator<UnreadState> _unread = tuple2(
  integers(min: 0, max: 1000),
  integers(min: 0, max: 1000),
).map((v) => UnreadState(readSequence: v.$1, lastSequence: v.$2));

Map<String, Object?> _row(int n, {int? updated, int read = 0, int last = 0, String? title}) => {
  'id': '0d9cc041-9db2-4e4c-b28b-${n.toRadixString(16).padLeft(12, '0')}',
  'title': title ?? 'Thread $n',
  'status': 'ready',
  'collaboration_mode': 'work',
  'read_sequence': read,
  'last_sequence': last,
  'updated_at': updated == null
      ? null
      : DateTime.utc(2026, 10, 18).add(Duration(minutes: updated)).toIso8601String(),
};

const PendingQuestion _pending = PendingQuestion(_question, [
  AgentQuestion(
    id: 'scope',
    header: 'Scope',
    question: 'Which part first?',
    options: [QuestionOption('API', 'The server'), QuestionOption('UI', 'The app')],
  ),
  AgentQuestion(id: 'notes', header: 'Notes', question: 'Anything else?', options: []),
]);

void main() {
  property('read markers only move forward', (tc) {
    final state = tc.draw(_unread, name: 'state');
    final seq = tc.draw(integers(min: 0, max: 2000), name: 'seq');
    final next = state.markRead(seq);
    expect(next.readSequence, greaterThanOrEqualTo(state.readSequence));
    expect(next.lastSequence, greaterThanOrEqualTo(state.lastSequence));
    expect(next.unread, lessThanOrEqualTo(max(state.unread, 0)));
    expect(next.unread, greaterThanOrEqualTo(0));
    final other = tc.draw(_unread, name: 'other');
    final merged = state.merge(other);
    expect(merged.readSequence, max(state.readSequence, other.readSequence));
    expect(merged.lastSequence, max(state.lastSequence, other.lastSequence));
    expect(state.merge(other), other.merge(state));
    final send = readMarkerToSend(state, seq);
    if (send != null) expect(send, greaterThan(state.readSequence));
    if (seq > state.readSequence) expect(send, seq);
  });

  property('recent ordering is total and search only removes', (tc) {
    final rows = tc.draw(
      lists(
        tuple3(
          integers(min: 0, max: 50),
          optional(integers(min: 0, max: 100)),
          sampledFrom(const ['build', 'deploy fix', 'Docs', '']),
        ),
        maxLength: 12,
      ),
      name: 'rows',
    );
    final threads = decodeThreadList({
      'items': [for (final (i, r) in rows.indexed) _row(i, updated: r.$2, title: r.$3, last: r.$1)],
    }).$1.items;
    final query = tc.draw(
      sampledFrom(const ['', 'deploy', 'UNREAD', 'docs ready', 'zzz']),
      name: 'q',
    );
    final found = searchThreads(threads, query);
    expect(found.length, lessThanOrEqualTo(threads.length));
    for (var i = 1; i < found.length; i++) {
      expect(compareRecent(found[i - 1], found[i]), lessThanOrEqualTo(0));
    }
    if (query.isEmpty) expect(found.length, threads.length);
    expect(totalUnread(threads), threads.fold<int>(0, (s, t) => s + t.unread.unread));
  });

  test('answers must cover every question with a valid option or text', () {
    final encoded = encodeAnswers(_pending, const {
      'scope': QuestionAnswer(selected: 'API'),
      'notes': QuestionAnswer(text: 'Keep it small'),
    });
    expect(jsonDecode(encoded!), {
      'scope': {'selected': 'API', 'text': ''},
      'notes': {'selected': null, 'text': 'Keep it small'},
    });
    expect(encodeAnswers(_pending, const {'scope': QuestionAnswer(selected: 'API')}), isNull);
    expect(
      encodeAnswers(_pending, const {
        'scope': QuestionAnswer(selected: 'Other'),
        'notes': QuestionAnswer(text: 'x'),
      }),
      isNull,
    );
    expect(
      encodeAnswers(_pending, const {
        'scope': QuestionAnswer(selected: 'UI'),
        'notes': QuestionAnswer(text: '   '),
      }),
      isNull,
    );
  });

  test('thread show decodes questions and plans, dropping unrenderable ones', () {
    final detail = decodeThreadDetail({
      ..._row(1, read: 2, last: 9),
      'busy': true,
      'pending_question': {
        'id': _question,
        'questions': [
          {
            'id': 'scope',
            'header': 'Scope',
            'question': 'Which part first?',
            'options': [
              {'label': 'API', 'description': 'The server'},
            ],
          },
        ],
      },
      'latest_plan': {'id': _plan, 'text': '1. Do it', 'implemented': false, 'event_sequence': 8},
    });
    expect(detail.busy, isTrue);
    expect(detail.pendingQuestion!.questions.single.options.single.label, 'API');
    expect(detail.latestPlan!.text, '1. Do it');
    final broken = decodeThreadDetail({
      ..._row(1),
      'pending_question': {
        'id': _question,
        'questions': [
          {'id': 'x', 'question': 'q', 'options': 'nope'},
        ],
      },
    });
    expect(broken.pendingQuestion, isNull);
  });

  test('turn pages keep only prompt and assistant text and stay ordered', () {
    final page = decodeTurnPage(
      {
        'thread_id': _thread,
        'items': [
          {
            'sequence': 5,
            'kind': 'prompt',
            'body': {'prompt': 'hello'},
          },
          {
            'sequence': 6,
            'kind': 'tool_result',
            'body': {'result': 'secret output'},
          },
          {
            'sequence': 7,
            'kind': 'assistant',
            'body': {'text': 'hi'},
          },
          {'sequence': 8, 'kind': 'from_the_future', 'body': {}},
        ],
        'next_after': 8,
      },
      threadId: _thread,
      after: 4,
    );
    expect(page.items.map((e) => e.text), ['hello', null, 'hi', null]);
    expect(page.items.last.kind, isNull);
    expect(page.nextAfter, 8);
    expect(
      () => decodeTurnPage({
        'thread_id': _thread,
        'items': [
          {'sequence': 5, 'kind': 'prompt'},
          {'sequence': 5, 'kind': 'prompt'},
        ],
      }, threadId: _thread),
      throwsA(isA<ThreadFormatException>()),
    );
    final shown = appendTurns(const [], page);
    final again = appendTurns(shown, page);
    expect(again.map((e) => e.sequence), [5, 6, 7, 8]);
  });

  test('payload commands carry text on stdin only', () {
    final prompt = payloadCommand(
      PorscheCommand('thread prompt', arguments: [_thread, '-'], options: {'json': true}),
      'make it --fast; rm -rf /',
    );
    expect(encodeCommand(prompt.command), 'thread prompt --json $_thread -');
    expect(utf8.decode(prompt.stdin), 'make it --fast; rm -rf /');
    expect(
      () => payloadCommand(
        PorscheCommand('thread prompt', arguments: [_thread, '-']),
        'x' * (maximumPayloadBytes + 1),
      ),
      throwsA(isA<PayloadRefused>().having((e) => e.reason, 'reason', PayloadRefusal.tooLarge)),
    );
    expect(
      () => payloadCommand(PorscheCommand('thread prompt', arguments: [_thread, '-']), '  \n'),
      throwsA(isA<PayloadRefused>()),
    );
    expect(
      () => payloadCommand(
        PorscheCommand('thread answer', arguments: [_thread, _question, '-']),
        '[1]',
      ),
      throwsA(isA<PayloadRefused>().having((e) => e.reason, 'r', PayloadRefusal.notAnObject)),
    );
    expect(
      () => payloadCommand(PorscheCommand('thread mode', arguments: [_thread, 'plan']), 'x'),
      throwsA(isA<CommandRefused>()),
    );
    expect(validatePayload(PayloadKind.revision, 'a\u0000b'), PayloadRefusal.invalidText);
    expect(validatePayload(PayloadKind.prompt, 'a\uD800'), PayloadRefusal.invalidText);
  });

  property('payloads up to the limit are accepted and never enter the line', (tc) {
    final body = tc.draw(
      text(
        minLength: 1,
        maxLength: 300,
        excludeCategories: const ['Cs'],
      ).where((t) => t.trim().isNotEmpty && !t.contains('\u0000')),
      name: 'text',
    );
    final kind = tc.draw(sampledFrom(const ['thread prompt', 'thread plan revise']), name: 'kind');
    final args = kind == 'thread prompt' ? [_thread, '-'] : [_thread, _plan, '-'];
    final built = payloadCommand(PorscheCommand(kind, arguments: args), body);
    final line = encodeCommand(built.command);
    expect(utf8.decode(built.stdin), body);
    expect(line.endsWith(' -'), isTrue);
    expect(line.length, lessThan(200));
  });
}
