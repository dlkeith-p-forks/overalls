// The integration flavour's view of the running app, for the mila-desktop
// machine test (`--dart-define=MILA_INTEGRATION=true`). It writes the current
// route, the screen rectangle of every keyed widget and the visible plain
// texts to an owner-only JSON file so the driver can click real widgets with
// real X input and assert what is shown. Release and demo builds do not
// compile it in: `main` only reaches it behind a const flag.

// @cc [owner:ghuntley,label:verification;security] mila-integration-probe-scope
// The probe MUST only report what the screen already shows (route, widget
// keys, rectangles and Text/SelectableText strings). It MUST NOT read providers holding
// credentials, keys, push tokens or terminal bytes, and MUST NOT accept input.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mila_transport/mila_transport.dart';

import 'app.dart';

/// One observation of the screen.
typedef ProbeState = ({
  String route,
  Map<String, List<double>> keys,
  List<String> texts,
  double devicePixelRatio,
});

/// Collects keyed widget rectangles (physical pixels, relative to the view)
/// and Text strings from the live element tree.
ProbeState observe(String route) {
  final keys = <String, List<double>>{};
  final texts = <String>[];
  final view = WidgetsBinding.instance.platformDispatcher.implicitView;
  final ratio = view?.devicePixelRatio ?? 1;
  void visit(Element element) {
    final widget = element.widget;
    final key = widget.key;
    if (key is ValueKey<String>) {
      final render = element.renderObject;
      if (render is RenderBox && render.attached && render.hasSize) {
        final origin = render.localToGlobal(Offset.zero);
        keys[key.value] = [
          origin.dx * ratio,
          origin.dy * ratio,
          render.size.width * ratio,
          render.size.height * ratio,
        ];
      }
    }
    final text = switch (widget) {
      Text(:final data) => data,
      SelectableText(:final data) => data,
      _ => null,
    };
    if (text != null && texts.length < 200) texts.add(text);
    // Offstage subtrees (the content under the app lock) are not shown.
    if (widget is Offstage && widget.offstage) return;
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return (route: route, keys: keys, texts: texts, devicePixelRatio: ratio);
}

String encodeProbe(ProbeState state) => jsonEncode({
  'route': state.route,
  'keys': state.keys,
  'texts': state.texts,
  'device_pixel_ratio': state.devicePixelRatio,
});

/// Writes an observation after every frame, at most every 200 ms.
void startProbe(ProviderContainer container, String path) {
  final file = File(path);
  var last = '';
  var writing = false;
  Timer.periodic(const Duration(milliseconds: 200), (_) async {
    if (writing) return;
    final router = container.read(routerProvider);
    final route = router.routerDelegate.currentConfiguration.uri.toString();
    final encoded = encodeProbe(observe(route));
    if (encoded == last) return;
    writing = true;
    try {
      await writeOwnerOnly(file.parent, file.uri.pathSegments.last, utf8.encode(encoded));
      last = encoded;
    } finally {
      writing = false;
    }
  });
}
