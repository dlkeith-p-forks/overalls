// A machine's sharing: `share show`, then `share add` and `share remove`,
// each sent once under its own request id (plan M4). Marshall decides who
// may change sharing; a refusal is shown, never retried.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mila_core/mila_core.dart';

import '../mutation.dart';
import '../session.dart';
import '../terminal/terminals_controller.dart' show MachineKey;

/// Why the last sharing change did not apply.
enum ShareChangeFailure { refused, failed }

final class SharingView {
  const SharingView({
    this.listing,
    this.loading = false,
    this.failed = false,
    this.saving = false,
    this.failure,
  });

  final ShareListing? listing;
  final bool loading;
  final bool failed;
  final bool saving;
  final ShareChangeFailure? failure;
}

final sharingProvider = NotifierProvider.autoDispose
    .family<SharingController, SharingView, MachineKey>(SharingController.new);

final class SharingController extends Notifier<SharingView> {
  SharingController(this.key);

  final MachineKey key;

  @override
  SharingView build() {
    if (ref.watch(sessionProvider(key.$1)) != null) Future.microtask(refresh);
    return const SharingView(loading: true);
  }

  Future<ShareListing?> _read({String? after}) async {
    final session = ref.read(sessionProvider(key.$1));
    if (session == null) return null;
    final result = await readResult(session, shareShowCommand(key.$2, after: after));
    try {
      return result == null ? null : decodeShareListing(result);
    } on ShareFormatException {
      return null;
    }
  }

  /// Reloads the first page.
  Future<void> refresh() async {
    final listing = await _read();
    if (!ref.mounted) return;
    state = SharingView(
      listing: listing ?? state.listing,
      failed: listing == null,
      failure: state.failure,
    );
  }

  /// Appends the next page, if there is one.
  Future<void> more() async {
    final current = state.listing;
    final cursor = current?.nextCursor;
    if (current == null || cursor == null) return;
    final page = await _read(after: cursor);
    if (!ref.mounted || page == null) return;
    state = SharingView(
      listing: ShareListing(
        ownerEmail: current.ownerEmail,
        grants: List.unmodifiable([...current.grants, ...page.grants]),
        nextCursor: page.nextCursor,
        skipped: current.skipped + page.skipped,
      ),
    );
  }

  /// Grants [email] [role]; false without sending when the email is invalid.
  Future<bool> add(String email, ShareRole role) =>
      _change((requestId) => shareAddCommand(key.$2, email, role, requestId: requestId));

  /// Revokes [email]'s grant.
  Future<bool> remove(String email) =>
      _change((requestId) => shareRemoveCommand(key.$2, email, requestId: requestId));

  Future<bool> _change(PorscheCommand? Function(String requestId) build) async {
    final session = ref.read(sessionProvider(key.$1));
    if (session == null) return false;
    final random = ref.read(randomProvider);
    final command = build(allocateRequestId(random));
    if (command == null) return false;
    state = SharingView(listing: state.listing, saving: true);
    final poll = await submitOnce(session, command, random: random);
    if (!ref.mounted) return true;
    state = SharingView(
      listing: state.listing,
      failure: switch (poll.phase) {
        PollPhase.succeeded => null,
        PollPhase.refused => ShareChangeFailure.refused,
        _ => ShareChangeFailure.failed,
      },
    );
    unawaited(refresh());
    return true;
  }
}
