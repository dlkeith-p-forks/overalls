/// Canonical `overalls://HOST/PATH` application routes (ADR-0221).
///
/// A port of `OverallsProtocol.AppRoute`; both sides are tested against
/// `protocol/test/fixtures/app_routes.json`. The table is closed, every
/// identifier is a canonical UUID and routes never carry a secret.
library;

import 'dart:convert';

import 'workspace_source.dart';

const String _scheme = 'overalls://';
const int _maximumBytes = 2048;

final RegExp _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
final RegExp _label = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
final RegExp _port = RegExp(r'^[1-9][0-9]{0,4}$');
final RegExp _forbidden = RegExp(r'[\x00-\x20\x7f]');

/// Whether [value] is a lowercase canonical UUID.
bool isCanonicalUuid(String value) => value.length == 36 && _uuid.hasMatch(value);

/// Whether [name] is a lowercase DNS host name, as `SSHHostCertificate.hostname?`.
bool isHostname(String name) {
  final bytes = utf8.encode(name).length;
  return bytes >= 1 && bytes <= 253 && name.split('.').every(_label.hasMatch);
}

/// A page inside a deployment. Each subtype is one row of the closed table.
sealed class MilaPage {
  const MilaPage();

  /// The canonical path, including any query, beginning with `/`.
  String get path;

  /// The page as the shared fixtures describe it.
  Map<String, Object?> describe();
}

final class MachinesPage extends MilaPage {
  const MachinesPage();
  @override
  String get path => '/machines';
  @override
  Map<String, Object?> describe() => {'page': 'machines'};
  @override
  bool operator ==(Object other) => other is MachinesPage;
  @override
  int get hashCode => (MachinesPage).hashCode;
}

final class ThreadsPage extends MilaPage {
  const ThreadsPage();
  @override
  String get path => '/threads';
  @override
  Map<String, Object?> describe() => {'page': 'threads'};
  @override
  bool operator ==(Object other) => other is ThreadsPage;
  @override
  int get hashCode => (ThreadsPage).hashCode;
}

final class SettingsPage extends MilaPage {
  const SettingsPage();
  @override
  String get path => '/settings';
  @override
  Map<String, Object?> describe() => {'page': 'settings'};
  @override
  bool operator ==(Object other) => other is SettingsPage;
  @override
  int get hashCode => (SettingsPage).hashCode;
}

/// The machine sub-pages addressed by `/machines/:id[/tab]`.
enum MachineTab {
  overview('machine', ''),
  info('machine_info', '/info'),
  web('machine_web', '/web'),
  terminals('machine_terminals', '/terminals'),
  threads('machine_threads', '/threads');

  const MachineTab(this.wire, this.suffix);

  /// The fixture page name.
  final String wire;

  /// The path suffix after the machine id.
  final String suffix;
}

final class MachinePage extends MilaPage {
  const MachinePage(this.machineId, [this.tab = MachineTab.overview]);
  final String machineId;
  final MachineTab tab;
  @override
  String get path => '/machines/$machineId${tab.suffix}';
  @override
  Map<String, Object?> describe() => {'page': tab.wire, 'machine_id': machineId};
  @override
  bool operator ==(Object other) =>
      other is MachinePage && other.machineId == machineId && other.tab == tab;
  @override
  int get hashCode => Object.hash(machineId, tab);
}

final class MachineTerminalPage extends MilaPage {
  const MachineTerminalPage(this.machineId, this.sessionId);
  final String machineId;
  final String sessionId;
  @override
  String get path => '/machines/$machineId/terminals/$sessionId';
  @override
  Map<String, Object?> describe() => {
    'page': 'machine_terminal',
    'machine_id': machineId,
    'session_id': sessionId,
  };
  @override
  bool operator ==(Object other) =>
      other is MachineTerminalPage && other.machineId == machineId && other.sessionId == sessionId;
  @override
  int get hashCode => Object.hash(machineId, sessionId, 'terminal');
}

final class MachineThreadPage extends MilaPage {
  const MachineThreadPage(this.machineId, this.threadId);
  final String machineId;
  final String threadId;
  @override
  String get path => '/machines/$machineId/threads/$threadId';
  @override
  Map<String, Object?> describe() => {
    'page': 'machine_thread',
    'machine_id': machineId,
    'thread_id': threadId,
  };
  @override
  bool operator ==(Object other) =>
      other is MachineThreadPage && other.machineId == machineId && other.threadId == threadId;
  @override
  int get hashCode => Object.hash(machineId, threadId, 'thread');
}

final class ThreadPage extends MilaPage {
  const ThreadPage(this.threadId);
  final String threadId;
  @override
  String get path => '/threads/$threadId';
  @override
  Map<String, Object?> describe() => {'page': 'thread', 'thread_id': threadId};
  @override
  bool operator ==(Object other) => other is ThreadPage && other.threadId == threadId;
  @override
  int get hashCode => Object.hash(threadId, 'thread_page');
}

/// Opens the create-machine flow prefilled with a repository. Never creates
/// a machine without confirmation.
final class LaunchPage extends MilaPage {
  const LaunchPage(this.source);
  final WorkspaceSource source;
  @override
  String get path => '/launch?source=${encodeWwwForm(source.toUrl())}';
  @override
  Map<String, Object?> describe() => {'page': 'launch', 'source': source.toUrl()};
  @override
  bool operator ==(Object other) => other is LaunchPage && other.source == source;
  @override
  int get hashCode => Object.hash(source, 'launch');
}

final class SshApprovedPage extends MilaPage {
  const SshApprovedPage(this.sessionId);
  final String sessionId;
  @override
  String get path => '/ssh/approved?session=$sessionId';
  @override
  Map<String, Object?> describe() => {'page': 'ssh_approved', 'session_id': sessionId};
  @override
  bool operator ==(Object other) => other is SshApprovedPage && other.sessionId == sessionId;
  @override
  int get hashCode => Object.hash(sessionId, 'ssh_approved');
}

/// A deployment host, optional port and page.
final class MilaRoute {
  const MilaRoute({required this.host, required this.page, this.port});

  final String host;

  /// Null means the default HTTPS port.
  final int? port;
  final MilaPage page;

  /// The canonical link for this route.
  String format() => '$_scheme${port == null ? host : '$host:$port'}${page.path}';

  /// The route as the shared fixtures describe it.
  Map<String, Object?> describe() => {'host': host, 'port': port, ...page.describe()};

  @override
  bool operator ==(Object other) =>
      other is MilaRoute && other.host == host && other.port == port && other.page == page;

  @override
  int get hashCode => Object.hash(host, port, page);

  @override
  String toString() => format();
}

// @cc [owner:ghuntley,label:security;protocol] mila-app-route-closed-table
// Mila MUST accept exactly the routes `OverallsProtocol.AppRoute` accepts:
// bounded to 2 KiB, no userinfo, fragments, percent-encoded paths, unknown
// query keys or non-canonical identifiers. Parsing MUST NOT throw.
/// Parses [value] against the closed table, or returns null.
MilaRoute? parseMilaRoute(String value) {
  if (_hasLoneSurrogate(value) || utf8.encode(value).length > _maximumBytes) return null;
  if (value.contains('#') || _forbidden.hasMatch(value) || !value.startsWith(_scheme)) {
    return null;
  }
  final rest = value.substring(_scheme.length);
  final queryAt = rest.indexOf('?');
  final location = queryAt < 0 ? rest : rest.substring(0, queryAt);
  final query = queryAt < 0 ? null : rest.substring(queryAt + 1);
  if (location.contains('%') || location.contains('@')) return null;
  final segments = location.split('/');
  final authority = _authority(segments.first);
  if (authority == null) return null;
  final page = _page(segments.sublist(1), query);
  if (page == null) return null;
  return MilaRoute(host: authority.$1, port: authority.$2, page: page);
}

(String, int?)? _authority(String authority) {
  final parts = authority.split(':');
  if (parts.length == 1) return isHostname(parts[0]) ? (parts[0], null) : null;
  if (parts.length != 2 || !isHostname(parts[0]) || !_port.hasMatch(parts[1])) return null;
  final port = int.parse(parts[1]);
  return port <= 65535 ? (parts[0], port) : null;
}

MilaPage? _page(List<String> segments, String? query) {
  if (query == null) {
    return switch (segments) {
      ['machines'] => const MachinesPage(),
      ['threads'] => const ThreadsPage(),
      ['settings'] => const SettingsPage(),
      ['machines', final id] => _uuidPage(id, (id) => MachinePage(id)),
      ['machines', final id, 'info'] => _uuidPage(id, (id) => MachinePage(id, MachineTab.info)),
      ['machines', final id, 'web'] => _uuidPage(id, (id) => MachinePage(id, MachineTab.web)),
      ['machines', final id, 'terminals'] => _uuidPage(
        id,
        (id) => MachinePage(id, MachineTab.terminals),
      ),
      ['machines', final id, 'threads'] => _uuidPage(
        id,
        (id) => MachinePage(id, MachineTab.threads),
      ),
      ['machines', final id, 'terminals', final session] =>
        isCanonicalUuid(id) && isCanonicalUuid(session) ? MachineTerminalPage(id, session) : null,
      ['machines', final id, 'threads', final thread] =>
        isCanonicalUuid(id) && isCanonicalUuid(thread) ? MachineThreadPage(id, thread) : null,
      ['threads', final id] => _uuidPage(id, ThreadPage.new),
      _ => null,
    };
  }
  switch (segments) {
    case ['launch']:
      final url = _singleQuery(query, 'source');
      if (url == null) return null;
      return switch (parseWorkspaceSource(url)) {
        SourceAccepted(:final source) => LaunchPage(source),
        SourceRefused() => null,
      };
    case ['ssh', 'approved']:
      final session = _singleQuery(query, 'session');
      return session == null ? null : _uuidPage(session, SshApprovedPage.new);
  }
  return null;
}

MilaPage? _uuidPage(String id, MilaPage Function(String) build) =>
    isCanonicalUuid(id) ? build(id) : null;

String? _singleQuery(String query, String key) {
  final equals = query.indexOf('=');
  if (equals < 0 || query.substring(0, equals) != key) return null;
  final encoded = query.substring(equals + 1);
  if (encoded.contains('&') || encoded.contains('=')) return null;
  final value = decodeWwwForm(encoded);
  return value == null || value.isEmpty ? null : value;
}

bool _hasLoneSurrogate(String value) {
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (i + 1 >= value.length) return true;
      final next = value.codeUnitAt(i + 1);
      if (next < 0xDC00 || next > 0xDFFF) return true;
      i++;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      return true;
    }
  }
  return false;
}

bool _unreserved(int byte) =>
    (byte >= 0x41 && byte <= 0x5A) ||
    (byte >= 0x61 && byte <= 0x7A) ||
    (byte >= 0x30 && byte <= 0x39) ||
    byte == 0x2D ||
    byte == 0x2E ||
    byte == 0x5F ||
    byte == 0x7E;

/// Encodes as Elixir's `URI.encode_www_form/1`: unreserved bytes pass, space
/// becomes `+`, and everything else is uppercase percent-encoded UTF-8.
String encodeWwwForm(String value) {
  final out = StringBuffer();
  for (final byte in utf8.encode(value)) {
    if (_unreserved(byte)) {
      out.writeCharCode(byte);
    } else if (byte == 0x20) {
      out.write('+');
    } else {
      out
        ..write('%')
        ..write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return out.toString();
}

/// Decodes as Elixir's `URI.decode_www_form/1`, returning null for malformed
/// escapes or invalid UTF-8 instead of throwing.
String? decodeWwwForm(String encoded) {
  final bytes = <int>[];
  final input = utf8.encode(encoded);
  for (var i = 0; i < input.length; i++) {
    final byte = input[i];
    if (byte == 0x2B) {
      bytes.add(0x20);
    } else if (byte == 0x25) {
      if (i + 2 >= input.length) return null;
      final high = _hex(input[i + 1]);
      final low = _hex(input[i + 2]);
      if (high == null || low == null) return null;
      bytes.add(high * 16 + low);
      i += 2;
    } else {
      bytes.add(byte);
    }
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

int? _hex(int byte) {
  if (byte >= 0x30 && byte <= 0x39) return byte - 0x30;
  if (byte >= 0x41 && byte <= 0x46) return byte - 0x37;
  if (byte >= 0x61 && byte <= 0x66) return byte - 0x57;
  return null;
}
