import 'dart:convert';

import 'package:hegel/hegel.dart';
import 'package:mila_core/src/machine.dart';
import 'package:mila_core/src/snapshot_cache.dart';
import 'package:test/test.dart';

const String _host = 'control.example.test';

final Generator<String> _uuid = fromRegex(
  r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
  fullMatch: true,
);

/// Wire rows as `ls --json` sends them, including keys a snapshot drops.
final Generator<Map<String, Object?>> _row =
    tuple3(
      _uuid,
      fromRegex(r'[a-z][a-z0-9-]{0,20}', fullMatch: true),
      tuple3(
        sampledFrom(DesiredState.values),
        sampledFrom<ObservedState?>([...ObservedState.values, null]),
        booleans(),
      ),
    ).map(
      (v) => {
        'id': v.$1,
        'name': v.$2,
        'desired_state': v.$3.$1.name,
        'observed_state': v.$3.$2?.name,
        'pinned': v.$3.$3,
        'owner': true,
        'permissions': {'read': true, 'write': v.$3.$3, 'manage': false},
        'route': 'overalls://$_host/machines/${v.$1}',
        'image_name': 'ubuntu',
        'vcpu': 2,
        'memory_bytes': 1 << 30,
        'disk_bytes': 10 << 30,
        'ssh_host': '${v.$2}.machines.example.test',
        'terminal_token': 'secret-should-never-be-cached',
      },
    );

final Generator<List<Machine>> _machines = lists(_row, maxLength: 12).map((rows) {
  final seen = <String>{};
  return [
    for (final row in rows)
      if (seen.add(row['id']! as String)) decodeMachine(row),
  ];
});

MachineSnapshot _snapshot(List<Machine> machines, int minute) => MachineSnapshot(
  host: _host,
  port: null,
  savedAt: DateTime.utc(2026, 10, 18, 12, minute),
  machines: machines,
);

Map<String, Object?> _view(Machine m) => {
  'id': m.id,
  'name': m.name,
  'desired': m.desired,
  'observed': m.observed,
  'pinned': m.pinned,
  'write': m.permissions.write,
  'route': m.route?.format(),
};

void main() {
  property('snapshots round-trip and keep only the closed schema', (tc) {
    final machines = tc.draw(_machines, name: 'machines');
    final snapshot = _snapshot(machines, 1);
    final bytes = encodeSnapshot(snapshot);
    final text = utf8.decode(bytes);
    expect(text, isNot(contains('secret-should-never-be-cached')));
    expect(text, isNot(contains('ssh_host')));
    final decoded = decodeSnapshot(bytes, host: _host, port: null)!;
    expect(decoded.savedAt, snapshot.savedAt);
    expect(decoded.machines.map(_view), snapshot.machines.map(_view));
    expect(decodeSnapshot(bytes, host: 'other.example.test', port: null), isNull);
    expect(decodeSnapshot(bytes, host: _host, port: 2222), isNull);
  });

  property('an older listing never replaces a newer one', (tc) {
    final a = _snapshot(
      tc.draw(_machines, name: 'a'),
      tc.draw(integers(min: 0, max: 59), name: 'ta'),
    );
    final b = _snapshot(
      tc.draw(_machines, name: 'b'),
      tc.draw(integers(min: 0, max: 59), name: 'tb'),
    );
    final ab = mergeSnapshot(mergeSnapshot(null, a), b);
    final ba = mergeSnapshot(mergeSnapshot(null, b), a);
    final newest = a.savedAt.isAfter(b.savedAt) ? a : b;
    if (a.savedAt != b.savedAt) {
      // Order of arrival does not matter: the newest listing wins.
      expect(identical(ab, newest), isTrue);
      expect(identical(ba, newest), isTrue);
    }
    expect(identical(mergeSnapshot(ab, ab), ab), isTrue);
  });

  property('a newer complete listing drops machines the deployment no longer has', (tc) {
    final old = tc.draw(_machines, name: 'old');
    final fresh = tc.draw(_machines, name: 'fresh');
    final merged = mergeSnapshot(_snapshot(old, 1), _snapshot(fresh, 2));
    expect(merged.machines.map((m) => m.id).toSet(), fresh.map((m) => m.id).toSet());
    // Pinned first, then by name, so the cached list reads like the live one.
    final sorted = [...merged.machines]..sort(compareMachines);
    expect(merged.machines.map((m) => m.id), sorted.map((m) => m.id));
  });

  property('arbitrary bytes never decode or throw', (tc) {
    final bytes = tc.draw(binaryOrJson, name: 'bytes');
    expect(() => decodeSnapshot(bytes, host: _host, port: null), returnsNormally);
  });

  test('extra keys, versions and oversized files are refused', () {
    final good =
        jsonDecode(utf8.decode(encodeSnapshot(_snapshot(const [], 1)))) as Map<String, Object?>;
    for (final changed in [
      {...good, 'token': 'x'},
      {...good, 'version': 2},
      {...good, 'saved_at': -1},
      {
        ...good,
        'machines': [
          {'id': 'x', 'terminal': 'bytes'},
        ],
      },
    ]) {
      expect(decodeSnapshot(utf8.encode(jsonEncode(changed)), host: _host, port: null), isNull);
    }
    expect(
      decodeSnapshot(List<int>.filled(maximumSnapshotBytes + 1, 0x20), host: _host, port: null),
      isNull,
    );
  });

  test('a single machine update applies only when it is newer', () {
    final row = decodeMachine({
      'id': '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1',
      'name': 'dev-box',
      'desired_state': 'running',
      'observed_state': 'running',
      'permissions': {'read': true},
    });
    final snapshot = _snapshot([row], 10);
    final stopped = decodeMachine({
      'id': row.id,
      'name': 'dev-box',
      'desired_state': 'stopped',
      'observed_state': 'stopped',
      'permissions': {'read': true},
    });
    expect(
      updateSnapshotMachine(snapshot, stopped, DateTime.utc(2026, 10, 18, 12, 9)),
      same(snapshot),
    );
    final updated = updateSnapshotMachine(snapshot, stopped, DateTime.utc(2026, 10, 18, 12, 11));
    expect(updated.machines.single.observed, ObservedState.stopped);
  });
}

/// Random bytes, or JSON shaped like a snapshot with arbitrary values.
final Generator<List<int>> binaryOrJson = oneOf<List<int>>([
  bytes(maxLength: 64),
  text(maxLength: 64).map(
    (t) => utf8.encode('{"version":1,"host":"$_host","port":null,"saved_at":0,"machines":[$t]}'),
  ),
]);
