import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:hegel/hegel.dart';
import 'package:mila_core/src/ssh_command.dart';
import 'package:test/test.dart';

/// Shared with `OverallsProtocol.SSHCommandLinesTest`.
final File _vectors = File('../../../protocol/test/fixtures/ssh_command_lines.json');

PorscheCommand _fromJson(Map<String, Object?> value) => PorscheCommand(
  value['command']! as String,
  arguments: (value['arguments']! as List<Object?>).cast<String>(),
  options: (value['options']! as Map<String, Object?>).map(
    (key, value) => MapEntry(key, value is List<Object?> ? value.cast<String>().toList() : value!),
  ),
);

final Generator<String> _uuid =
    lists(
      integers(min: 0, max: 255).map((b) => b.toRadixString(16).padLeft(2, '0')),
      minLength: 16,
      maxLength: 16,
    ).map((bytes) {
      final hex = bytes.join();
      return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
          '${hex.substring(16, 20)}-${hex.substring(20)}';
    });

/// An unpadded base64url X25519 public key, as `--enc-pubkey` carries it.
final Generator<String> _encKey = fromRegex(r'[A-Za-z0-9_-]{43}', fullMatch: true);

final Generator<String> _machine = oneOf([
  fromRegex(r'[a-z][a-z0-9]{0,8}(-[a-z0-9]{1,6}){0,2}', fullMatch: true),
  _uuid,
]);

/// Free text for share emails: any printable characters, including quotes,
/// backslashes, spaces and leading dashes.
final Generator<String> _freeText = text(
  minLength: 1,
  maxLength: 40,
  excludeCategories: const ['Cc', 'Cs', 'Zl', 'Zp'],
).where((value) => utf8.encode(value).length <= 320);

final Generator<PorscheCommand> _command = oneOf<PorscheCommand>([
  just(PorscheCommand('whoami', options: {'json': true})),
  _uuid.map((after) => PorscheCommand('ls', options: {'json': true, 'after': after})),
  tuple2(
    _machine,
    sampledFrom(const ['start', 'stop', 'pause', 'resume', 'unpause', 'rm', 'pin', 'show']),
  ).map((v) => PorscheCommand(v.$2, arguments: [v.$1], options: {'json': true})),
  tuple2(_machine, integers(min: 1, max: 3600)).map(
    (v) => PorscheCommand(
      'start',
      arguments: [v.$1],
      options: {
        'json': true,
        'no-wait': true,
        'timeout': '${v.$2}',
        'request-id': allocateRequestId(Random(v.$2)),
      },
    ),
  ),
  tuple2(
    tuple2(_machine, _freeText),
    sampledFrom(const ['viewer', 'operator', 'manager']),
  ).map((v) => PorscheCommand('share add', arguments: [v.$1.$1, v.$1.$2, v.$2])),
  tuple2(_machine, _freeText).map((v) => PorscheCommand('share remove', arguments: [v.$1, v.$2])),
  tuple2(sampledFrom(pushPlatforms.toList()), _encKey).map(
    (v) => PorscheCommand(
      'device register',
      options: {
        'json': true,
        'platform': v.$1,
        'push-key': '-',
        'enc-pubkey': v.$2,
        'request-id': allocateRequestId(Random(v.$2.length)),
      },
    ),
  ),
  just(PorscheCommand('device ls', options: {'json': true})),
  _uuid.map((id) => PorscheCommand('device rm', arguments: [id], options: {'json': true})),
  tuple2(
    _uuid,
    booleans(),
  ).map((v) => PorscheCommand('device prefs', arguments: [v.$1], options: {'enabled': '${v.$2}'})),
]);

/// The thread, terminal, web and watch commands (ADR-0222).
final Generator<PorscheCommand> _clientCommand =
    tuple2(tuple2(_uuid, _uuid), tuple2(_machine, integers(min: 0, max: 2147483647))).flatMap((v) {
      final ((thread, other), (machine, sequence)) = v;
      return sampledFrom([
        PorscheCommand('thread ls', options: {'machine': machine, 'after': thread, 'json': true}),
        PorscheCommand('thread show', arguments: [thread]),
        PorscheCommand('thread turns', arguments: [thread], options: {'after': '$sequence'}),
        PorscheCommand('thread prompt', arguments: [thread, '-'], options: {'json': true}),
        PorscheCommand('thread answer', arguments: [thread, other, '-']),
        PorscheCommand('thread plan approve', arguments: [thread, other]),
        PorscheCommand('thread plan revise', arguments: [thread, other, '-']),
        PorscheCommand('thread mode', arguments: [thread, 'plan']),
        PorscheCommand('thread read', arguments: [thread, '$sequence']),
        PorscheCommand('terminal ls', arguments: [machine]),
        PorscheCommand('terminal new', arguments: [machine], options: {'request-id': 'porsche-1'}),
        PorscheCommand('terminal kill', arguments: [machine, other]),
        PorscheCommand('web show', arguments: [machine]),
        PorscheCommand('web set', arguments: [machine], options: {'port': '8080', 'public': true}),
        PorscheCommand(
          'web set',
          arguments: [machine],
          options: {'private': true, 'revision': '2'},
        ),
        PorscheCommand(
          'watch',
          options: {
            'machine': [machine, other],
            'thread': thread,
            'session': true,
          },
        ),
      ]);
    });

void main() {
  final document = jsonDecode(_vectors.readAsStringSync()) as Map<String, Object?>;

  test('shared lines parse to the same structure as the server', () {
    expect(document['version'], 1);
    final accepted = (document['accepted']! as List<Object?>).cast<Map<String, Object?>>();
    for (final entry in accepted) {
      final line = entry['line']! as String;
      final expected = _fromJson(entry['command']! as Map<String, Object?>);
      final parsed = parseCommandLine(line);
      expect(parsed, expected, reason: line);
      expect(validateCommand(parsed!), isNull, reason: line);
      expect(parseCommandLine(encodeCommand(expected)), expected, reason: line);
    }
  });

  test('shared refused lines are refused by lexing or by the catalog', () {
    for (final line in (document['refused']! as List<Object?>).cast<String>()) {
      final parsed = parseCommandLine(line);
      expect(parsed == null || validateCommand(parsed) != null, isTrue, reason: jsonEncode(line));
    }
  });

  test('every Mila catalog row is a known server command', () {
    expect(catalog.keys, everyElement(isNot(startsWith('integration'))));
    for (final MapEntry(:key, :value) in catalog.entries) {
      expect(value.name, key);
      expect(!value.physical || value.mutation, isTrue, reason: key);
    }
  });

  test('invalid commands throw before any line exists', () {
    expect(
      () => encodeCommand(PorscheCommand('show')),
      throwsA(
        isA<CommandRefused>().having((e) => e.reason, 'reason', CommandRefusal.argumentCount),
      ),
    );
    expect(
      () => encodeCommand(PorscheCommand('pin', arguments: ['a'], options: {'timeout': '5'})),
      throwsA(isA<CommandRefused>()),
    );
    expect(
      () => encodeCommand(PorscheCommand('integration add', arguments: ['x'])),
      throwsA(isA<CommandRefused>()),
    );
  });

  test('device commands carry the push key on stdin and only a bounded public key', () {
    const key = 'lTVivsmQGYBRLZMJOkaiDfgARfzYIk6PmDqwmsRmXEM';
    final line = encodeCommand(
      PorscheCommand(
        'device register',
        options: {'json': true, 'platform': 'ios', 'push-key': '-', 'enc-pubkey': key},
      ),
    );
    expect(line, 'device register --enc-pubkey=$key --json --platform=ios --push-key=-');
    for (final options in [
      {'platform': 'ios', 'push-key': 'secret-key', 'enc-pubkey': key},
      {'platform': 'linux', 'push-key': '-', 'enc-pubkey': key},
      {'platform': 'ios', 'push-key': '-', 'enc-pubkey': '$key='},
      {'platform': 'ios', 'push-key': '-'},
    ]) {
      expect(validateCommand(PorscheCommand('device register', options: options)), isNotNull);
    }
    expect(
      validateCommand(
        PorscheCommand('device prefs', arguments: ['not-a-uuid'], options: {'enabled': 'true'}),
      ),
      CommandRefusal.invalidArgument,
    );
    expect(
      validateCommand(
        PorscheCommand('device prefs', arguments: ['0d9cc041-9db2-4e4c-b28b-1e41d7f472c1']),
      ),
      CommandRefusal.invalidOption,
    );
    expect(parseCommandLine('device rm 0d9cc041-9db2-4e4c-b28b-1e41d7f472c1')!.name, 'device rm');
  });

  test('request ids match the server allocation shape', () {
    final id = allocateRequestId();
    expect(id, matches(RegExp(r'^porsche-[0-9a-f]{32}$')));
    expect(isRequestId(id), isTrue);
  });

  property('encoded commands lex back to the same command', (tc) {
    final command = tc.draw(_command, name: 'command');
    final line = encodeCommand(command);
    expect(utf8.encode(line).length, lessThanOrEqualTo(maximumLineBytes));
    expect(line.contains('\n') || line.contains('\r'), isFalse);
    expect(parseCommandLine(line), command);
  });

  property('client commands encode to lines the server grammar reads back', (tc) {
    final command = tc.draw(_clientCommand, name: 'command');
    expect(validateCommand(command), isNull);
    final line = encodeCommand(command);
    expect(parseCommandLine(line), command);
    expect(line.contains('\n') || line.contains('\r'), isFalse);
  });

  property('a corrupted thread identifier is refused before any line exists', (tc) {
    final command = tc.draw(_clientCommand, name: 'command');
    final garbage = tc.draw(sampledFrom(const ['', 'x', 'NOT-A-UUID', '-1']), name: 'garbage');
    if (command.name.startsWith('thread ') && command.arguments.isNotEmpty) {
      final corrupted = PorscheCommand(
        command.name,
        arguments: [garbage, ...command.arguments.skip(1)],
        options: command.options,
      );
      expect(validateCommand(corrupted), isNotNull);
    }
  });

  test('stdin payload commands name their kind and limit', () {
    const thread = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';
    expect(stdinPayload(PorscheCommand('thread prompt', arguments: [thread, '-'])), (
      PayloadKind.prompt,
      65536,
    ));
    expect(
      stdinPayload(PorscheCommand('thread answer', arguments: [thread, thread, '-']))?.$1,
      PayloadKind.answers,
    );
    expect(stdinPayload(PorscheCommand('thread show', arguments: [thread])), isNull);
    // The payload never travels on the command line.
    expect(
      validateCommand(
        PorscheCommand('thread prompt', arguments: [thread, '-'], options: {'stdin': 'hi'}),
      ),
      CommandRefusal.unknownOption,
    );
  });

  test('watch filters are bounded and web set names a setting', () {
    final many = [for (var i = 0; i < 17; i++) 'box-$i'];
    expect(
      validateCommand(PorscheCommand('watch', options: {'machine': many})),
      CommandRefusal.invalidOption,
    );
    expect(validateCommand(PorscheCommand('watch')), CommandRefusal.invalidOption);
    expect(
      validateCommand(PorscheCommand('web set', arguments: ['box'], options: {'json': true})),
      CommandRefusal.invalidOption,
    );
    expect(
      validateCommand(
        PorscheCommand('web set', arguments: ['box'], options: {'public': true, 'private': true}),
      ),
      CommandRefusal.invalidOption,
    );
    expect(
      validateCommand(
        PorscheCommand(
          'thread ls',
          options: {
            'machine': ['a', 'b'],
          },
        ),
      ),
      CommandRefusal.invalidOption,
    );
  });

  property('lexing arbitrary text never throws', (tc) {
    final line = tc.draw(text(maxLength: 80), name: 'line');
    final tokens = lexCommandLine(line);
    if (tokens != null) expect(tokens.length, lessThanOrEqualTo(maximumTokens + 1));
    parseCommandLine(line);
  });

  property('a quoted token never splits or escapes into a second token', (tc) {
    final value = tc.draw(_freeText, name: 'value');
    final line = encodeCommand(PorscheCommand('share remove', arguments: ['box', value]));
    final tokens = lexCommandLine(line)!;
    expect(tokens.last, value);
    // `share remove box VALUE`, plus the `--` separator before a leading `--`.
    expect(tokens.length, value.startsWith('--') ? 5 : 4);
    expect(parseCommandLine(line)!.arguments, ['box', value]);
  });
}
