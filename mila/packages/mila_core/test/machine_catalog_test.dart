import 'package:mila_core/mila_core.dart';
import 'package:test/test.dart';

const String _id = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';
const String _request = 'porsche-0123456789abcdef0123456789abcdef';
final String _digest = 'sha256:${'a' * 64}';

void main() {
  test('images keep only rows new --image would accept', () {
    final images = decodeImageChoices({
      'images': [
        {'id': _digest, 'name': 'NixOS', 'architecture': 'x86_64'},
        {'id': 'latest', 'name': 'Tagged'},
        {'id': 'sha256:${'b' * 64}', 'name': ''},
        'junk',
      ],
    });
    expect(images.map((i) => (i.id, i.name, i.architecture)), [(_digest, 'NixOS', 'x86_64')]);
    expect(decodeImageChoices({'images': 'nope'}), isEmpty);
  });

  test('teams keep only names new --team would accept, with a canonical cursor', () {
    final (teams, cursor) = decodeTeamChoices({
      'items': [
        {'id': _id, 'name': 'platform', 'role': 'admin'},
        {'id': _id, 'name': 'Bad Team', 'role': 'member'},
        {'id': 'x', 'name': 'ops', 'role': 'member'},
      ],
      'next_cursor': _id,
    });
    expect(teams.map((t) => t.name), ['platform']);
    expect(cursor, _id);
    expect(decodeTeamChoices({'items': const [], 'next_cursor': 'x'}).$2, isNull);
  });

  test('new sends a chosen image and team only when given', () {
    final command = createMachineCommand(image: _digest, team: 'platform', requestId: _request)!;
    expect(command.options['image'], _digest);
    expect(command.options['team'], 'platform');
    expect(parseCommandLine(encodeCommand(command)), command);
    expect(createMachineCommand(image: 'latest', requestId: _request), isNull);
    expect(createMachineCommand(team: 'Bad Team', requestId: _request), isNull);
    expect(createMachineCommand(requestId: _request)!.options.containsKey('image'), isFalse);
  });

  test('retry and cancel name the original request under a fresh id', () {
    for (final control in RequestControl.values) {
      final command = requestControlCommand(control, 'porsche-${'1' * 32}', requestId: _request)!;
      expect(command.name, control.command);
      expect(command.arguments, ['porsche-${'1' * 32}']);
      expect(command.options['request-id'], _request);
      expect(validateCommand(command), isNull);
      expect(parseCommandLine(encodeCommand(command)), command);
    }
    expect(requestControlCommand(RequestControl.retry, 'bad id', requestId: _request), isNull);
  });

  test('a machine carries its architecture and creation time', () {
    final machine = decodeMachine({
      'id': _id,
      'name': 'dev-box',
      'desired_state': 'running',
      'permissions': {'read': true},
      'architecture': 'aarch64',
      'inserted_at': '2026-10-20T01:02:03.000000Z',
    });
    expect(machine.architecture, 'aarch64');
    expect(machine.createdAt, DateTime.utc(2026, 10, 20, 1, 2, 3));
    final local = decodeMachine({
      'id': _id,
      'name': 'dev-box',
      'desired_state': 'running',
      'permissions': {'read': true},
      'inserted_at': '2026-10-20T01:02:03',
    });
    expect(local.createdAt, isNull);
  });
}
