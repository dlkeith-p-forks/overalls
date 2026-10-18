/// Bounded exponential backoff with full jitter for reconnects and polls.
library;

import 'dart:math';

/// A backoff policy. Pure: callers pass the random source. [base] must be
/// positive and no greater than [cap].
final class Backoff {
  const Backoff({
    this.base = const Duration(milliseconds: 500),
    this.cap = const Duration(seconds: 30),
  });

  final Duration base;
  final Duration cap;

  /// The ceiling for attempt [attempt] (0-based): `min(cap, base * 2^attempt)`.
  Duration ceiling(int attempt) {
    final shift = attempt.clamp(0, 30);
    final micros = base.inMicroseconds * (1 << shift);
    return Duration(microseconds: min(micros, cap.inMicroseconds));
  }

  /// A delay in `[ceiling/2, ceiling]`, so retries never stampede and never
  /// spin. A server `Retry-After` raises the floor but never the cap.
  Duration delay(int attempt, Random random, {Duration? retryAfter}) {
    final ceiling = this.ceiling(attempt).inMicroseconds;
    final half = ceiling ~/ 2;
    final jittered = half + (ceiling - half == 0 ? 0 : random.nextInt(ceiling - half + 1));
    final floor = retryAfter == null ? 0 : min(retryAfter.inMicroseconds, cap.inMicroseconds);
    return Duration(microseconds: max(jittered, floor));
  }
}
