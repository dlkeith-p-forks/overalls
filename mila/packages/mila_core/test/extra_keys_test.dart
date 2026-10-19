import 'dart:convert';

import 'package:hegel/hegel.dart';
import 'package:mila_core/mila_core.dart';
import 'package:test/test.dart';

List<int> _sent(KeyOutput output) => (output as SendBytes).bytes;

bool _containsSequence(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length && match; j++) {
      match = haystack[i + j] == needle[j];
    }
    if (match) return true;
  }
  return false;
}

void main() {
  test('each key sends the bytes a VT terminal expects', () {
    const keys = ExtraKeys();
    expect(_sent(keys.press(ExtraKey.esc).$2), [0x1b]);
    expect(_sent(keys.press(ExtraKey.tab).$2), [0x09]);
    expect(_sent(keys.press(ExtraKey.tilde).$2), utf8.encode('~'));
    expect(_sent(keys.press(ExtraKey.pipe).$2), utf8.encode('|'));
    expect(_sent(keys.press(ExtraKey.dash).$2), utf8.encode('-'));
    expect(_sent(keys.press(ExtraKey.up).$2), utf8.encode('\x1b[A'));
    expect(_sent(keys.press(ExtraKey.left, applicationCursor: true).$2), utf8.encode('\x1bOD'));
    expect(keys.press(ExtraKey.paste).$2, isA<RequestPaste>());
    final (armed, output) = keys.press(ExtraKey.ctrl);
    expect(output, isA<ModifierOnly>());
    expect(armed.ctrl, isTrue);
    expect(armed.type('c').$2, [0x03]);
    expect(armed.type('c').$1.ctrl, isFalse);
    expect(_sent(armed.press(ExtraKey.right).$2), utf8.encode('\x1b[1;5C'));
    expect(armed.press(ExtraKey.ctrl).$1.ctrl, isFalse);
  });

  property('ctrl is one-shot and maps letters to C0 controls', (tc) {
    final rune = tc.draw(integers(min: 0x20, max: 0x7e), name: 'rune');
    final (after, bytes) = const ExtraKeys(ctrl: true).type(String.fromCharCode(rune));
    expect(after.ctrl, isFalse);
    expect(bytes, hasLength(1));
    final control = controlByte(rune);
    if (control == null) {
      expect(bytes.single, rune);
    } else {
      expect(bytes.single == 0x7f || bytes.single < 0x20, isTrue);
    }
    final letter = String.fromCharCode(rune).toLowerCase().codeUnitAt(0);
    if (letter >= 0x61 && letter <= 0x7a) expect(bytes.single, letter - 0x60);
  });

  property('typing without ctrl sends the text unchanged', (tc) {
    final typed = tc.draw(text(maxLength: 20), name: 'typed');
    final (after, bytes) = const ExtraKeys().type(typed);
    expect(after.ctrl, isFalse);
    expect(bytes, utf8.encode(typed));
  });

  property('every non-modifier key disarms ctrl', (tc) {
    final key = tc.draw(sampledFrom(ExtraKey.values), name: 'key');
    final ctrl = tc.draw(booleans(), name: 'ctrl');
    final app = tc.draw(booleans(), name: 'app');
    final (after, output) = ExtraKeys(ctrl: ctrl).press(key, applicationCursor: app);
    if (key == ExtraKey.ctrl) {
      expect(after.ctrl, !ctrl);
    } else {
      expect(after.ctrl, isFalse);
      if (output is SendBytes) expect(output.bytes, isNotEmpty);
    }
  });

  property('arrows are distinct escape sequences in both cursor modes', (tc) {
    final app = tc.draw(booleans(), name: 'app');
    final ctrl = tc.draw(booleans(), name: 'ctrl');
    const arrows = [ExtraKey.up, ExtraKey.down, ExtraKey.left, ExtraKey.right];
    final encoded = [
      for (final a in arrows) arrowBytes(a, applicationCursor: app, ctrl: ctrl).join(','),
    ];
    expect(encoded.toSet(), hasLength(4));
    for (final a in arrows) {
      final bytes = arrowBytes(a, applicationCursor: app, ctrl: ctrl);
      expect(bytes.first, 0x1b);
      expect(bytes.length, ctrl ? 6 : 3);
    }
  });

  property('a paste cannot carry control sequences or its own end marker', (tc) {
    final clip = tc.draw(
      oneOf([
        text(maxLength: 200),
        lists(
          sampledFrom(const ['\x1b[201~', '\x1b', '\n', '\r\n', 'ls', '\u009b', '\u0007', 'é']),
          maxLength: 20,
        ).map((parts) => parts.join()),
      ]),
      name: 'clip',
    );
    final bracketed = tc.draw(booleans(), name: 'bracketed');
    final bytes = encodePaste(clip, bracketed: bracketed);
    final body = bracketed
        ? bytes.sublist(pasteStart.length, bytes.length - pasteEnd.length)
        : bytes;
    if (bracketed) {
      expect(bytes.sublist(0, pasteStart.length), pasteStart);
      expect(bytes.sublist(bytes.length - pasteEnd.length), pasteEnd);
    }
    expect(body, isNot(contains(0x1b)));
    expect(body, isNot(contains(0x0a)));
    expect(_containsSequence(body, pasteEnd), isFalse);
    final decoded = utf8.decode(body);
    for (final rune in decoded.runes) {
      final control = rune < 0x20 || rune == 0x7f || (rune >= 0x80 && rune <= 0x9f);
      expect(
        !control || rune == 0x09 || rune == 0x0d,
        isTrue,
        reason: 'U+${rune.toRadixString(16)}',
      );
    }
    expect(body.length, lessThanOrEqualTo(maximumPasteBytes));
  });

  test('a long paste is cut at a character boundary', () {
    final bytes = encodePaste('é' * 40000, bracketed: false);
    expect(bytes.length, lessThanOrEqualTo(maximumPasteBytes));
    expect(utf8.decode(bytes), 'é' * (bytes.length ~/ 2));
    expect(encodePaste('a\r\nb\nc', bracketed: false), utf8.encode('a\rb\rc'));
  });
}
