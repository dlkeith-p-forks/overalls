import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mila/integration_probe.dart';

void main() {
  testWidgets('the probe reports keyed rectangles and visible text only', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(
          children: [
            SizedBox(key: Key('shown'), width: 40, height: 20),
            Text('visible'),
            SelectableText('SHA256:abc'),
            Offstage(child: Text('hidden', key: Key('covered'))),
          ],
        ),
      ),
    );
    final state = observe('/route');
    expect(state.route, '/route');
    final ratio = state.devicePixelRatio;
    expect(state.keys['shown'], [380 * ratio, 0.0, 40 * ratio, 20 * ratio]);
    expect(state.keys.containsKey('covered'), isFalse);
    expect(state.texts, containsAll(['visible', 'SHA256:abc']));
    expect(state.texts, isNot(contains('hidden')));
    final decoded = jsonDecode(encodeProbe(state)) as Map<String, Object?>;
    expect(decoded.keys, unorderedEquals(['route', 'keys', 'texts', 'device_pixel_ratio']));
  });
}
