import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hegel/hegel.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';
import 'package:test/test.dart';

const String _thread = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';

/// An in-memory attach channel: the test plays the gateway.
final class _Pipe {
  final StreamController<Uint8List> stdout = StreamController<Uint8List>();
  final StreamController<Uint8List> stderr = StreamController<Uint8List>();
  final Completer<int?> status = Completer<int?>();
  final List<List<int>> written = [];
  final List<TerminalSize> resized = [];
  bool closed = false;

  late final StreamTerminalChannel channel = StreamTerminalChannel(
    stdout: stdout.stream,
    stderr: stderr.stream,
    exitStatus: status.future,
    write: written.add,
    resize: resized.add,
    close: () async => closed = true,
  );

  Future<void> finish(int? code) async {
    status.complete(code);
    await stdout.close();
    await stderr.close();
  }
}

Uint8List _b(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  test('the stderr header, output and exit become signals in order', () async {
    final pipe = _Pipe();
    final signals = <AttachSignal>[];
    final done = pipe.channel.signals.forEach(signals.add);
    pipe.stderr.add(_b('{"attached":true,"from":4096,'));
    pipe.stderr.add(_b('"mode":"ro","replay_bytes":0,"version":1}\nignored later stderr\n'));
    await Future<void>.delayed(Duration.zero);
    pipe.stdout.add(_b('hello'));
    await pipe.finish(3);
    await done;
    final header = (signals[0] as AttachHeaderSignal).header! as AttachedHeader;
    expect((header.from, header.mode), (4096, AttachMode.readOnly));
    expect(utf8.decode((signals[1] as AttachOutputSignal).bytes), 'hello');
    expect((signals[2] as AttachEndSignal).outcome, AttachOutcome.authority);
    expect(signals, hasLength(3));
  });

  test('an invalid or overlong header is reported as invalid', () async {
    for (final header in ['{"attached":false,"error":"ticket=abc","version":1}\n', 'x' * 600]) {
      final pipe = _Pipe();
      final first = pipe.channel.signals.first;
      pipe.stderr.add(_b(header));
      expect((await first as AttachHeaderSignal).header, isNull);
      await pipe.finish(1);
    }
  });

  test('input and resizes reach the channel until it ends; sizes are clamped', () async {
    final pipe = _Pipe();
    final done = pipe.channel.signals.drain<void>();
    pipe.channel.send(utf8.encode('ls\r'));
    pipe.channel.resize(const TerminalSize(9999, 0));
    await pipe.finish(0);
    await done;
    pipe.channel.send(utf8.encode('late'));
    expect(pipe.written.map(utf8.decode), ['ls\r']);
    expect(pipe.resized, [const TerminalSize(4096, 1)]);
  });

  test('a dropped connection without a status is a transport failure', () async {
    final pipe = _Pipe();
    final last = pipe.channel.signals.last;
    await pipe.finish(null);
    expect((await last as AttachEndSignal).outcome, AttachOutcome.transport);
  });

  property('watch framing survives any chunking', (tc) async {
    final lines = [
      '{"version":1,"event":"thread","id":"$_thread"}',
      '{"version":1,"event":"heartbeat"}',
      '{"version":1,"event":"resync"}',
    ];
    final picked = tc.draw(lists(sampledFrom(lines), minLength: 1, maxLength: 6), name: 'lines');
    final bytes = utf8.encode(picked.map((l) => '$l\n').join());
    final size = tc.draw(integers(min: 1, max: 16), name: 'size');
    final out = StreamController<Uint8List>();
    final channel = StreamWatchChannel(
      stdout: out.stream,
      exitStatus: Future<int?>.value(0),
      close: () async {},
    );
    final events = channel.events.toList();
    for (var i = 0; i < bytes.length; i += size) {
      out.add(
        Uint8List.fromList(bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size)),
      );
    }
    await out.close();
    expect((await events).length, picked.length);
    expect(await channel.exit, PorscheExit.ok);
  });

  test('a watch feed reconnects after transport loss and stops on authority loss', () async {
    final opened = <String>[];
    var n = 0;
    Future<WatchChannel> open(PorscheCommand command) async {
      opened.add(encodeCommand(command));
      n++;
      final out = StreamController<Uint8List>();
      final code = n < 3 ? 5 : 3;
      scheduleMicrotask(() async {
        out.add(_b('{"version":1,"event":"thread","id":"$_thread"}\n'));
        await out.close();
      });
      return StreamWatchChannel(
        stdout: out.stream,
        exitStatus: Future.value(code),
        close: () async {},
      );
    }

    final feed = WatchFeed(
      open: open,
      filter: WatchFilter(threads: [_thread]),
    );
    final events = <WatchEvent>[];
    feed.events.listen(events.add);
    final stopped = feed.status.firstWhere((s) => s == FeedStatus.stopped);
    feed.start();
    await stopped.timeout(const Duration(seconds: 20));
    expect(opened, hasLength(3));
    expect(opened.toSet().single, 'watch --json --thread=$_thread');
    expect(events.whereType<ThreadChanged>(), hasLength(3));
    expect(feed.state.stop, WatchStop.authority);
    await feed.close();
  });

  test('a silent watch is closed and reopened', () async {
    var n = 0;
    final closes = <int>[];
    Future<WatchChannel> open(PorscheCommand command) async {
      final id = ++n;
      final out = StreamController<Uint8List>();
      final status = Completer<int?>();
      return StreamWatchChannel(
        stdout: out.stream,
        exitStatus: status.future,
        close: () async {
          closes.add(id);
          if (!status.isCompleted) status.complete(null);
          await out.close();
        },
      );
    }

    final feed = WatchFeed(
      open: open,
      filter: WatchFilter(threads: [_thread]),
      silence: const Duration(milliseconds: 50),
    );
    feed.start();
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(n, greaterThanOrEqualTo(2));
    expect(closes, contains(1));
    await feed.close();
  });
}
