import 'dart:convert';
import 'dart:io';

import 'package:hegel/hegel.dart';
import 'package:mila_core/src/app_route.dart';
import 'package:mila_core/src/workspace_source.dart';
import 'package:test/test.dart';

/// Shared with `OverallsProtocol.AppRouteTest`.
final File _vectors = File('../../../protocol/test/fixtures/app_routes.json');

const List<String> _sourceUrls = [
  'https://github.com/ghuntley/overalls',
  'https://gitlab.com/group/sub/project/-/merge_requests/7',
  'https://codeberg.org/owner/repo/src/branch/main',
  'https://bitbucket.org/team/repo/commits/0123456789abcdef0123456789abcdef01234567',
];

String _canonicalJson(Map<String, Object?> value) {
  final keys = value.keys.toList()..sort();
  return jsonEncode({for (final key in keys) key: value[key]});
}

final Generator<String> _hexByte = integers(
  min: 0,
  max: 255,
).map((byte) => byte.toRadixString(16).padLeft(2, '0'));

final Generator<String> _uuidGen = lists(_hexByte, minLength: 16, maxLength: 16).map((bytes) {
  final hex = bytes.join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
});

final Generator<String> _host = lists(
  fromRegex(r'[a-z0-9][a-z0-9]{0,10}', fullMatch: true),
  minLength: 1,
  maxLength: 4,
).map((labels) => labels.join('.'));

final Generator<MilaPage> _page = oneOf<MilaPage>([
  sampledFrom<MilaPage>(const [MachinesPage(), ThreadsPage(), SettingsPage()]),
  tuple2(_uuidGen, sampledFrom(MachineTab.values)).map((pair) => MachinePage(pair.$1, pair.$2)),
  tuple2(_uuidGen, _uuidGen).map((pair) => MachineTerminalPage(pair.$1, pair.$2)),
  tuple2(_uuidGen, _uuidGen).map((pair) => MachineThreadPage(pair.$1, pair.$2)),
  _uuidGen.map(ThreadPage.new),
  _uuidGen.map(SshApprovedPage.new),
  sampledFrom(
    _sourceUrls,
  ).map((url) => LaunchPage((parseWorkspaceSource(url) as SourceAccepted).source)),
]);

final Generator<MilaRoute> _route = tuple2(
  tuple2(_host, oneOf<int?>([just<int?>(null), integers(min: 1, max: 65535)])),
  _page,
).map((value) => MilaRoute(host: value.$1.$1, port: value.$1.$2, page: value.$2));

void main() {
  final document = jsonDecode(_vectors.readAsStringSync()) as Map<String, Object?>;

  test('shared vectors accept and canonicalise the same links as the server', () {
    expect(document['version'], 1);
    final accepted = (document['accepted']! as List<Object?>).cast<Map<String, Object?>>();
    expect(accepted, isNotEmpty);
    for (final entry in accepted) {
      final input = entry['input']! as String;
      final route = parseMilaRoute(input);
      expect(route, isNotNull, reason: input);
      expect(route!.format(), entry['canonical'], reason: input);
      expect(
        _canonicalJson(route.describe()),
        _canonicalJson(entry['route']! as Map<String, Object?>),
        reason: input,
      );
      expect(parseMilaRoute(route.format()), route, reason: input);
    }
  });

  test('shared vectors refuse the same links as the server', () {
    final refused = (document['refused']! as List<Object?>).cast<String>();
    expect(refused, isNotEmpty);
    for (final input in refused) {
      expect(parseMilaRoute(input), isNull, reason: jsonEncode(input));
    }
  });

  test('oversized and lone-surrogate input is refused', () {
    expect(parseMilaRoute('overalls://overalls.example/launch?source=${'a' * 2048}'), isNull);
    expect(parseMilaRoute('overalls://overalls.example/machines\uD800'), isNull);
  });

  test('www-form encoding matches the server alphabet', () {
    expect(encodeWwwForm('a b/c~d'), 'a+b%2Fc~d');
    expect(decodeWwwForm('a+b%2Fc~d'), 'a b/c~d');
    expect(decodeWwwForm('%ZZ'), isNull);
    expect(decodeWwwForm('%2'), isNull);
    expect(decodeWwwForm('%FF'), isNull);
  });

  property('formatted routes parse back to the same route', (tc) {
    final route = tc.draw(_route, name: 'route');
    final link = route.format();
    expect(utf8.encode(link).length, lessThanOrEqualTo(2048));
    expect(parseMilaRoute(link), route);
  });

  property('arbitrary and mutated input never throws', (tc) {
    final input = tc.draw(
      oneOf<String>([
        text(maxLength: 96),
        tuple2(_route, tuple2(integers(min: 0, max: 200), integers(min: 0, max: 255))).map((value) {
          final link = value.$1.format();
          final at = value.$2.$1.clamp(0, link.length);
          return link.substring(0, at) + String.fromCharCode(value.$2.$2) + link.substring(at);
        }),
      ]),
      name: 'input',
    );
    final route = parseMilaRoute(input);
    if (route != null) expect(parseMilaRoute(route.format()), route);
  });

  property('appending a fragment, query key or segment refuses the route', (tc) {
    final route = tc.draw(_route, name: 'route');
    final suffix = tc.draw(sampledFrom(const ['#x', '/extra', '/', '&x=1']), name: 'suffix');
    // A launch source is a provider URL, so a path suffix can name another repository path.
    tc.assume(!(route.page is LaunchPage && (suffix == '/extra' || suffix == '/')));
    var link = route.format();
    if (suffix == '&x=1' && !link.contains('?')) link = '$link?x=1';
    expect(parseMilaRoute(link + suffix), isNull);
  });

  property('links never carry userinfo or a fragment', (tc) {
    final link = tc.draw(_route, name: 'route').format();
    expect(link.contains('@'), isFalse);
    expect(link.contains('#'), isFalse);
  });
}
