// Deployments and sign-in: owns the one Porsche connection per deployment
// and drives the pure `SignIn` state machine from transport events.
import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

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

final class DeploymentsNotifier extends Notifier<List<Deployment>> {
  @override
  List<Deployment> build() => const [];

  /// Adds [deployment] once; returns false if it was already present.
  bool add(Deployment deployment) {
    if (state.contains(deployment)) return false;
    state = List.unmodifiable([...state, deployment]);
    return true;
  }

  void remove(Deployment deployment) {
    state = List.unmodifiable(state.where((d) => d != deployment));
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
    final keep = next.phase == SignInPhase.expired || next.phase == SignInPhase.failed
        ? null
        : session ?? state.session;
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
            : Disconnected(generation),
      );
      return;
    }
    _apply(Connected(generation), session);
    unawaited(session.closed.then((_) => _apply(Disconnected(generation))));
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      _apply(Tick(ref.read(clockProvider)()));
    });
    await _whoami(session);
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
