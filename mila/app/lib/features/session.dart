// Deployments and sign-in: owns the one Porsche connection per deployment
// and drives the pure `SignIn` state machine from transport events.
import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import 'preferences.dart';

/// The transport. Overridden at startup (real SSH) and in tests (fake).
final connectorProvider = Provider<PorscheConnector>(
  (ref) => throw UnimplementedError('connectorProvider must be overridden'),
);

/// The wall clock, injectable so expiry is testable.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// How often a pending approval re-checks `whoami`.
const Duration approvalPollInterval = Duration(seconds: 2);

/// The deployments the user has added, in the order added.
final deploymentsProvider = NotifierProvider<DeploymentsNotifier, List<Deployment>>(
  DeploymentsNotifier.new,
);

const String _deploymentsKey = 'deployments';

final class DeploymentsNotifier extends Notifier<List<Deployment>> {
  @override
  List<Deployment> build() {
    unawaited(_load());
    return const [];
  }

  /// Restores the saved list ahead of anything added meanwhile. Saved
  /// entries are re-validated: an unparseable one is dropped.
  Future<void> _load() async {
    final preferences = ref.read(preferencesProvider.notifier);
    await preferences.loaded;
    final saved = ref.read(preferencesProvider)?[_deploymentsKey];
    if (saved is! List<Object?>) return;
    final restored = <Deployment>[
      for (final entry in saved)
        if (entry is String) ?parseDeployment(entry),
    ];
    final merged = <Deployment>[
      for (final d in restored)
        if (!state.contains(d)) d,
      ...state,
    ];
    state = List.unmodifiable(merged.toSet().toList());
  }

  Future<void> _save() => ref.read(preferencesProvider.notifier).put(_deploymentsKey, [
    for (final d in state) d.toString(),
  ]);

  /// Adds [deployment] once; returns false if it was already present.
  bool add(Deployment deployment) {
    if (state.contains(deployment)) return false;
    state = List.unmodifiable([...state, deployment]);
    unawaited(_save());
    return true;
  }

  void remove(Deployment deployment) {
    state = List.unmodifiable(state.where((d) => d != deployment));
    unawaited(_save());
  }

  /// The deployment a link's host and port name, if added.
  Deployment? forRoute(MilaRoute route) {
    for (final d in state) {
      if (d.host == route.host && d.port == route.port) return d;
    }
    return null;
  }
}

/// Sign-in state plus the live session once connected.
final class SignInView {
  const SignInView(this.flow, [this.session]);
  final SignIn flow;
  final PorscheSession? session;
}

final signInProvider = NotifierProvider.family<SignInController, SignInView, Deployment>(
  SignInController.new,
);

final class SignInController extends Notifier<SignInView> {
  SignInController(this.deployment);

  final Deployment deployment;
  Timer? _poll;
  Timer? _tick;

  @override
  SignInView build() {
    ref.onDispose(_stopTimers);
    return const SignInView(SignIn.initial());
  }

  void _stopTimers() {
    _poll?.cancel();
    _tick?.cancel();
  }

  void _apply(SignInEvent event, [PorscheSession? session]) {
    final next = state.flow.apply(event);
    // Only a live phase holds a connection; the rest have none to offer.
    final keep = switch (next.phase) {
      SignInPhase.connecting ||
      SignInPhase.awaitingApproval ||
      SignInPhase.signedIn => session ?? state.session,
      _ => null,
    };
    state = SignInView(next, keep);
  }

  /// Starts (or restarts) sign-in on a fresh connection.
  Future<void> start() async {
    _stopTimers();
    await state.session?.close();
    _apply(const StartSignIn());
    final generation = state.flow.generation;
    final PorscheSession session;
    try {
      session = await ref.read(connectorProvider).connect(deployment, generation: generation);
    } on ConnectException catch (e) {
      _apply(
        e.failure == ConnectFailure.hostUntrusted
            ? HostRejected(generation)
            : Unreachable(generation),
      );
      return;
    }
    _apply(Connected(generation), session);
    unawaited(
      session.closed.then((_) {
        if (!ref.mounted || state.flow.generation != generation) return;
        _stopTimers();
        _apply(Disconnected(generation));
      }),
    );
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      _apply(Tick(ref.read(clockProvider)()));
    });
    await _whoami(session);
  }

  /// Ends the session on this device. Keys and the deployment's approval are
  /// unchanged, so signing in again needs no new approval.
  Future<void> signOut() async {
    _stopTimers();
    final session = state.session;
    _apply(const SignOut());
    await session?.close();
  }

  Future<void> _whoami(PorscheSession session) async {
    final outcome = await session.exec(PorscheCommand('whoami', options: const {'json': true}));
    _apply(WhoamiFinished(session.generation, outcome, ref.read(clockProvider)()));
    final flow = state.flow;
    if (flow.phase == SignInPhase.awaitingApproval && flow.generation == session.generation) {
      _poll = Timer(approvalPollInterval, () => unawaited(_whoami(session)));
    } else if (flow.phase != SignInPhase.signedIn) {
      _tick?.cancel();
    }
  }
}

/// The signed-in session for [deployment], or null.
final sessionProvider = Provider.family<PorscheSession?, Deployment>((ref, deployment) {
  final view = ref.watch(signInProvider(deployment));
  return view.flow.phase == SignInPhase.signedIn ? view.session : null;
});

/// Request ids come from a secure source in production.
final randomProvider = Provider<Random>((ref) => Random.secure());
