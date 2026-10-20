import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../l10n/app_localizations.dart';
import '../ui/theme.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'machines/machines_controller.dart';
import 'machines/machines_screen.dart';
import 'routes.dart';
import 'session.dart';

/// Opens an approval link outside Mila. Overridden per platform.
final openExternalProvider = Provider<Future<void> Function(Uri)>((ref) => (uri) async {});

/// Navigation `extra` asking the sign-in screen to start at once, as adding a
/// deployment does. A restored or typed URL never carries it.
final class SignInAutoStart {
  const SignInAutoStart();
}

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key, required this.deployment, this.autoStart = false});

  final Deployment deployment;

  /// Start signing in when shown, if no sign-in is under way.
  final bool autoStart;

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.autoStart) {
      // After the first frame, so this screen's listener sees every phase,
      // including the approval link it opens in the browser.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final controller = ref.read(signInProvider(widget.deployment).notifier);
        if (ref.read(signInProvider(widget.deployment)).flow.phase == SignInPhase.idle) {
          unawaited(controller.start());
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final deployment = widget.deployment;
    final l = MilaLocalizations.of(context);
    final view = ref.watch(signInProvider(deployment));
    final controller = ref.read(signInProvider(deployment).notifier);
    ref.listen(signInProvider(deployment), (previous, next) {
      // Each new approval link opens once in the system browser; the button
      // below reopens it. A failure to launch leaves the button as the path.
      final link = next.flow.showsLink ? next.flow.approvalUrl : null;
      if (link != null && previous?.flow.approvalUrl != link) {
        unawaited(ref.read(openExternalProvider)(link).catchError((Object _) {}));
      }
      if (next.flow.phase == SignInPhase.signedIn && previous?.flow.phase != SignInPhase.signedIn) {
        context.go(machinesPath(deployment));
      }
    });
    final flow = view.flow;
    final saved = ref.watch(savedSnapshotProvider(deployment)).value;
    final body = switch (flow.phase) {
      SignInPhase.idle => [
        ConsoleButton(
          key: const Key('sign-in-start'),
          label: l.signInStart,
          glyph: Glyph.arrowUpRight,
          onPressed: controller.start,
        ),
      ],
      SignInPhase.connecting => [
        Text(l.signInConnecting(deployment.toString()), key: const Key('sign-in-connecting')),
      ],
      SignInPhase.awaitingApproval => [
        Text(l.signInApprove),
        const SizedBox(height: MonoScale.line),
        Kv(
          l.signInFingerprint,
          SelectableText(
            flow.fingerprint ?? '',
            key: const Key('sign-in-fingerprint'),
            textDirection: TextDirection.ltr,
          ),
        ),
        const SizedBox(height: MonoScale.line),
        ConsoleButton(
          key: const Key('sign-in-open'),
          label: l.signInOpenBrowser,
          glyph: Glyph.arrowUpRight,
          onPressed: flow.showsLink
              ? () => ref.read(openExternalProvider)(flow.approvalUrl!)
              : null,
        ),
      ],
      SignInPhase.signedIn => [
        ..._account(context, flow),
        ConsoleButton(
          key: const Key('sign-in-open-machines'),
          label: l.signInOpenMachines,
          glyph: Glyph.arrowRight,
          onPressed: () => context.go(machinesPath(deployment)),
        ),
        const SizedBox(height: MonoScale.line / 2),
        ConsoleButton(
          key: const Key('sign-in-sign-out'),
          label: l.signInSignOut,
          onPressed: controller.signOut,
        ),
      ],
      SignInPhase.disconnected => [
        Text(l.signInDisconnected, key: const Key('sign-in-disconnected')),
        const SizedBox(height: MonoScale.line),
        ..._account(context, flow),
        ConsoleButton(
          key: const Key('sign-in-reconnect'),
          label: l.signInReconnect,
          glyph: Glyph.arrowRight,
          onPressed: controller.start,
        ),
        const SizedBox(height: MonoScale.line / 2),
        ConsoleButton(
          key: const Key('sign-in-sign-out'),
          label: l.signInSignOut,
          onPressed: controller.signOut,
        ),
      ],
      SignInPhase.expired => [
        Text(l.signInExpired, key: const Key('sign-in-expired')),
        const SizedBox(height: MonoScale.line),
        ConsoleButton(label: l.retry, onPressed: controller.start),
      ],
      SignInPhase.failed => [
        Text(switch (flow.failure) {
          SignInFailure.hostUntrusted => l.signInFailedHost,
          SignInFailure.refused => l.signInFailedRefused,
          SignInFailure.unreachable => l.signInFailedUnreachable,
          SignInFailure.protocol || null => l.signInFailedProtocol,
        }, key: const Key('sign-in-failed')),
        const SizedBox(height: MonoScale.line),
        ConsoleButton(label: l.retry, onPressed: controller.start),
      ],
    };
    return Scaffold(
      appBar: AppBar(
        leading: TextButton(
          onPressed: () => context.go(deploymentsPath),
          child: BackGlyph(label: l.back),
        ),
        title: Text(l.signInTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.all(MonoScale.fontSize),
        children: [
          Text(deployment.toString(), textDirection: TextDirection.ltr),
          const SizedBox(height: MonoScale.line),
          ...body,
          if (saved != null && flow.phase != SignInPhase.signedIn) ...[
            const SizedBox(height: MonoScale.line),
            ConsoleButton(
              key: const Key('sign-in-saved-list'),
              label: l.machinesTitle,
              glyph: Glyph.arrowRight,
              onPressed: () => context.go(machinesPath(deployment)),
            ),
            Text(
              l.machinesSavedAt(formatSavedAt(saved.savedAt)),
              style: TextStyle(color: MonoTheme.of(context).textAlt),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _account(BuildContext context, SignIn flow) {
    final email = flow.email;
    if (email == null) return const [];
    return [
      Kv(
        MilaLocalizations.of(context).signInAccount,
        Text(email, key: const Key('sign-in-account'), textDirection: TextDirection.ltr),
      ),
      const SizedBox(height: MonoScale.line),
    ];
  }
}
