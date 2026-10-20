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

  /// The signed-in connection closed. [SignIn.account] is kept for display;
  /// reconnecting opens a new connection and asks `whoami` again.
  disconnected,

  /// The link can no longer be used; a new connection mints a new one.
  expired,

  /// A closed failure the user must act on.
  failed,
}

/// Why sign-in failed.
enum SignInFailure { hostUntrusted, refused, protocol, unreachable }

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

/// Connection [generation] could not be opened: no trust document or no SSH
/// listener at the host. Distinct from [Disconnected], which ends a link
/// already shown.
final class Unreachable extends SignInEvent {
  const Unreachable(this.generation);
  final int generation;
}

/// Connection [generation] closed.
final class Disconnected extends SignInEvent {
  const Disconnected(this.generation);
  final int generation;
}

/// The user signed out on this device: the connection is dropped and its
/// generation retired, so nothing it still reports can apply. Keys and the
/// deployment's approval are unchanged.
final class SignOut extends SignInEvent {
  const SignOut();
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

  /// The `whoami` result once signed in, kept while [SignInPhase.disconnected].
  final Map<String, Object?>? account;
  final SignInFailure? failure;

  /// The account's email from [account], when it is a non-empty string.
  String? get email => switch (account?['email']) {
    final String email when email.isNotEmpty => email,
    _ => null,
  };

  /// The OpenSSH public key `whoami` reported for this connection's key.
  String? get publicKey => switch (account?['public_key']) {
    final String key when key.isNotEmpty => key,
    _ => null,
  };

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
    Unreachable(:final generation) when generation != this.generation => this,
    Unreachable() => phase == SignInPhase.connecting ? _fail(SignInFailure.unreachable) : this,
    Disconnected(:final generation) when generation != this.generation => this,
    Disconnected() => switch (phase) {
      SignInPhase.awaitingApproval ||
      SignInPhase.connecting => SignIn._(phase: SignInPhase.expired, generation: generation),
      SignInPhase.signedIn => SignIn._(
        phase: SignInPhase.disconnected,
        generation: generation,
        account: account,
      ),
      _ => this,
    },
    SignOut() => SignIn._(phase: SignInPhase.idle, generation: generation + 1),
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
