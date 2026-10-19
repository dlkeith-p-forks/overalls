import 'dart:convert';

import 'package:hegel/hegel.dart';
import 'package:mila_core/src/porsche_reply.dart';
import 'package:test/test.dart';

const String _operation = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';
const String _fingerprint = 'SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU';

final Generator<String> _requestId = fromRegex(r'porsche-[0-9a-f]{32}', fullMatch: true);
final Generator<Map<String, Object?>> _result = sampledFrom<Map<String, Object?>>([
  {},
  {'machines': <Object?>[], 'next': null},
  {'id': _operation, 'name': 'box', 'pinned': true, 'future_field': 1},
]);

/// Envelopes Porsche emits, built from `Porsche.Runner`'s shapes.
final Generator<Map<String, Object?>> _envelope = oneOf([
  _result.map((result) => {'version': 1, 'status': 'succeeded', 'result': result}),
  tuple2(
    tuple2(_requestId, sampledFrom(const ['accepted', 'succeeded', 'failed', 'superseded'])),
    tuple2(_result, booleans()),
  ).map(
    (v) => {
      'version': 1,
      'request_id': v.$1.$1,
      'status': v.$1.$2,
      'operation_id': _operation,
      'result': v.$2.$1,
      if (v.$2.$2) 'wait_status': 'timed_out',
    },
  ),
  _requestId.map(
    (id) => {
      'version': 1,
      'request_id': id,
      'status': 'succeeded',
      'operation_id': null,
      'result': <String, Object?>{},
    },
  ),
  tuple2(
    sampledFrom(const ['unauthorized', 'not_found', 'machine_pinned', 'temporarily_unavailable']),
    booleans(),
  ).map((v) => {'version': 1, 'status': 'error', 'error': v.$1, if (v.$2) 'hint': 'Fixed hint.'}),
  just<Map<String, Object?>>({
    'version': 1,
    'status': 'approval_required',
    'fingerprint': _fingerprint,
    'approval_url': 'https://overalls.example/ssh/approve/abc',
    'message': 'Approve this key in your browser, then retry the command.',
  }),
]);

void main() {
  test('exit codes are the closed Porsche table', () {
    expect(PorscheExit.values.map((e) => e.code), [0, 1, 2, 3, 4, 5, 130]);
    expect(PorscheExit.fromCode(6), isNull);
    expect(PorscheExit.fromCode(130), PorscheExit.interrupted);
  });

  test('approval replies require an https url without userinfo', () {
    Map<String, Object?> approval(String url) => {
      'version': 1,
      'status': 'approval_required',
      'fingerprint': _fingerprint,
      'approval_url': url,
    };
    expect(decodeReply(approval('https://overalls.example/ssh/approve/a')), isA<ApprovalReply>());
    for (final url in ['http://overalls.example/a', 'https://u@overalls.example/a', 'x']) {
      expect(() => decodeReply(approval(url)), throwsA(isA<ReplyFormatException>()), reason: url);
    }
  });

  test('physical receipts need an operation id and durable ones may omit it', () {
    expect(
      () => decodeReply({
        'version': 1,
        'request_id': 'r',
        'status': 'accepted',
        'operation_id': null,
        'result': <String, Object?>{},
      }),
      throwsA(isA<ReplyFormatException>()),
    );
  });

  test('pollable outcomes never include terminal receipts', () {
    const done = ReceiptReply(
      requestId: 'r',
      status: ReceiptStatus.failed,
      operationId: _operation,
      result: {},
    );
    expect(const ChannelOutcome(PorscheExit.failed, done).pollable, isFalse);
    expect(const ChannelOutcome(PorscheExit.timedOut, null).pollable, isTrue);
  });

  property('emitted envelopes decode to their own fields', (tc) {
    final envelope = tc.draw(_envelope, name: 'envelope');
    final reply = decodeReplyLine('${jsonEncode(envelope)}\n');
    switch (reply) {
      case ReadReply(:final result):
        expect(result, envelope['result']);
      case ReceiptReply(:final requestId, :final status, :final waitTimedOut):
        expect(requestId, envelope['request_id']);
        expect(status.name, envelope['status']);
        expect(waitTimedOut, envelope['wait_status'] == 'timed_out');
      case ErrorReply(:final error, :final hint):
        expect(error, envelope['error']);
        expect(hint, envelope['hint']);
      case ApprovalReply(:final fingerprint):
        expect(fingerprint, envelope['fingerprint']);
    }
  });

  property('an extra or missing envelope key is refused', (tc) {
    final envelope = Map<String, Object?>.of(tc.draw(_envelope, name: 'envelope'));
    final drop = tc.draw(booleans(), name: 'drop');
    if (drop) {
      final required = envelope.keys
          .where((k) => !const {'wait_status', 'hint', 'message'}.contains(k))
          .toList();
      envelope.remove(tc.draw(sampledFrom(required), name: 'key'));
    } else {
      envelope['session_token'] = 'secret';
    }
    expect(() => decodeReply(envelope), throwsA(isA<ReplyFormatException>()));
  });

  property('arbitrary lines only ever fail with ReplyFormatException', (tc) {
    final line = tc.draw(
      oneOf([
        text(maxLength: 64),
        _envelope
            .map(jsonEncode)
            .flatMap(
              (json) => integers(min: 0, max: json.length).map((cut) => json.substring(0, cut)),
            ),
      ]),
      name: 'line',
    );
    try {
      decodeReplyLine(line);
    } on ReplyFormatException {
      // Refused, as expected for most input.
    }
  });
}
