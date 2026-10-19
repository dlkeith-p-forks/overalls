// A public web endpoint in an in-app webview (iOS and Android only). The
// webview never receives Marshall credentials: private endpoints open in
// the system browser instead (Mila plan, section A4).
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/app_localizations.dart';
import '../../ui/widgets.dart';

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key, required this.url});

  /// An HTTPS URL validated by `decodeWebEndpoint`.
  final Uri url;

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  late final WebViewController _controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setNavigationDelegate(
      NavigationDelegate(
        // Only HTTPS pages load inside Mila; any other scheme is refused
        // rather than handed to another app.
        onNavigationRequest: (request) => Uri.tryParse(request.url)?.scheme == 'https'
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
      ),
    )
    ..loadRequest(widget.url);

  @override
  Widget build(BuildContext context) {
    final l = MilaLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: TextButton(
          key: const Key('webview-back'),
          onPressed: () => Navigator.of(context).pop(),
          child: BackGlyph(label: l.back),
        ),
        title: Text(widget.url.host, textDirection: TextDirection.ltr),
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
