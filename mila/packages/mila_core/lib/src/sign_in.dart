/// Browser-approved sign-in over one Porsche connection (ADR-0220).
///
/// Porsche's approval link is valid only while the connection that produced
/// it stays open, for at most ten minutes. Mila therefore keeps that one
/// connection, polls `whoami` on fresh exec channels, and never shows a link
/// after the connection that minted it has gone.
library;

import 'porsche_reply.dart';

/// How long an approval link is honoured after it is issued.
const Duration approvalLifetime = Duration(seconds: 600);

/// Sign-in phases.
enum SignInPhase {
  /// No connection yet.
  idle,

  /// Connecting and verifying the host certificate.
  connecting,

  /// Waiting for the user to approve [SignIn.approvalUrl] in a browser.
  awaitingApproval,

  /// The key is approved; [SignIn.account] is known.
  signedIn,

  /// The link can no longer be used; a new connection mints a new one.
  expired,

  /// A closed failure the user must act on.
  failed,
}

/// Why sign-in failed.
enum SignInFailure { hostUntrusted, refused, protocol }

/// Inputs to the flow, produced by the transport.
sealed class SignInEvent {
  const SignInEvent();
}

/// The user asked to sign in.
final class StartSignIn extends SignInEvent {
  const StartSignIn();
}

/// The connection numbered [generation] opened and its host certificate verified.
final class Connected extends SignInEvent {
  const Connected(this.generation);
  final int generation;
}

/// Host verification failed; there is no unsigned fallback.
final class HostRejected extends SignInEvent {
  const HostRejected(this.generation);
  final int generation;
}

/// A `whoami --json` exec channel on connection [generation] finished.
final class WhoamiFinished extends SignInEvent {
  const WhoamiFinished(this.generation, this.outcome, this.at);
  final int generation;
  final ChannelOutcome outcome;
  final DateTime at;
}

/// Connection [generation] closed.
final class Disconnected extends SignInEvent {
  const Disconnected(this.generation);
  final int generation;
}

/// The clock advanced.
final class Tick extends SignInEvent {
  const Tick(this.at);
  final DateTime at;
}

/// An immutable sign-in snapshot.
final class SignIn {
  const SignIn._({
    required this.phase,
    required this.generation,
    this.approvalUrl,
    this.fingerprint,
    this.issuedAt,
    this.account,
    this.failure,
  });

  const SignIn.initial() : this._(phase: SignInPhase.idle, generation: 0);

  final SignInPhase phase;

  /// The connection the current phase belongs to. Events from any other
  /// generation are stale and ignored.
  final int generation;

  /// Shown only while [phase] is [SignInPhase.awaitingApproval].
  final Uri? approvalUrl;

  /// The key fingerprint the browser page must show, for comparison.
  final String? fingerprint;
  final DateTime? issuedAt;

  /// The `whoami` result once signed in.
  final Map<String, Object?>? account;
  final SignInFailure? failure;

  /// Whether a link may be presented now.
  bool get showsLink => phase == SignInPhase.awaitingApproval && approvalUrl != null;

  /// Applies one event.
  SignIn apply(SignInEvent event) => switch (event) {
    StartSignIn() when phase != SignInPhase.signedIn && phase != SignInPhase.connecting => SignIn._(
      phase: SignInPhase.connecting,
      generation: generation + 1,
    ),
    StartSignIn() => this,
    Connected(:final generation) when generation != this.generation => this,
    Connected() => this,
    HostRejected(:final generation) when generation != this.generation => this,
    HostRejected() => _fail(SignInFailure.hostUntrusted),
    WhoamiFinished(:final generation) when generation != this.generation => this,
    WhoamiFinished(:final outcome, :final at) => _whoami(outcome, at),
    Disconnected(:final generation) when generation != this.generation => this,
    Disconnected() => switch (phase) {
      SignInPhase.awaitingApproval ||
      SignInPhase.connecting => SignIn._(phase: SignInPhase.expired, generation: generation),
      _ => this,
    },
    Tick(:final at) =>
      phase == SignInPhase.awaitingApproval &&
              issuedAt != null &&
              !at.isBefore(issuedAt!.add(approvalLifetime))
          ? SignIn._(phase: SignInPhase.expired, generation: generation)
          : this,
  };

  SignIn _whoami(ChannelOutcome outcome, DateTime at) {
    if (phase != SignInPhase.connecting && phase != SignInPhase.awaitingApproval) return this;
    final reply = outcome.reply;
    switch (reply) {
      case ReadReply(:final result) when outcome.exit == PorscheExit.ok:
        return SignIn._(phase: SignInPhase.signedIn, generation: generation, account: result);
      case ApprovalReply(:final approvalUrl, :final fingerprint):
        // A link already shown is kept: re-polling must not restart its clock.
        if (phase == SignInPhase.awaitingApproval) return this;
        return SignIn._(
          phase: SignInPhase.awaitingApproval,
          generation: generation,
          approvalUrl: approvalUrl,
          fingerprint: fingerprint,
          issuedAt: at,
        );
      case ErrorReply() when outcome.exit == PorscheExit.authority:
        return _fail(SignInFailure.refused);
      case ErrorReply() when outcome.exit == PorscheExit.unavailable:
        return this;
      case ErrorReply() || ReadReply() || ReceiptReply() || null:
        return _fail(SignInFailure.protocol);
    }
  }

  SignIn _fail(SignInFailure failure) =>
      SignIn._(phase: SignInPhase.failed, generation: generation, failure: failure);
}
