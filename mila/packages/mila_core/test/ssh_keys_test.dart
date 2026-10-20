import 'package:mila_core/mila_core.dart';
import 'package:test/test.dart';

const String _id = '019a0f74-4e5f-7a6b-8c7d-8e9f0a1b2c3d';
const String _requestId = 'porsche-0123456789abcdef0123456789abcdef';

void main() {
  test('a listing keeps valid keys and counts refused rows', () {
    final listing = decodeSshKeyListing({
      'keys': [
        {
          'id': _id,
          'label': 'laptop',
          'algorithm': 'ssh-ed25519',
          'fingerprint': 'SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU',
          'inserted_at': '2026-10-18T09:00:00Z',
        },
        {'id': 'not-a-uuid', 'algorithm': 'ssh-ed25519', 'fingerprint': 'SHA256:x'},
        {
          'id': _id,
          'label': 'bad\nlabel',
          'algorithm': 'ssh-ed25519',
          'fingerprint': 'SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU',
        },
        'junk',
      ],
    });
    expect(listing.keys.single.label, 'laptop');
    expect(listing.keys.single.addedAt, DateTime.utc(2026, 10, 18, 9));
    expect(listing.skipped, 3);
    expect(() => decodeSshKeyListing({}), throwsA(isA<SshKeyFormatException>()));
  });

  test('the fingerprint matches OpenSSH for a known key', () {
    // SHA-256 of the one-byte blob 0x00, as OpenSSH prints it.
    expect(sshFingerprint('ssh-ed25519 '), isNull);
    expect(sshFingerprint('ssh-ed25519 !!!'), isNull);
    expect(
      sshFingerprint('ssh-ed25519 AA== comment'),
      'SHA256:bjQLnP+zepicpUTmu3gKLHiQHT+zNzh2hRGjBhevoB0',
    );
  });

  test('remove carries one canonical key id and a request id', () {
    final command = sshKeyRemoveCommand(_id, requestId: _requestId);
    expect(command, isNotNull);
    expect(encodeCommand(command!), 'ssh-key remove --json --request-id=$_requestId $_id');
    expect(sshKeyRemoveCommand('laptop', requestId: _requestId), isNull);
    expect(validateCommand(sshKeyListCommand()), isNull);
  });
}
