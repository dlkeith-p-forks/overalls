import 'dart:convert';
import 'dart:io';

import 'package:hegel/hegel.dart';
import 'package:mila_core/src/app_route.dart';
import 'package:mila_core/src/machine.dart';
import 'package:test/test.dart';

/// Shared with `MarshallWeb.Components.MachineStateFixtureTest`.
final File _states = File('../../../protocol/test/fixtures/machine_states.json');

const String _id = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';
const String _other = '6f1e2d3c-4b5a-4987-8a6b-5c4d3e2f1a0b';

Map<String, Object?> _row({String id = _id, String name = 'box', bool pinned = false}) => {
  'id': id,
  'name': name,
  'desired_state': 'running',
  'observed_state': 'running',
  'pinned': pinned,
  'owner': true,
  'permissions': {'read': true, 'write': true, 'manage': true},
  'route': 'overalls://overalls.example/machines/$id',
  'image_name': 'NixOS',
  'vcpu': 2,
  'memory_bytes': 4294967296,
  'disk_bytes': 53687091200,
  'resize': null,
  'relocation': null,
};

String _capitalised(StateLabel label) => label.name[0].toUpperCase() + label.name.substring(1);

final Generator<Machine> _machine =
    tuple2(
      tuple2(fromRegex(r'[a-z][a-z0-9-]{0,10}', fullMatch: true), booleans()),
      tuple2(sampledFrom(DesiredState.values), sampledFrom(ObservedState.values)),
    ).flatMap(
      (v) => integers(min: 0, max: 0xffff).map(
        (n) => Machine(
          id: '${n.toRadixString(16).padLeft(8, '0')}-0000-4000-8000-000000000000',
          name: v.$1.$1,
          desired: v.$2.$1,
          observed: v.$2.$2,
          pinned: v.$1.$2,
          owner: true,
          permissions: const MachinePermissions(read: true, write: false, manage: false),
        ),
      ),
    );

void main() {
  test('every state pair labels and tones exactly as the web', () {
    final document = jsonDecode(_states.readAsStringSync()) as Map<String, Object?>;
    final rows = (document['states']! as List<Object?>).cast<Map<String, Object?>>();
    expect(rows, hasLength(DesiredState.values.length * ObservedState.values.length));
    for (final row in rows) {
      final desired = DesiredState.values.byName(row['desired_state']! as String);
      final observed = ObservedState.values.byName(row['observed_state']! as String);
      expect(_capitalised(stateLabel(desired, observed)), row['label'], reason: '$row');
      expect(stateTone(desired, observed)?.name, row['tone'], reason: '$row');
    }
  });

  test('an unknown observed state is unavailable, not guessed', () {
    final machine = decodeMachine({..._row(), 'observed_state': 'hibernating'});
    expect(machine.observed, isNull);
    expect(machine.label, StateLabel.unavailable);
  });

  test('decoding keeps pinned and the route, ignoring unknown keys', () {
    final machine = decodeMachine({..._row(pinned: true), 'future_field': 1});
    expect(machine.pinned, isTrue);
    expect(machine.route, isNotNull);
    expect(machine.route!.page, const MachinePage(_id));
    expect(machine.permissions.manage, isTrue);
  });

  test('a route naming another machine is dropped', () {
    final machine = decodeMachine({
      ..._row(),
      'route': 'overalls://overalls.example/machines/$_other',
    });
    expect(machine.route, isNull);
  });

  test('strict identity fields refuse the row', () {
    for (final broken in [
      {..._row(), 'id': 'not-a-uuid'},
      {..._row(), 'name': ''},
      {..._row(), 'desired_state': 'flying'},
      {..._row(), 'permissions': null},
    ]) {
      expect(() => decodeMachine(broken), throwsA(isA<MachineFormatException>()));
    }
  });

  test('a listing skips and counts bad rows', () {
    final (page, skipped) = decodeMachineList({
      'items': [
        _row(),
        'junk',
        {..._row(id: _other), 'id': 'x'},
      ],
      'next_cursor': _other,
    });
    expect(page.items, hasLength(1));
    expect(skipped, 2);
    expect(page.nextCursor, _other);
  });

  property('search results are pinned first and totally ordered', (tc) {
    final machines = tc.draw(lists(_machine, maxLength: 12), name: 'machines');
    final query = tc.draw(sampledFrom(const ['', 'a', 'running', 'pinned', 'x y']), name: 'q');
    final found = searchMachines(machines, query);
    for (var i = 1; i < found.length; i++) {
      expect(compareMachines(found[i - 1], found[i]), lessThanOrEqualTo(0));
    }
    final firstUnpinned = found.indexWhere((m) => !m.pinned);
    if (firstUnpinned >= 0) {
      expect(found.skip(firstUnpinned).every((m) => !m.pinned), isTrue);
    }
    expect(found.every(machines.contains), isTrue);
    if (query.isEmpty) expect(found, hasLength(machines.length));
  });

  property('search is monotone: adding a term never adds results', (tc) {
    final machines = tc.draw(lists(_machine, maxLength: 12), name: 'machines');
    final first = tc.draw(fromRegex(r'[a-z]{0,3}', fullMatch: true), name: 'first');
    final second = tc.draw(fromRegex(r'[a-z]{1,3}', fullMatch: true), name: 'second');
    final wide = searchMachines(machines, first).toSet();
    final narrow = searchMachines(machines, '$first $second');
    expect(narrow.every(wide.contains), isTrue);
  });

  property('every label has a tone decision and transitions are pending', (tc) {
    final desired = tc.draw(sampledFrom(DesiredState.values), name: 'desired');
    final observed = tc.draw(
      sampledFrom<ObservedState?>([...ObservedState.values, null]),
      name: 'o',
    );
    final label = stateLabel(desired, observed);
    final tone = stateTone(desired, observed);
    if (const [StateLabel.deleting, StateLabel.stopping, StateLabel.starting].contains(label)) {
      expect(tone, StateTone.pending);
    }
    if (label == StateLabel.failed) expect(tone, StateTone.danger);
    if (tone == StateTone.success) expect(label, StateLabel.running);
  });

  test('routes in rows still parse with the shared grammar', () {
    expect(parseMilaRoute(_row()['route']! as String), isNotNull);
  });
}
