/// The extra-keys row above a touch keyboard: keys a phone keyboard lacks,
/// encoded as the bytes a VT terminal sends (ADR-0223 client side).
library;

import 'dart:convert';

/// One key on the row.
enum ExtraKey { esc, tab, ctrl, tilde, pipe, dash, up, down, left, right, paste }

const int _esc = 0x1b;

/// The most bytes one paste sends; longer clipboard text is truncated at a
/// character boundary.
const int maximumPasteBytes = 65536;

/// Bracketed-paste markers (`ESC [ 200 ~` and `ESC [ 201 ~`).
const List<int> pasteStart = [_esc, 0x5b, 0x32, 0x30, 0x30, 0x7e];
const List<int> pasteEnd = [_esc, 0x5b, 0x32, 0x30, 0x31, 0x7e];

/// What pressing a key produces.
sealed class KeyOutput {
  const KeyOutput();
}

/// Send these bytes to the terminal.
final class SendBytes extends KeyOutput {
  const SendBytes(this.bytes);
  final List<int> bytes;
}

/// Read the clipboard and send it with [encodePaste].
final class RequestPaste extends KeyOutput {
  const RequestPaste();
}

/// Only the modifier changed; nothing to send.
final class ModifierOnly extends KeyOutput {
  const ModifierOnly();
}

/// The row's state: whether Ctrl is armed for the next key. Ctrl is one-shot,
/// as on a hardware keyboard held for one keystroke.
final class ExtraKeys {
  const ExtraKeys({this.ctrl = false});

  final bool ctrl;

  /// Presses [key]. [applicationCursor] is the terminal's DECCKM mode, under
  /// which arrows send `ESC O x` instead of `ESC [ x`.
  (ExtraKeys, KeyOutput) press(ExtraKey key, {bool applicationCursor = false}) {
    if (key == ExtraKey.ctrl) return (ExtraKeys(ctrl: !ctrl), const ModifierOnly());
    const idle = ExtraKeys();
    final output = switch (key) {
      ExtraKey.esc => const SendBytes([_esc]),
      ExtraKey.tab => const SendBytes([0x09]),
      ExtraKey.tilde => SendBytes(ctrl ? [0x1e] : [0x7e]),
      ExtraKey.pipe => SendBytes(ctrl ? [0x1c] : [0x7c]),
      ExtraKey.dash => SendBytes(ctrl ? [0x1f] : [0x2d]),
      ExtraKey.up ||
      ExtraKey.down ||
      ExtraKey.right ||
      ExtraKey.left => SendBytes(arrowBytes(key, applicationCursor: applicationCursor, ctrl: ctrl)),
      ExtraKey.paste => const RequestPaste(),
      ExtraKey.ctrl => throw StateError('unreachable'),
    };
    return (idle, output);
  }

  /// Applies an armed Ctrl to text typed on the keyboard: the first
  /// character becomes its control byte when it has one. Returns the bytes
  /// to send and the disarmed row.
  (ExtraKeys, List<int>) type(String text) {
    if (!ctrl || text.isEmpty) return (this, utf8.encode(text));
    final first = text.runes.first;
    final rest = String.fromCharCodes(text.runes.skip(1));
    final control = controlByte(first);
    return (
      const ExtraKeys(),
      [
        ...control == null ? utf8.encode(String.fromCharCode(first)) : [control],
        ...utf8.encode(rest),
      ],
    );
  }
}

/// The control byte Ctrl+[rune] sends, or null when it has none.
int? controlByte(int rune) {
  if (rune >= 0x61 && rune <= 0x7a) return rune - 0x60; // a–z
  if (rune >= 0x40 && rune <= 0x5f) return rune - 0x40; // @ A–Z [ \ ] ^ _
  return switch (rune) {
    0x20 => 0x00, // space
    0x3f => 0x7f, // ?
    0x7e => 0x1e, // ~
    0x7c => 0x1c, // |
    0x2d => 0x1f, // -
    _ => null,
  };
}

/// The bytes for an arrow key.
List<int> arrowBytes(ExtraKey key, {required bool applicationCursor, bool ctrl = false}) {
  final final_ = switch (key) {
    ExtraKey.up => 0x41,
    ExtraKey.down => 0x42,
    ExtraKey.right => 0x43,
    ExtraKey.left => 0x44,
    _ => throw ArgumentError.value(key, 'key', 'not an arrow'),
  };
  // Modified arrows always use CSI with parameter 5 (Ctrl), as xterm does.
  if (ctrl) return [_esc, 0x5b, 0x31, 0x3b, 0x35, final_];
  return [_esc, applicationCursor ? 0x4f : 0x5b, final_];
}

// @cc [owner:ghuntley,label:security] mila-paste-cannot-escape
// Pasted text MUST NOT carry control sequences into the terminal: every C0
// control except tab, every DEL and every C1 control is removed, newlines
// become carriage returns, and a bracketed paste cannot contain its own end
// marker, so clipboard content cannot run commands by itself.
/// Encodes clipboard [text] for the terminal.
List<int> encodePaste(String text, {required bool bracketed}) {
  final out = StringBuffer();
  var previousCr = false;
  for (final rune in text.runes) {
    if (rune == 0x0a) {
      if (!previousCr) out.writeCharCode(0x0d);
      previousCr = false;
      continue;
    }
    previousCr = rune == 0x0d;
    final control = rune < 0x20 || rune == 0x7f || (rune >= 0x80 && rune <= 0x9f);
    final lone = rune >= 0xd800 && rune <= 0xdfff;
    if ((control && rune != 0x09 && rune != 0x0d) || lone) continue;
    out.writeCharCode(rune);
  }
  var bytes = utf8.encode(out.toString());
  if (bytes.length > maximumPasteBytes) {
    var end = maximumPasteBytes;
    // Back up to a character boundary: continuation bytes are 10xxxxxx.
    while (end > 0 && bytes[end] & 0xc0 == 0x80) {
      end--;
    }
    bytes = bytes.sublist(0, end);
  }
  return bracketed ? [...pasteStart, ...bytes, ...pasteEnd] : bytes;
}
