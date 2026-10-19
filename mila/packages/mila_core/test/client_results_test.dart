import 'dart:convert';
import 'dart:io';

import 'package:hegel/hegel.dart';
import 'package:mila_core/mila_core.dart';
import 'package:test/test.dart';

/// Shared with Marshall's `client_commands_test` (ADR-0222).
final File _results = File('../../../protocol/test/fixtures/porsche_client_results.json');

/// Shared with `OverallsProtocol.TerminalAttachTest` (ADR-0223).
final File _attach = File('../../../protocol/test/fixtures/terminal_attach.json');

const String _thread = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';
const String _machine = '019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a';
const String _session = '019a0f73-3d4e-7f5a-8b6c-7d8e9f0a1b2c';

Map<String, Object?> _json(File file) =>
    jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

/// Adds keys a newer server might send, at every object level.
Object? _withExtras(Object? value) => switch (value) {
  final Map<String, Object?> map => {
    for (final MapEntry(:key, :value) in map.entries) key: _withExtras(value),
    'added_in_a_later_server': {'nested': true},
  },
  final List<Object?> list => [for (final item in list) _withExtras(item)],
  _ => value,
};

void main() {
  final document = _json(_results);
  final results = document['results']! as Map<String, Object?>;
  Map<String, Object?> result(String command) => results[command]! as Map<String, Object?>;

  test('the fixture covers every client command Mila decodes', () {
    expect(document['version'], 1);
    expect(
      results.keys.toSet(),
      containsAll(<String>{
        'thread ls',
        'thread show',
        'thread turns',
        'thread prompt',
        'thread answer',
        'thread plan approve',
        'thread plan revise',
        'thread mode',
        'thread read',
        'terminal ls',
        'terminal new',
        'terminal kill',
        'web show',
        'web set',
      }),
    );
    for (final name in results.keys) {
      expect(catalog, contains(name), reason: name);
    }
  });

  test('thread results decode, including unread state and routes', () {
    final (listing, skipped) = decodeThreadList(result('thread ls'));
    expect(skipped, 0);
    final row = listing.items.single;
    expect(row.id, _thread);
    expect(row.title, 'Improve the workspace');
    expect(row.status, ThreadStatus.ready);
    expect(row.mode, CollaborationMode.work);
    expect(row.machineId, _machine);
    expect(row.unread, const UnreadState(readSequence: 3, lastSequence: 7));
    expect(row.unread.unread, 4);
    expect(row.route?.page, const ThreadPage(_thread));
    expect(listing.nextCursor, isNull);

    final detail = decodeThreadDetail(result('thread show'));
    expect(detail.summary.mode, CollaborationMode.plan);
    expect(detail.busy, isFalse);
    expect(detail.pendingQuestion, isNull);
    expect(detail.latestPlan, isNull);

    final page = decodeTurnPage(result('thread turns'), threadId: _thread);
    expect(page.items.single.sequence, 4);
    expect(page.items.single.kind, TurnEventKind.assistant);
    expect(page.items.single.text, isNull);
    expect(page.nextAfter, isNull);

    for (final name in [
      'thread prompt',
      'thread answer',
      'thread plan approve',
      'thread plan revise',
      'thread mode',
      'thread read',
    ]) {
      expect(decodeThreadMutation(result(name)).threadId, _thread, reason: name);
    }
    expect(decodeThreadMutation(result('thread read')).unread?.unread, 0);
    expect(decodeThreadMutation(result('thread mode')).mode, CollaborationMode.plan);
    expect(decodeThreadMutation(result('thread plan approve')).planId, isNotNull);
  });

  test('terminal and web results decode', () {
    final (terminals, skipped) = decodeTerminalList(result('terminal ls'));
    expect(skipped, 0);
    expect(terminals.machineId, _machine);
    final session = terminals.items.single;
    expect(session.id, _session);
    expect((session.columns, session.rows, session.viewers), (120, 40, 1));
    expect(session.mine && session.canKill, isTrue);
    expect(session.killStatus, KillStatus.idle);
    expect(session.guestUser, 'dev');
    expect(session.route?.page, const MachineTerminalPage(_machine, _session));
    final opened = decodeTerminalNew(result('terminal new'));
    expect((opened.machineId, opened.sessionId), (_machine, _session));
    expect(decodeTerminalKill(result('terminal kill'), _session), isTrue);

    final shown = decodeWebEndpoint(result('web show'));
    expect((shown.port, shown.visibility, shown.revision), (8080, WebVisibility.private, 1));
    expect(shown.label, 'web-box-k3x9');
    expect(shown.url, isNull);
    expect(shown.route?.page, const MachinePage(_machine, MachineTab.web));
    final set = decodeWebEndpoint(result('web set'));
    expect((set.port, set.visibility, set.revision), (8081, WebVisibility.public, 2));
  });

  test('every result tolerates keys a later server adds', () {
    for (final name in results.keys) {
      final extended = _withExtras(results[name]) as Map<String, Object?>;
      switch (name.split(' ').first) {
        case 'thread' when name == 'thread ls':
          expect(decodeThreadList(extended).$2, 0);
        case 'thread' when name == 'thread show':
          decodeThreadDetail(extended);
        case 'thread' when name == 'thread turns':
          decodeTurnPage(extended, threadId: _thread);
        case 'thread':
          decodeThreadMutation(extended);
        case 'terminal' when name == 'terminal ls':
          expect(decodeTerminalList(extended).$2, 0);
        case 'terminal' when name == 'terminal new':
          decodeTerminalNew(extended);
        case 'terminal':
          expect(decodeTerminalKill(extended, _session), isTrue);
        case 'web':
          decodeWebEndpoint(extended);
      }
    }
  });

  test('identity fields are strict: a bad id refuses the row or result', () {
    final ls = jsonDecode(jsonEncode(result('thread ls'))) as Map<String, Object?>;
    ((ls['items']! as List<Object?>).single! as Map<String, Object?>)['id'] = 'NOT-A-UUID';
    expect(decodeThreadList(ls).$2, 1);
    expect(
      () => decodeTurnPage(result('thread turns'), threadId: _machine),
      throwsA(isA<ThreadFormatException>()),
    );
    final web = {...result('web show'), 'port': 0};
    expect(() => decodeWebEndpoint(web), throwsA(isA<WebFormatException>()));
    final link = {...result('web show'), 'url': 'javascript:alert(1)'};
    expect(decodeWebEndpoint(link).url, isNull);
    final https = {...result('web show'), 'url': 'https://web-box-k3x9.apps.example.test'};
    expect(decodeWebEndpoint(https).url.toString(), 'https://web-box-k3x9.apps.example.test');
    final userinfo = {...result('web show'), 'url': 'https://user@evil.example'};
    expect(decodeWebEndpoint(userinfo).url, isNull);
  });

  test('watch lines from the fixture decode', () {
    final lines = (document['watch']! as List<Object?>).map(jsonEncode).toList();
    final events = lines.map(decodeWatchLine).toList();
    expect(events[0], isA<Watching>());
    final watching = events[0] as Watching;
    expect(watching.machines, [_machine]);
    expect(watching.threads, [_thread]);
    expect((events[1] as ThreadChanged).threadId, _thread);
    expect(events[2], isA<Heartbeat>());
  });

  final attach = _json(_attach);

  test('attach headers decode exactly as the fixture says', () {
    expect(attach['version'], 1);
    for (final entry in (attach['headers']! as List<Object?>).cast<Map<String, Object?>>()) {
      final header = decodeAttachHeader(entry['line']! as String);
      final expected = entry['header']! as Map<String, Object?>;
      switch (expected['kind']) {
        case 'attached':
          expect(header, isA<AttachedHeader>(), reason: '$expected');
          final attached = header! as AttachedHeader;
          expect(attached.from, expected['from']);
          expect(attached.replayBytes, expected['replay_bytes']);
          expect(attached.mode == AttachMode.readWrite ? 'rw' : 'ro', expected['mode']);
        case 'refused':
          expect((header! as RefusedHeader).error.wire, expected['error']);
      }
    }
    for (final line in (attach['invalid_headers']! as List<Object?>).cast<String>()) {
      expect(decodeAttachHeader(line), isNull, reason: line);
    }
  });

  test('the exit and error tables match the fixture', () {
    for (final entry in (attach['exit_codes']! as List<Object?>).cast<Map<String, Object?>>()) {
      final outcome = AttachOutcome.fromStatus(entry['status']! as int);
      expect(outcome.name, entry['outcome']);
      expect(outcome.status, entry['status']);
    }
    expect(AttachOutcome.values.map((o) => o.status).toSet(), hasLength(5));
    expect(AttachOutcome.fromStatus(null), AttachOutcome.transport);
    expect(AttachOutcome.fromStatus(130), AttachOutcome.transport);
    final errors = (attach['errors']! as List<Object?>).cast<Map<String, Object?>>();
    expect(errors.map((e) => e['error']).toSet(), AttachError.values.map((e) => e.wire).toSet());
    for (final entry in errors) {
      expect(AttachError.fromWire(entry['error'])!.outcome.name, entry['outcome']);
    }
    expect(attach['invocation'], containsPair('requires_pty', true));
  });

  property('arbitrary header text never throws and never invents a header', (tc) {
    final line = tc.draw(text(maxLength: 600), name: 'line');
    final header = decodeAttachHeader(line);
    if (header != null) {
      // Anything accepted re-encodes to the closed schema.
      final value = jsonDecode(line.trimRight()) as Map<String, Object?>;
      expect(value['version'], 1);
      expect(value.length, header is AttachedHeader ? 5 : 3);
    }
  });

  property('arbitrary thread results decode or refuse, never throw otherwise', (tc) {
    final value = tc.draw(
      maps(
        sampledFrom(const ['id', 'thread_id', 'items', 'read_sequence', 'last_sequence', 'title']),
        oneOf<Object?>([
          just(_thread),
          integers(min: -2, max: 9),
          text(maxLength: 8),
          just(<Object?>[]),
          just(null),
        ]),
        maxLength: 6,
      ),
      name: 'result',
    );
    for (final decode in <void Function()>[
      () => decodeThreadList(value),
      () => decodeThreadDetail(value),
      () => decodeTurnPage(value, threadId: _thread),
      () => decodeThreadMutation(value),
    ]) {
      try {
        decode();
      } on ThreadFormatException {
        // A refusal is the only failure.
      }
    }
  });
}
