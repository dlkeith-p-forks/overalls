import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../../l10n/app_localizations.dart';
import '../../ui/theme.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../routes.dart';
import '../session.dart';
import 'ssh_keys_controller.dart';

/// The SSH keys page of [deployment].
String sshKeysPath(Deployment deployment) =>
    '/d/${Uri.encodeComponent(deployment.toString())}/keys';

/// The account's approved SSH keys on one deployment, each revocable except
/// the key this device is signed in with.
class SshKeysScreen extends ConsumerWidget {
  const SshKeysScreen({super.key, required this.deployment});

  final Deployment deployment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = MilaLocalizations.of(context);
    final signedIn = ref.watch(sessionProvider(deployment)) != null;
    final view = ref.watch(sshKeysProvider(deployment));
    final controller = ref.read(sshKeysProvider(deployment).notifier);
    final own = ref.watch(ownKeyFingerprintProvider(deployment));
    final listing = view.listing;
    final alt = TextStyle(color: MonoTheme.of(context).textAlt);
    return Scaffold(
      appBar: AppBar(
        leading: TextButton(
          onPressed: () => context.go(settingsPath),
          child: BackGlyph(label: l.back),
        ),
        title: Text(l.sshKeysTitle),
        actions: [
          if (signedIn)
            TextButton(
              key: const Key('ssh-keys-refresh'),
              onPressed: view.loading || view.revoking ? null : controller.refresh,
              child: Text(l.refresh.toUpperCase()),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(MonoScale.fontSize),
        children: [
          Text(deployment.toString(), textDirection: TextDirection.ltr),
          const SizedBox(height: MonoScale.line / 2),
          Text(l.sshKeysExplain, style: alt),
          const SizedBox(height: MonoScale.line),
          if (!signedIn) ...[
            Text(l.sshKeysSignInFirst, key: const Key('ssh-keys-offline')),
            const SizedBox(height: MonoScale.line / 2),
            ConsoleButton(
              key: const Key('ssh-keys-sign-in'),
              label: l.signInTitle,
              glyph: Glyph.arrowRight,
              onPressed: () => context.go(signInPath(deployment)),
            ),
          ] else if (listing == null && view.failed) ...[
            Text(l.sshKeysFailed, key: const Key('ssh-keys-failed')),
            const SizedBox(height: MonoScale.line / 2),
            ConsoleButton(label: l.retry, onPressed: controller.refresh),
          ] else if (listing == null)
            Text(l.sshKeysLoading, key: const Key('ssh-keys-loading'))
          else ...[
            if (listing.keys.isEmpty) Text(l.sshKeysEmpty, key: const Key('ssh-keys-empty')),
            for (final key in listing.keys) ...[
              _KeyRow(
                entry: key,
                own: key.fingerprint == own,
                enabled: !view.revoking,
                onRevoke: () => _confirmRevoke(context, controller, key),
              ),
              const SizedBox(height: MonoScale.line / 2),
            ],
            if (view.failed) Text(l.sshKeysFailed, key: const Key('ssh-keys-failed')),
            if (view.failure != null)
              Text(switch (view.failure!) {
                SshKeyRevokeFailure.refused => l.requestRefused,
                SshKeyRevokeFailure.failed => l.requestFailed,
              }, key: const Key('ssh-key-revoke-failed')),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmRevoke(
    BuildContext context,
    SshKeysController controller,
    SshKeyEntry entry,
  ) async {
    final l = MilaLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l.sshKeyRevokeConfirm(entry.fingerprint)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.cancel.toUpperCase()),
          ),
          TextButton(
            key: const Key('confirm-ssh-key-revoke'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.sshKeyRevoke.toUpperCase()),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.revoke(entry.id);
  }
}

class _KeyRow extends StatelessWidget {
  const _KeyRow({
    required this.entry,
    required this.own,
    required this.enabled,
    required this.onRevoke,
  });

  final SshKeyEntry entry;
  final bool own;
  final bool enabled;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final l = MilaLocalizations.of(context);
    return Panel(
      key: Key('ssh-key-${entry.id}'),
      title: entry.label.isEmpty ? l.sshKeyUnlabelled : entry.label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Kv(l.sshKeyAlgorithm, Text(entry.algorithm, textDirection: TextDirection.ltr)),
          Kv(
            l.signInFingerprint,
            SelectableText(entry.fingerprint, textDirection: TextDirection.ltr),
          ),
          const SizedBox(height: MonoScale.line / 2),
          if (own)
            StatusLabel(
              l.sshKeyThisDevice,
              key: Key('ssh-key-own-${entry.id}'),
              tone: StateTone.success,
            )
          else
            ConsoleButton(
              key: Key('ssh-key-revoke-${entry.id}'),
              label: l.sshKeyRevoke,
              onPressed: enabled ? onRevoke : null,
            ),
        ],
      ),
    );
  }
}
