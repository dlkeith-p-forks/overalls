import 'package:hegel/hegel.dart';
import 'package:mila_core/mila_core.dart';
import 'package:test/test.dart';

const String _id = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';
const String _user = '6f1e2d3c-4b5a-4987-8a6b-5c4d3e2f1a0b';
const String _grant = '9a8b7c6d-5e4f-4a3b-9c2d-1e0f9a8b7c6d';
const String _request = 'porsche-0123456789abcdef0123456789abcdef';

/// The `share show` result shape Marshall's commands test pins
/// (`marshall/test/marshall/ssh/commands_test.exs`, "share show").
Map<String, Object?> _result({List<Object?>? items, Object? cursor}) => {
  'owner': {'user_id': _user, 'email': 'owner@example.com', 'role': 'owner'},
  'items':
      items ??
      [
        {'id': _grant, 'user_id': _user, 'email': 'member@example.com', 'role': 'manager'},
      ],
  'next_cursor': cursor,
};

void main() {
  test('share show decodes the owner, grants and cursor', () {
    final listing = decodeShareListing(_result(cursor: _grant));
    expect(listing.ownerEmail, 'owner@example.com');
    expect(listing.grants.single.email, 'member@example.com');
    expect(listing.grants.single.role, ShareRole.manager);
    expect(listing.nextCursor, _grant);
    expect(listing.skipped, 0);
  });

  test('bad grants are skipped and counted; unknown keys are ignored', () {
    final listing = decodeShareListing({
      ..._result(
        items: [
          {'user_id': 'nope', 'email': 'a@b', 'role': 'viewer'},
          {'user_id': _user, 'email': 'not-an-email', 'role': 'viewer'},
          {'user_id': _user, 'email': 'a@b', 'role': 'owner'},
          'row',
          {'user_id': _user, 'email': 'a@b', 'role': 'viewer', 'later': 1},
        ],
      ),
      'later': true,
    });
    expect(listing.skipped, 4);
    expect(listing.grants.single.role, ShareRole.viewer);
  });

  test('a result without an owner or items is refused', () {
    expect(() => decodeShareListing({'items': []}), throwsA(isA<ShareFormatException>()));
    expect(
      () => decodeShareListing({..._result(), 'items': null}),
      throwsA(isA<ShareFormatException>()),
    );
  });

  test('changes are mutations with a request id; bad emails never reach a line', () {
    expect(
      encodeCommand(shareAddCommand(_id, 'a@b.example', ShareRole.operator, requestId: _request)!),
      'share add --json --request-id=$_request $_id a@b.example operator',
    );
    expect(
      encodeCommand(shareRemoveCommand(_id, 'a@b.example', requestId: _request)!),
      'share remove --json --request-id=$_request $_id a@b.example',
    );
    for (final bad in ['', 'a', '@b', 'a@', 'a@@b', 'a b@c', 'a@b\n', 'x' * 320 + '@b']) {
      expect(shareAddCommand(_id, bad, ShareRole.viewer, requestId: _request), isNull, reason: bad);
      expect(shareRemoveCommand(_id, bad, requestId: _request), isNull, reason: bad);
    }
  });

  property('arbitrary results decode or refuse, never throw otherwise', (tc) {
    final value = tc.draw(
      sampledFrom<Object?>([null, 1, 'x', <Object?>[], <String, Object?>{}, _user, 'owner']),
      name: 'value',
    );
    final key = tc.draw(sampledFrom(const ['owner', 'items', 'next_cursor']), name: 'key');
    final inner = tc.draw(sampledFrom(const ['user_id', 'email', 'role', 'id']), name: 'inner');
    final mutated = _result();
    if (tc.draw(booleans(), name: 'deep')) {
      mutated['items'] = [
        {
          'id': _grant,
          'user_id': _user,
          'email': 'member@example.com',
          'role': 'manager',
          inner: value,
        },
      ];
    } else {
      mutated[key] = value;
    }
    try {
      final listing = decodeShareListing(mutated);
      expect(listing.grants.length + listing.skipped, lessThanOrEqualTo(1));
    } on ShareFormatException {
      // Refused, as intended.
    }
  });

  property('valid emails build commands the server grammar reads back', (tc) {
    final email = tc.draw(
      fromRegex(r'[a-z0-9._%+-]{1,40}@[a-z0-9-]{1,30}(\.[a-z]{2,6}){0,2}', fullMatch: true),
      name: 'email',
    );
    final role = tc.draw(sampledFrom(ShareRole.values), name: 'role');
    expect(isShareEmail(email), isTrue);
    for (final command in [
      shareAddCommand(_id, email, role, requestId: _request)!,
      shareRemoveCommand(_id, email, requestId: _request)!,
    ]) {
      expect(parseCommandLine(encodeCommand(command)), command);
    }
  });
}
