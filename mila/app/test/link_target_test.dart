import 'package:flutter_test/flutter_test.dart';
import 'package:hegel/hegel.dart';
import 'package:mila/features/routes.dart';
import 'package:mila_transport/mila_transport.dart';

const Deployment _added = Deployment('overalls.example');
const Deployment _withPort = Deployment('overalls.example', port: 8443);

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

final Generator<String> _path = oneOf([
  sampledFrom(const ['/machines', '/threads', '/settings']),
  _uuid.map((id) => '/machines/$id'),
  _uuid.map((id) => '/machines/$id/info'),
  tuple2(_uuid, _uuid).map((v) => '/machines/${v.$1}/terminals/${v.$2}'),
  tuple2(_uuid, _uuid).map((v) => '/machines/${v.$1}/threads/${v.$2}'),
  _uuid.map((id) => '/machines/$id/web'),
  _uuid.map((id) => '/machines/$id/terminals'),
  _uuid.map((id) => '/machines/$id/threads'),
  _uuid.map((id) => '/threads/$id'),
  _uuid.map((id) => '/ssh/approved?session=$id'),
  just('/launch?source=https%3A%2F%2Fgithub.com%2Fghuntley%2Foveralls'),
]);

void main() {
  property('links to an added, signed-in deployment stay inside it', (tc) {
    final path = tc.draw(_path, name: 'path');
    final port = tc.draw(booleans(), name: 'port');
    final deployment = port ? _withPort : _added;
    final link = 'overalls://${deployment.host}${port ? ':8443' : ''}$path';
    final target = linkTarget(link, const [_added, _withPort], signedIn: (_) => true);
    expect(target, isA<OpenPath>());
    final opened = (target as OpenPath).path;
    expect(
      opened == settingsPath || opened.startsWith(deploymentRoot(deployment)),
      isTrue,
      reason: opened,
    );
  });

  property('links to a signed-out deployment only reach its sign-in screen', (tc) {
    final path = tc.draw(_path, name: 'path');
    final target = linkTarget('overalls://overalls.example$path', const [
      _added,
    ], signedIn: (_) => false);
    expect((target as OpenPath).path, signInPath(_added));
  });

  property('links to an unknown deployment never open a page', (tc) {
    final path = tc.draw(_path, name: 'path');
    final host = tc.draw(fromRegex(r'[a-z]{1,8}\.test', fullMatch: true), name: 'host');
    final target = linkTarget('overalls://$host$path', const [_added], signedIn: (_) => true);
    expect(target, isA<UnknownDeployment>());
  });

  property('arbitrary text is refused or opened, never thrown', (tc) {
    final input = tc.draw(text(maxLength: 80), name: 'input');
    final target = linkTarget(input, const [_added], signedIn: (_) => true);
    expect(target, isA<LinkTarget>());
  });

  test('each new page link opens its own screen', () {
    const m = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';
    const t = '6f1e2d3c-4b5a-4987-8a6b-5c4d3e2f1a0b';
    String open(String path) => (linkTarget('overalls://overalls.example$path', const [
      _added,
    ], signedIn: (_) => true) as OpenPath).path;
    expect(open('/machines/$m/threads/$t'), machineThreadPath(_added, m, t));
    expect(open('/machines/$m/terminals/$t'), machineTerminalPath(_added, m, t));
    expect(open('/threads/$t'), threadPath(_added, t));
    expect(open('/threads'), threadsPath(_added));
    expect(open('/machines/$m/web'), machineWebPath(_added, m));
    expect(open('/machines/$m/info'), machinePath(_added, m));
  });

  test('deployment entry accepts only a lowercase host and optional port', () {
    expect(parseDeployment(' Overalls.Example '), _added);
    expect(parseDeployment('overalls.example:8443'), _withPort);
    for (final bad in ['', 'http://x', 'a b', 'x:0', 'x:65536', 'user@x', '-x']) {
      expect(parseDeployment(bad), isNull, reason: bad);
    }
  });

  test('deployment segments round-trip through paths', () {
    for (final d in const [_added, _withPort]) {
      final segment = machinesPath(d).split('/')[2];
      expect(deploymentFromSegment(segment), d);
    }
  });
}
