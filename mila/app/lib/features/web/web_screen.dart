import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

import '../../l10n/app_localizations.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../machines/machine_tabs.dart';
import '../sign_in_screen.dart' show openExternalProvider;
import 'web_controller.dart';
import 'webview_screen.dart';

/// A machine's web endpoint: open, copy or share its address, and change
/// its port and visibility.
class WebScreen extends ConsumerStatefulWidget {
  const WebScreen({super.key, required this.deployment, required this.machineId});

  final Deployment deployment;
  final String machineId;

  @override
  ConsumerState<WebScreen> createState() => _WebScreenState();
}

class _WebScreenState extends ConsumerState<WebScreen> {
  final TextEditingController _port = TextEditingController();
  bool _portInvalid = false;

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  Future<void> _open(WebEndpoint endpoint) async {
    final url = endpoint.url;
    if (url == null) return;
    switch (webOpening(endpoint, inAppWebView: ref.read(inAppWebViewProvider))) {
      case WebOpening.inApp:
        await Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (context) => WebViewScreen(url: url)));
      case WebOpening.externalBrowser:
        // Private endpoints authorize through the browser's Marshall session.
        await ref.read(openExternalProvider)(url);
      case WebOpening.unavailable:
        break;
    }
  }

  Future<void> _copy(Uri url) async {
    await Clipboard.setData(ClipboardData(text: url.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(MilaLocalizations.of(context).webCopied)));
  }

  @override
  Widget build(BuildContext context) {
    final l = MilaLocalizations.of(context);
    final key = (widget.deployment, widget.machineId);
    final view = ref.watch(webProvider(key));
    final controller = ref.read(webProvider(key).notifier);
    final endpoint = view.endpoint;
    final share = ref.watch(shareLinkProvider);
    return MachineScaffold(
      deployment: widget.deployment,
      machineId: widget.machineId,
      tab: MachineTab.web,
      actions: [
        TextButton(
          key: const Key('web-refresh'),
          onPressed: controller.refresh,
          child: Text(l.refresh.toUpperCase()),
        ),
      ],
      children: [
        if (view.failed && endpoint == null) Text(l.webFailed, key: const Key('web-failed')),
        if (endpoint != null) ...[
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Kv(
                  l.webVisibility,
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: StatusLabel(
                      endpoint.visibility == WebVisibility.public ? l.webPublic : l.webPrivate,
                      key: const Key('web-visibility'),
                    ),
                  ),
                ),
                Kv(l.webPort, Text('${endpoint.port}', textDirection: TextDirection.ltr)),
                if (endpoint.url != null)
                  Kv(
                    l.webAddress,
                    SelectableText(
                      endpoint.url.toString(),
                      key: const Key('web-url'),
                      textDirection: TextDirection.ltr,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: MonoScale.line / 2),
          Text(
            endpoint.visibility == WebVisibility.public ? l.webPublicExplain : l.webPrivateExplain,
          ),
          if (endpoint.url == null) Text(l.webNoAddress),
          const SizedBox(height: MonoScale.line / 2),
          Wrap(
            spacing: MonoScale.fontSize / 2,
            runSpacing: MonoScale.line / 2,
            children: [
              ConsoleButton(
                key: const Key('web-open'),
                label: l.webOpen,
                glyph: Glyph.arrowUpRight,
                onPressed: endpoint.url == null ? null : () => _open(endpoint),
              ),
              ConsoleButton(
                key: const Key('web-copy'),
                label: l.webCopy,
                onPressed: endpoint.url == null ? null : () => _copy(endpoint.url!),
              ),
              if (share != null)
                ConsoleButton(
                  key: const Key('web-share'),
                  label: l.webShare,
                  onPressed: endpoint.url == null ? null : () => share(endpoint.url!),
                ),
            ],
          ),
          const SizedBox(height: MonoScale.line),
          Panel(
            title: l.webSettings,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Segmented<WebVisibility>(
                  keyPrefix: 'web-visibility',
                  options: WebVisibility.values,
                  selected: endpoint.visibility,
                  label: (v) => v == WebVisibility.public ? l.webPublic : l.webPrivate,
                  onSelected: view.saving ? null : (v) => controller.change(visibility: v),
                ),
                const SizedBox(height: MonoScale.line / 2),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('web-port'),
                        controller: _port,
                        keyboardType: TextInputType.number,
                        textDirection: TextDirection.ltr,
                        decoration: InputDecoration(
                          labelText: l.webPort,
                          hintText: '${endpoint.port}',
                          errorText: _portInvalid ? l.webPortInvalid : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: MonoScale.fontSize / 2),
                    ConsoleButton(
                      key: const Key('web-port-save'),
                      label: l.webSave,
                      onPressed: view.saving
                          ? null
                          : () {
                              final port = parsePort(_port.text);
                              setState(() => _portInvalid = port == null);
                              if (port != null) controller.change(port: port);
                            },
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (view.saving) Text(l.requestWaiting),
          if (view.failure != null)
            Text(
              switch (view.failure!) {
                WebChangeFailure.conflict => l.webConflict,
                WebChangeFailure.refused => l.requestRefused,
                WebChangeFailure.failed => l.requestFailed,
              },
              key: const Key('web-change-failed'),
              style: const TextStyle(fontWeight: MonoScale.bold),
            ),
        ],
      ],
    );
  }
}
