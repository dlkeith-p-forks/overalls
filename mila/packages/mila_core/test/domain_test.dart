import 'dart:math';

import 'package:hegel/hegel.dart';
import 'package:mila_core/src/backoff.dart';
import 'package:mila_core/src/porsche_reply.dart';
import 'package:mila_core/src/request_poll.dart';
import 'package:mila_core/src/sign_in.dart';
import 'package:test/test.dart';

const String _requestId = 'porsche-0123456789abcdef0123456789abcdef';
const String _operation = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';
const String _otherOperation = '6f1e2d3c-4b5a-4987-8a6b-5c4d3e2f1a0b';
const String _fingerprint = 'SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU';

/// Every channel outcome the transport can report for a mutation or poll.
final Generator<ChannelOutcome> _pollOutcome = oneOf<ChannelOutcome>([
  tuple2(
        sampledFrom(ReceiptStatus.values),
        sampledFrom<String?>([_operation, _otherOperation, null]),
      )
      .where((v) => v.$2 != null || v.$1 == ReceiptStatus.succeeded)
      .map(
        (v) => ChannelOutcome(
          v.$1 == ReceiptStatus.failed || v.$1 == ReceiptStatus.superseded
              ? PorscheExit.failed
              : PorscheExit.ok,
          ReceiptReply(requestId: _requestId, status: v.$1, operationId: v.$2, result: const {}),
        ),
      ),
  just(
    const ChannelOutcome(
      PorscheExit.ok,
      ReceiptReply(
        requestId: 'porsche-ffffffffffffffffffffffffffffffff',
        status: ReceiptStatus.succeeded,
        operationId: _operation,
        result: {},
      ),
    ),
  ),
  sampledFrom(const ['request_not_found', 'machine_pinned', 'unauthorized']).flatMap(
    (error) => sampledFrom(const [
      PorscheExit.invalid,
      PorscheExit.authority,
    ]).map((exit) => ChannelOutcome(exit, ErrorReply(error: error))),
  ),
  just(const ChannelOutcome(PorscheExit.unavailable, ErrorReply(error: 'temporarily_unavailable'))),
  just(const ChannelOutcome(PorscheExit.timedOut, null)),
  just(const ChannelOutcome(PorscheExit.interrupted, null)),
]);

/// A model of the poller: the request id is fixed, terminal states absorb,
/// and the only command it ever asks for is `request show` with that id.
final class PollMachine extends StateMachine {
  RequestPoll poll = RequestPoll.submitted(_requestId);
  RequestPoll? terminalAt;
  String? firstOperation;

  @override
  List<Rule> get rules => [
    Rule('observe', (tc) {
      final outcome = tc.draw(_pollOutcome, name: 'outcome');
      poll = poll.observe(outcome);
      if (poll.terminal) terminalAt ??= poll;
      firstOperation ??= poll.operationId;
    }),
    Rule('poll', (tc) {
      final action = poll.next;
      if (action is PollAgain) {
        expect(action.attempt, poll.attempts);
        poll = poll.polled();
      }
    }),
  ];

  @override
  List<Invariant> get invariants => [
    Invariant('the request id never changes', (tc) => expect(poll.requestId, _requestId)),
    Invariant('terminal states absorb later replies', (tc) {
      if (terminalAt != null) expect(identical(poll, terminalAt), isTrue);
    }),
    Invariant('the operation id is fixed once known', (tc) {
      if (firstOperation != null) expect(poll.operationId, firstOperation);
    }),
    Invariant('only terminal states stop polling', (tc) {
      expect(poll.next is PollDone, poll.terminal);
    }),
  ];
}

final class SignInMachine extends StateMachine {
  SignIn state = const SignIn.initial();
  DateTime now = DateTime.utc(2026, 10, 18);
  Uri? shownLink;
  int? shownGeneration;

  ChannelOutcome _approval(int n) => ChannelOutcome(
    PorscheExit.authority,
    ApprovalReply(
      fingerprint: _fingerprint,
      approvalUrl: Uri.parse('https://overalls.example/ssh/approve/$n'),
    ),
  );

  @override
  List<Rule> get rules => [
    Rule('start', (tc) => state = state.apply(const StartSignIn())),
    Rule('connected', (tc) => state = state.apply(Connected(state.generation))),
    Rule('stale event', (tc) {
      final old = tc.draw(integers(min: -3, max: -1), name: 'age') + state.generation;
      final before = state;
      state = state.apply(Disconnected(old));
      state = state.apply(WhoamiFinished(old, _approval(old), now));
      state = state.apply(HostRejected(old));
      expect(identical(state, before), isTrue);
    }),
    Rule('whoami pending', (tc) {
      final n = tc.draw(integers(min: 0, max: 99), name: 'n');
      state = state.apply(WhoamiFinished(state.generation, _approval(n), now));
    }),
    Rule('whoami approved', (tc) {
      state = state.apply(
        WhoamiFinished(
          state.generation,
          const ChannelOutcome(PorscheExit.ok, ReadReply({'email': 'a@example.com'})),
          now,
        ),
      );
    }),
    Rule('whoami unavailable', (tc) {
      state = state.apply(
        WhoamiFinished(
          state.generation,
          const ChannelOutcome(
            PorscheExit.unavailable,
            ErrorReply(error: 'temporarily_unavailable'),
          ),
          now,
        ),
      );
    }),
    Rule('disconnect', (tc) => state = state.apply(Disconnected(state.generation))),
    Rule('host rejected', (tc) => state = state.apply(HostRejected(state.generation))),
    Rule('time passes', (tc) {
      final seconds = tc.draw(integers(min: 1, max: 400), name: 'seconds');
      now = now.add(Duration(seconds: seconds));
      state = state.apply(Tick(now));
    }),
  ];

  @override
  List<Invariant> get invariants => [
    Invariant('a link belongs to the live connection and its lifetime', (tc) {
      if (state.showsLink) {
        expect(state.issuedAt, isNotNull);
        expect(now.isBefore(state.issuedAt!.add(approvalLifetime)), isTrue);
        if (shownGeneration == state.generation && shownLink != null) {
          // Re-polling never swaps the link the user is already looking at.
          expect(state.approvalUrl, shownLink);
        }
        shownLink = state.approvalUrl;
        shownGeneration = state.generation;
      } else {
        expect(state.approvalUrl, isNull);
      }
    }),
    Invariant('signed in carries an account and nothing else', (tc) {
      expect(state.phase == SignInPhase.signedIn, state.account != null);
      if (state.phase == SignInPhase.signedIn) expect(state.approvalUrl, isNull);
    }),
    Invariant('failures name a reason', (tc) {
      expect(state.phase == SignInPhase.failed, state.failure != null);
    }),
  ];
}

void main() {
  property('backoff stays within half-ceiling and the cap', (tc) {
    final attempt = tc.draw(integers(min: 0, max: 80), name: 'attempt');
    final seed = tc.draw(integers(min: 0, max: 1 << 30), name: 'seed');
    final retryAfter = tc.draw(
      oneOf<Duration?>([
        just<Duration?>(null),
        integers(min: 0, max: 120).map((s) => Duration(seconds: s)),
      ]),
      name: 'retryAfter',
    );
    const backoff = Backoff();
    final delay = backoff.delay(attempt, Random(seed), retryAfter: retryAfter);
    final ceiling = backoff.ceiling(attempt);
    expect(delay, lessThanOrEqualTo(backoff.cap));
    if (retryAfter == null) {
      expect(delay * 2, greaterThanOrEqualTo(ceiling));
      expect(delay, lessThanOrEqualTo(ceiling));
    } else {
      expect(delay, greaterThanOrEqualTo(retryAfter > backoff.cap ? backoff.cap : retryAfter));
    }
    if (attempt > 0) {
      expect(backoff.ceiling(attempt), greaterThanOrEqualTo(backoff.ceiling(attempt - 1)));
    }
  });

  test('an uncertain submission is resolved by polling, never resubmission', () {
    var poll = RequestPoll.submitted(_requestId);
    poll = poll.observe(const ChannelOutcome(PorscheExit.unavailable, null));
    expect(poll.phase, PollPhase.uncertain);
    expect(poll.next, isA<PollAgain>());
    for (var i = 0; i < notFoundPolls; i++) {
      poll = poll.polled().observe(
        const ChannelOutcome(PorscheExit.invalid, ErrorReply(error: 'request_not_found')),
      );
    }
    expect(poll.phase, PollPhase.refused);
    expect(poll.error, 'request_not_found');
  });

  test('an accepted request survives transient poll failures', () {
    var poll = RequestPoll.submitted(_requestId).observe(
      const ChannelOutcome(
        PorscheExit.ok,
        ReceiptReply(
          requestId: _requestId,
          status: ReceiptStatus.accepted,
          operationId: _operation,
          result: {},
        ),
      ),
    );
    poll = poll.observe(const ChannelOutcome(PorscheExit.timedOut, null));
    expect(poll.phase, PollPhase.accepted);
  });

  property('the request poller matches its model', (tc) => runStateful(tc, PollMachine()));

  property('sign-in never shows a stale or expired link', (tc) => runStateful(tc, SignInMachine()));
}
