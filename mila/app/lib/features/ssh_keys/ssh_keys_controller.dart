// The account's approved SSH keys: `ssh-key list`, then `ssh-key remove`
// sent once under its own request id. Marshall decides which keys this
// account may see and revoke; a refusal is shown, never retried.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../mutation.dart';
import '../session.dart';

/// Why the last revocation did not apply.
enum SshKeyRevokeFailure { refused, failed }

final class SshKeysView {
  const SshKeysView({
    this.listing,
    this.loading = false,
    this.failed = false,
    this.revoking = false,
    this.failure,
  });

  final SshKeyListing? listing;
  final bool loading;
  final bool failed;
  final bool revoking;
  final SshKeyRevokeFailure? failure;
}

final sshKeysProvider = NotifierProvider.autoDispose
    .family<SshKeysController, SshKeysView, Deployment>(SshKeysController.new);

/// This device's key fingerprint on [Deployment], from the signed-in
/// `whoami`, or null when it is not known.
final ownKeyFingerprintProvider = Provider.family<String?, Deployment>((ref, deployment) {
  final key = ref.watch(signInProvider(deployment)).flow.publicKey;
  return key == null ? null : sshFingerprint(key);
});

final class SshKeysController extends Notifier<SshKeysView> {
  SshKeysController(this.deployment);

  final Deployment deployment;

  @override
  SshKeysView build() {
    if (ref.watch(sessionProvider(deployment)) != null) Future.microtask(refresh);
    return const SshKeysView(loading: true);
  }

  /// Reloads the listing.
  Future<void> refresh() async {
    final session = ref.read(sessionProvider(deployment));
    if (session == null) return;
    state = SshKeysView(listing: state.listing, loading: true, failure: state.failure);
    final result = await readResult(session, sshKeyListCommand());
    SshKeyListing? listing;
    try {
      listing = result == null ? null : decodeSshKeyListing(result);
    } on SshKeyFormatException {
      listing = null;
    }
    if (!ref.mounted) return;
    state = SshKeysView(
      listing: listing ?? state.listing,
      failed: listing == null,
      failure: state.failure,
    );
  }

  /// Revokes the key [keyId].
  Future<void> revoke(String keyId) async {
    final session = ref.read(sessionProvider(deployment));
    if (session == null) return;
    final random = ref.read(randomProvider);
    final command = sshKeyRemoveCommand(keyId, requestId: allocateRequestId(random));
    if (command == null) return;
    state = SshKeysView(listing: state.listing, revoking: true);
    final poll = await submitOnce(session, command, random: random);
    if (!ref.mounted) return;
    state = SshKeysView(
      listing: state.listing,
      failure: switch (poll.phase) {
        PollPhase.succeeded => null,
        PollPhase.refused => SshKeyRevokeFailure.refused,
        _ => SshKeyRevokeFailure.failed,
      },
    );
    unawaited(refresh());
  }
}
