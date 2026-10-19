// One terminal view: an xterm emulator fed by successive `terminal attach`
// PTY channels, driven by the pure `TerminalAttach` state machine.
//
// @cc [owner:ghuntley,label:security;privacy] mila-terminal-bytes-never-at-rest
// Terminal output and input MUST only pass between the attach channel and
// the in-memory emulator: never written to disk, the offline cache,
// preferences, logs or diagnostics, and never held in controller state.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';
import 'package:xterm/xterm.dart';

import '../session.dart';

/// Lines of scrollback the emulator keeps in memory.
const int terminalScrollback = 10000;

/// The clipboard, injectable for tests.
final clipboardReaderProvider = Provider<Future<String?> Function()>(
  (ref) =>
      () async => (await Clipboard.getData(Clipboard.kTextPlain))?.text,
);

/// What the terminal screen shows besides the emulator itself.
final class TerminalScreenState {
  const TerminalScreenState({required this.attach, this.keys = const ExtraKeys()});
  final TerminalAttach attach;
  final ExtraKeys keys;

  TerminalScreenState copyWith({TerminalAttach? attach, ExtraKeys? keys}) =>
      TerminalScreenState(attach: attach ?? this.attach, keys: keys ?? this.keys);
}

/// A terminal session on a machine of a deployment.
typedef TerminalKey = (Deployment, String machine, String session);

final terminalProvider = NotifierProvider.autoDispose
    .family<TerminalController, TerminalScreenState, TerminalKey>(TerminalController.new);

final class TerminalController extends Notifier<TerminalScreenState> {
  TerminalController(this.key);

  final TerminalKey key;

  /// The emulator; it holds the screen in memory only.
  late final Terminal terminal = Terminal(
    maxLines: terminalScrollback,
    onOutput: _typed,
    onResize: (columns, rows, _, _) => _resized(TerminalSize(columns, rows)),
  );

  TerminalChannel? _channel;
  StreamSubscription<AttachSignal>? _signals;
  ByteConversionSink? _decoder;
  Timer? _retry;
  TerminalSize _size = const TerminalSize(80, 24);

  static const Backoff _backoff = Backoff(base: Duration(seconds: 1), cap: Duration(seconds: 20));

  @override
  TerminalScreenState build() {
    ref.onDispose(_dispose);
    final session = ref.watch(sessionProvider(key.$1));
    if (session != null) Future.microtask(connect);
    return const TerminalScreenState(attach: TerminalAttach.initial());
  }

  void _apply(AttachEvent event) {
    if (!ref.mounted) return;
    state = state.copyWith(attach: state.attach.apply(event));
  }

  /// Opens a new attach channel from the current cursor.
  Future<void> connect() async {
    _retry?.cancel();
    final session = ref.read(sessionProvider(key.$1));
    if (session == null || !ref.mounted) return;
    _apply(const AttachRequested());
    final attach = state.attach;
    if (attach.phase != AttachPhase.attaching) return;
    final generation = attach.generation;
    final TerminalChannel channel;
    try {
      channel = await session.attach(attach.command(key.$2, key.$3), size: _size);
    } on Object {
      _ended(generation, AttachOutcome.transport);
      return;
    }
    if (!ref.mounted || state.attach.generation != generation) {
      await channel.close();
      return;
    }
    _channel = channel;
    _signals = channel.signals.listen((signal) {
      switch (signal) {
        case AttachHeaderSignal(:final header):
          _apply(HeaderReceived(generation, header));
          if (state.attach.resetPending) {
            _resetScreen();
            _apply(const ScreenReset());
          }
          // The session may have a different size than this view.
          if (state.attach.canResize) channel.resize(_size);
        case AttachOutputSignal(:final bytes):
          if (!state.attach.acceptsOutput(generation)) return;
          _decoder ??= _newDecoder();
          _decoder!.add(bytes);
          _apply(OutputReceived(generation, bytes.length));
        case AttachEndSignal(:final outcome):
          _ended(generation, outcome);
      }
    });
  }

  ByteConversionSink _newDecoder() =>
      const Utf8Decoder(allowMalformed: true)
          .startChunkedConversion(StringConversionSink.withCallback(terminal.write));

  void _resetScreen() {
    _decoder = null;
    terminal
      ..useMainBuffer()
      ..eraseScrollbackOnly()
      ..eraseDisplay()
      ..setCursor(0, 0);
  }

  void _ended(int generation, AttachOutcome outcome) {
    _apply(ChannelEnded(generation, outcome));
    if (!ref.mounted) return;
    _channel = null;
    final attach = state.attach;
    if (attach.phase == AttachPhase.waiting) {
      _retry = Timer(
        _backoff.delay(attach.attempts - 1, ref.read(randomProvider)),
        () => unawaited(connect()),
      );
    }
  }

  void _send(List<int> bytes) {
    if (bytes.isEmpty || !state.attach.canSendInput) return;
    _channel?.send(bytes);
  }

  void _typed(String data) {
    final (keys, bytes) = state.keys.type(data);
    if (keys.ctrl != state.keys.ctrl) state = state.copyWith(keys: keys);
    _send(bytes);
  }

  void _resized(TerminalSize size) {
    _size = size.clamped;
    if (state.attach.canResize) _channel?.resize(_size);
  }

  /// Presses one key of the extra-keys row.
  Future<void> press(ExtraKey key) async {
    final (keys, output) = state.keys.press(key, applicationCursor: terminal.cursorKeysMode);
    state = state.copyWith(keys: keys);
    switch (output) {
      case SendBytes(:final bytes):
        _send(bytes);
      case RequestPaste():
        if (!state.attach.canSendInput) return;
        final text = await ref.read(clipboardReaderProvider)();
        if (text != null && text.isNotEmpty) {
          _send(encodePaste(text, bracketed: terminal.bracketedPasteMode));
        }
      case ModifierOnly():
        break;
    }
  }

  /// Switches read-only viewing. Leaving read-only needs a writable
  /// attachment, so the view reattaches from its cursor.
  Future<void> setReadOnly(bool readOnly) async {
    final wasGrantedReadOnly = state.attach.mode == AttachMode.readOnly;
    _apply(ReadOnlyChanged(readOnly));
    if (!readOnly && (wasGrantedReadOnly || state.attach.phase != AttachPhase.attached)) {
      await _reattach();
    }
  }

  /// Reattaches now, after a failure the user wants to retry.
  Future<void> retry() => _reattach();

  Future<void> _reattach() async {
    _apply(const Detached());
    await _closeChannel();
    await connect();
  }

  Future<void> _closeChannel() async {
    final channel = _channel;
    _channel = null;
    await _signals?.cancel();
    _signals = null;
    await channel?.close();
  }

  void _dispose() {
    _retry?.cancel();
    unawaited(_closeChannel());
    _decoder = null;
  }
}
