/// A machine's sharing as `share show --json` reports it, and the
/// `share add`/`share remove` changes Mila sends (plan M4). Marshall decides
/// who may see or change sharing; Mila only shows and asks.
library;

import 'dart:convert';

import 'app_route.dart';
import 'ssh_command.dart';

/// The access a grant gives, as Porsche names it on the line.
enum ShareRole { viewer, operator, manager }

/// Why a sharing result could not be decoded.
final class ShareFormatException implements Exception {
  const ShareFormatException(this.field);
  final String field;
  @override
  String toString() => 'ShareFormatException($field)';
}

/// One account's grant on a machine.
final class ShareGrant {
  const ShareGrant({required this.userId, required this.email, required this.role});

  final String userId;

  /// An identifier, shown left to right.
  final String email;
  final ShareRole role;
}

/// One page of a machine's sharing.
final class ShareListing {
  const ShareListing({
    required this.ownerEmail,
    required this.grants,
    this.nextCursor,
    this.skipped = 0,
  });

  final String ownerEmail;
  final List<ShareGrant> grants;

  /// The `--after` value for the next page, when there is one.
  final String? nextCursor;

  /// Rows refused by strict identity decoding.
  final int skipped;
}

final RegExp _control = RegExp(r'[\x00-\x1f\x7f\x80-\x9f  ]');

/// Whether [value] is an email Mila may send: one `@` with text on both
/// sides, no whitespace or control characters, at most 320 bytes. Marshall
/// decides whether an account has it.
bool isShareEmail(String value) {
  if (value.isEmpty || utf8.encode(value).length > 320) return false;
  if (_control.hasMatch(value) || value.contains(RegExp(r'\s'))) return false;
  final at = value.indexOf('@');
  return at > 0 && at == value.lastIndexOf('@') && at < value.length - 1;
}

String? _email(Object? value) => value is String && isShareEmail(value) ? value : null;

ShareRole? _role(Object? value) => switch (value) {
  'viewer' => ShareRole.viewer,
  'operator' => ShareRole.operator,
  'manager' => ShareRole.manager,
  _ => null,
};

/// Decodes `share show --json`: the owner and items are required; a grant
/// with a bad id, email or role is skipped and counted; unknown keys are
/// ignored.
ShareListing decodeShareListing(Map<String, Object?> result) {
  final owner = result['owner'];
  if (owner is! Map<String, Object?>) throw const ShareFormatException('owner');
  final ownerEmail = _email(owner['email']);
  if (ownerEmail == null) throw const ShareFormatException('owner.email');
  final items = result['items'];
  if (items is! List<Object?>) throw const ShareFormatException('items');
  final grants = <ShareGrant>[];
  var skipped = 0;
  for (final item in items) {
    if (item is! Map<String, Object?>) {
      skipped++;
      continue;
    }
    final userId = item['user_id'];
    final email = _email(item['email']);
    final role = _role(item['role']);
    if (userId is! String || !isCanonicalUuid(userId) || email == null || role == null) {
      skipped++;
      continue;
    }
    grants.add(ShareGrant(userId: userId, email: email, role: role));
  }
  final cursor = result['next_cursor'];
  return ShareListing(
    ownerEmail: ownerEmail,
    grants: List.unmodifiable(grants),
    nextCursor: cursor is String && isCanonicalUuid(cursor) ? cursor : null,
    skipped: skipped,
  );
}

/// `share show`, optionally after a cursor.
PorscheCommand shareShowCommand(String machineId, {String? after}) =>
    PorscheCommand('share show', arguments: [machineId], options: {'json': true, 'after': ?after});

/// `share add`, or null when the email would be refused.
PorscheCommand? shareAddCommand(
  String machineId,
  String email,
  ShareRole role, {
  required String requestId,
}) {
  if (!isShareEmail(email)) return null;
  final command = PorscheCommand(
    'share add',
    arguments: [machineId, email, role.name],
    options: {'json': true, 'request-id': requestId},
  );
  return validateCommand(command) == null ? command : null;
}

/// `share remove`, or null when the email would be refused.
PorscheCommand? shareRemoveCommand(String machineId, String email, {required String requestId}) {
  if (!isShareEmail(email)) return null;
  final command = PorscheCommand(
    'share remove',
    arguments: [machineId, email],
    options: {'json': true, 'request-id': requestId},
  );
  return validateCommand(command) == null ? command : null;
}
