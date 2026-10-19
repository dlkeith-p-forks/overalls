// Submitting one mutation and observing it to a terminal receipt, shared by
// the terminal, thread and web screens. A mutation is sent once under a
// client-allocated request id; uncertainty is resolved by `request show`,
// never by sending again (`mila-mutation-once`).
import 'dart:math';

import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

/// Polls a request may use before Mila stops watching it.
const int maximumMutationPolls = 60;

const Backoff _backoff = Backoff(base: Duration(milliseconds: 300), cap: Duration(seconds: 3));

/// Adds `--json` and a fresh `--request-id` to [command].
PorscheCommand withRequestId(PorscheCommand command, Random random) => PorscheCommand(
  command.name,
  arguments: command.arguments,
  options: {...command.options, 'json': true, 'request-id': allocateRequestId(random)},
);

/// Sends [command] (which carries its request id) once, with [stdin] if it
/// reads a payload, then polls until the receipt is terminal. [onUpdate]
/// sees every intermediate state.
Future<RequestPoll> submitOnce(
  PorscheSession session,
  PorscheCommand command, {
  required Random random,
  List<int>? stdin,
  void Function(RequestPoll poll)? onUpdate,
}) async {
  final requestId = command.options['request-id']! as String;
  var poll = RequestPoll.submitted(requestId);
  onUpdate?.call(poll);
  try {
    poll = poll.observe(await session.exec(command, stdin: stdin));
  } on Object {
    poll = poll.observe(const ChannelOutcome(PorscheExit.unavailable, null));
  }
  onUpdate?.call(poll);
  while (!poll.terminal && poll.attempts < maximumMutationPolls) {
    final next = poll.next as PollAgain;
    await Future<void>.delayed(_backoff.delay(next.attempt, random));
    poll = poll.polled();
    try {
      poll = poll.observe(
        await session.exec(
          PorscheCommand('request show', arguments: [requestId], options: const {'json': true}),
        ),
      );
    } on Object {
      poll = poll.observe(const ChannelOutcome(PorscheExit.unavailable, null));
    }
    onUpdate?.call(poll);
  }
  return poll;
}

/// Runs a read command and returns its result, or null on any failure.
Future<Map<String, Object?>?> readResult(PorscheSession session, PorscheCommand command) async {
  try {
    final outcome = await session.exec(command);
    final reply = outcome.reply;
    return reply is ReadReply ? reply.result : null;
  } on Object {
    return null;
  }
}
