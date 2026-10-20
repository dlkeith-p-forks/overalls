import 'dart:io';

import 'package:hegel/hegel.dart';
import 'package:mila_transport/mila_transport.dart';
import 'package:test/test.dart';

const String _user = 'S-1-5-21-1004336348-1177238915-682003330-1001';
const String _other = 'S-1-5-21-1004336348-1177238915-682003330-1002';

void main() {
  group('device platforms', () {
    test('each platform registers under its own wire name and provider', () {
      expect(
        {for (final p in DevicePlatform.values) p.wire: p.provider.wire},
        {'ios': 'apns', 'android': 'fcm', 'macos': 'apns', 'windows': 'wns'},
      );
    });
  });

  group('owner-only DACLs', () {
    test('the written DACL is protected and owner-only', () {
      for (final directory in [true, false]) {
        final sddl = ownerOnlySddl(_user, directory: directory);
        expect(sddl, startsWith('D:P'));
        expect(sddlIsOwnerOnly(sddl, _user), isTrue);
        expect(sddlIsOwnerOnly(sddl, _other), isFalse);
      }
    });

    test('inherited, foreign or malformed DACLs are refused', () {
      expect(sddlIsOwnerOnly('D:(A;;FA;;;$_user)', _user), isFalse);
      expect(sddlIsOwnerOnly('D:PAI(A;;FA;;;$_user)(A;;FR;;;BU)', _user), isFalse);
      expect(sddlIsOwnerOnly('D:P(A;;FA;;;$_user)(A;;FR;;;WD)', _user), isFalse);
      expect(sddlIsOwnerOnly('D:P(A;;FA;;;$_user', _user), isFalse);
      expect(sddlIsOwnerOnly('D:P(A;;FA)', _user), isFalse);
      expect(sddlIsOwnerOnly('O:BAD:P(A;;FA;;;$_user)', _user), isFalse);
      // Deny entries restrict further and are accepted.
      expect(sddlIsOwnerOnly('D:PAI(D;;FA;;;WD)(A;;FA;;;$_user)(A;;FA;;;SY)', _user), isTrue);
    });

    property('an allow entry for any other SID is refused', (tc) {
      final sid = tc.draw(
        sampledFrom(const ['WD', 'BU', 'BA', 'AU', 'IU', 'CO', 'OW', _other]),
        name: 'sid',
      );
      final rights = tc.draw(sampledFrom(const ['FA', 'FR', 'FW', 'GR', '0x1']), name: 'rights');
      final before = tc.draw(booleans(), name: 'before');
      final foreign = '(A;;$rights;;;$sid)';
      final own = '(A;;FA;;;$_user)(A;;FA;;;SY)';
      final sddl = 'D:P${before ? foreign + own : own + foreign}';
      expect(sddlIsOwnerOnly(sddl, _user), isFalse);
    });
  });

  group('owner-only files on Windows', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('mila-owner-only'));
    tearDown(() => dir.delete(recursive: true));

    test('a written file is owner-only and refused once shared', () async {
      final file = await writeOwnerOnly(dir, 'a.json', const [1, 2, 3]);
      expect(await readOwnerOnly(file), const [1, 2, 3]);
      final grant = await Process.run('icacls', [file.path, '/grant', '*S-1-1-0:R']);
      expect(grant.exitCode, 0);
      expect(() => readOwnerOnly(file), throwsA(isA<FileSystemException>()));
    });
  }, testOn: 'windows');
}
