// Attach and watch channels over plain byte streams. The SSH session code
// adapts a dartssh2 session onto these, so framing, header parsing and exit
// mapping are the same code in tests (in-memory streams) and production.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:mila_core/mila_core.dart';

import 'porsche.dart';

/// Bytes Mila holds from stdout before the header arrives. Porsche writes the
/// header first, so anything more is a misbehaving gateway.
const int maximumPreHeaderBytes = 65536;

/// A [TerminalChannel] over a channel's stdout, stderr and exit status.
///
/// The first newline-terminated stderr line is the header; later stderr is
/// drained unread. Stdout and stderr are merged in arrival order: both come
/// from one SSH channel, whose messages arrive in order, and their
/// controllers deliver in the order the session added to them.
final class StreamTerminalChannel implements TerminalChannel {
  StreamTerminalChannel({
    required Stream<Uint8List> stdout,
    required Stream<Uint8List> stderr,
    required Future<int?> exitStatus,
    required void Function(Uint8List bytes) write,
    required void Function(TerminalSize size) resize,
    required Future<void> Function() close,
  }) : _write = write,
       _resize = resize,
       _close = close {
    var outDone = false, errDone = false;
    void maybeEnd() {
      if (!outDone || !errDone) return;
      unawaited(
        exitStatus
            .then((status) => AttachOutcome.fromStatus(status))
            .catchError((Object _) => AttachOutcome.transport)
            .then(_end),
      );
    }

    _stdout = stdout.listen(
      (chunk) {
        if (_ended || chunk.isEmpty) return;
        _signals.add(AttachOutputSignal(chunk));
      },
      onError: (Object _) {},
      onDone: () {
        outDone = true;
        maybeEnd();
      },
    );
    _stderr = stderr.listen(
      _onStderr,
      onError: (Object _) {},
      onDone: () {
        errDone = true;
        maybeEnd();
      },
    );
  }

  final void Function(Uint8List bytes) _write;
  final void Function(TerminalSize size) _resize;
  final Future<void> Function() _close;
  final StreamController<AttachSignal> _signals = StreamController<AttachSignal>();
  late final StreamSubscription<Uint8List> _stdout;
  late final StreamSubscription<Uint8List> _stderr;
  final BytesBuilder _header = BytesBuilder(copy: true);
  bool _headerSeen = false;
  bool _ended = false;

  void _onStderr(Uint8List chunk) {
    if (_headerSeen || _ended) return;
    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] == 0x0a) {
        _header.add(chunk.sublist(0, i));
        _headerSeen = true;
        AttachHeader? header;
        try {
          header = decodeAttachHeader(utf8.decode(_header.takeBytes()));
        } on FormatException {
          header = null;
        }
        _signals.add(AttachHeaderSignal(header));
        return;
      }
    }
    _header.add(chunk);
    if (_header.length > maximumHeaderBytes) {
      _headerSeen = true;
      _header.clear();
      _signals.add(const AttachHeaderSignal(null));
    }
  }

  void _end(AttachOutcome outcome) {
    if (_ended) return;
    _ended = true;
    _signals.add(AttachEndSignal(outcome));
    unawaited(_signals.close());
  }

  @override
  Stream<AttachSignal> get signals => _signals.stream;

  @override
  void send(List<int> bytes) {
    if (_ended || bytes.isEmpty) return;
    _write(Uint8List.fromList(bytes));
  }

  @override
  void resize(TerminalSize size) {
    if (_ended) return;
    _resize(size.clamped);
  }

  @override
  Future<void> close() async {
    await _close().catchError((Object _) {});
    await _stdout.cancel();
    await _stderr.cancel();
    _end(AttachOutcome.closed);
  }
}

/// A [WatchChannel] over a channel's stdout and exit status.
final class StreamWatchChannel implements WatchChannel {
  StreamWatchChannel({
    required Stream<Uint8List> stdout,
    required Future<int?> exitStatus,
    required Future<void> Function() close,
  }) : _close = close,
       exit = exitStatus
           .then((status) => status == null ? null : PorscheExit.fromCode(status))
           .catchError((Object _) => null) {
    _subscription = stdout.listen(
      (chunk) {
        try {
          for (final line in _framer.add(chunk)) {
            if (line.isEmpty) continue;
            _events.add(decodeWatchLine(line));
          }
        } on WatchFormatException catch (error) {
          _events.addError(error);
          unawaited(close());
        } on ReplyFormatException {
          _events.addError(const WatchFormatException('envelope'));
          unawaited(close());
        }
      },
      onError: (Object _) {},
      onDone: () => unawaited(_events.close()),
    );
  }

  final Future<void> Function() _close;
  final LineFramer _framer = LineFramer();
  final StreamController<WatchEvent> _events = StreamController<WatchEvent>();
  late final StreamSubscription<Uint8List> _subscription;

  @override
  final Future<PorscheExit?> exit;

  @override
  Stream<WatchEvent> get events => _events.stream;

  @override
  Future<void> close() async {
    await _close().catchError((Object _) {});
    await _subscription.cancel();
    if (!_events.isClosed) await _events.close();
  }
}

/// Whether a watch feed is delivering.
enum FeedStatus { connecting, live, retrying, stopped }

/// A `watch` that stays open: it reopens after transport loss or silence
/// with jittered backoff, and stops for good on authority loss or refusal,
/// following [WatchSupervisor].
final class WatchFeed {
  WatchFeed({
    required this.open,
    required this.filter,
    Random? random,
    this.silence = watchSilenceLimit,
  }) : _random = random ?? Random.secure();

  /// Opens one channel for [command]; usually `session.watch`.
  final Future<WatchChannel> Function(PorscheCommand command) open;
  final WatchFilter filter;
  final Duration silence;
  final Random _random;

  final StreamController<WatchEvent> _events = StreamController<WatchEvent>.broadcast();
  final StreamController<FeedStatus> _status = StreamController<FeedStatus>.broadcast();
  WatchSupervisor _state = const WatchSupervisor.initial();
  WatchChannel? _channel;
  Timer? _retry;
  Timer? _silent;

  /// Change notices from every channel this feed opens.
  Stream<WatchEvent> get events => _events.stream;

  /// Status changes.
  Stream<FeedStatus> get status => _status.stream;

  WatchSupervisor get state => _state;

  void _say(FeedStatus status) {
    if (!_status.isClosed) _status.add(status);
  }

  /// Starts the feed. A feed with an empty filter does nothing.
  void start() {
    if (filter.isEmpty) return;
    unawaited(_connect());
  }

  Future<void> _connect() async {
    _state = _state.open();
    if (_state.phase != WatchPhase.opening) return;
    final generation = _state.generation;
    _say(FeedStatus.connecting);
    final WatchChannel channel;
    try {
      channel = await open(filter.command());
    } on Object {
      _ended(generation, null);
      return;
    }
    if (_state.phase == WatchPhase.stopped) {
      await channel.close();
      return;
    }
    _channel = channel;
    _arm(generation);
    channel.events.listen(
      (event) {
        if (generation != _state.generation) return;
        _arm(generation);
        _state = _state.received(generation, event);
        if (_state.phase == WatchPhase.live) _say(FeedStatus.live);
        if (event is! WatchRefused && event is! Heartbeat && event is! UnknownWatchEvent) {
          if (!_events.isClosed) _events.add(event);
        }
        if (_state.phase == WatchPhase.stopped) {
          _say(FeedStatus.stopped);
          unawaited(channel.close());
        }
      },
      onError: (Object _) => unawaited(channel.close()),
      onDone: () async => _ended(generation, await channel.exit),
    );
  }

  void _arm(int generation) {
    _silent?.cancel();
    _silent = Timer(silence, () {
      if (generation == _state.generation) unawaited(_channel?.close());
    });
  }

  void _ended(int generation, PorscheExit? exit) {
    if (generation != _state.generation) return;
    _silent?.cancel();
    _state = _state.ended(generation, exit);
    if (_state.phase == WatchPhase.stopped || _status.isClosed) {
      _say(FeedStatus.stopped);
      return;
    }
    _say(FeedStatus.retrying);
    _retry = Timer(
      WatchSupervisor.backoff.delay(_state.attempts - 1, _random),
      () => unawaited(_connect()),
    );
  }

  /// Stops the feed and closes its channel.
  Future<void> close() async {
    _state = _state.close();
    _retry?.cancel();
    _silent?.cancel();
    await _channel?.close();
    await _events.close();
    await _status.close();
  }
}
