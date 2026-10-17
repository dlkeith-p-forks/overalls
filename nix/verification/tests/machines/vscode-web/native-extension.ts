import * as vscode from 'vscode';

declare const process: { readonly env: Record<string, string | undefined> };

const defaults = ['elixir-lsp.elixir-ls', 'EditorConfig.EditorConfig', 'rust-lang.rust-analyzer', 'cab404.vscode-direnv'] as const;

function requireFixture(condition: boolean): void {
  if (!condition) throw new Error('Native policy fixture assertion failed');
}

function extensionVersion(extension: vscode.Extension<unknown>): string {
  const manifest: unknown = extension.packageJSON;
  if (typeof manifest !== 'object' || manifest === null || !('version' in manifest) || typeof manifest.version !== 'string') {
    throw new Error('Native extension manifest invalid');
  }
  return manifest.version;
}

/** @cc [owner:ghuntley,label:verification] fixture-real-rust-compiler-diagnostic
 * Positive Rust acceptance MUST observe the actual language server's published
 * compiler type mismatch E0308. Intrinsic name lookup and arbitrary errors MUST
 * NOT establish that the offline project compiler path works.
 */
function isRustTypeMismatch(diagnostic: vscode.Diagnostic): boolean {
  const code = typeof diagnostic.code === 'object' ? diagnostic.code.value : diagnostic.code;
  return diagnostic.severity === vscode.DiagnosticSeverity.Error
    && diagnostic.source === 'rustc' && code === 'E0308';
}

async function marker(name: string): Promise<void> {
  const folder = vscode.workspace.workspaceFolders?.[0];
  requireFixture(folder !== undefined && vscode.workspace.isTrusted);
  if (!folder) throw new Error('Native fixture workspace required');
  await vscode.workspace.fs.writeFile(vscode.Uri.joinPath(folder.uri, name + '.marker'), new TextEncoder().encode('passed\n'));
  await vscode.window.showInformationMessage('Native fixture ' + name + ' passed');
}

async function waitFor(check: () => boolean, milliseconds = 15000): Promise<void> {
  const deadline = Date.now() + milliseconds;
  while (!check()) {
    requireFixture(Date.now() < deadline);
    await new Promise<void>(resolve => setTimeout(resolve, 50));
  }
}

/**
 * @cc [owner:ghuntley,label:verification] fixture-real-native-defaults
 * Policy checks MUST use the actual extension host's trust/configuration APIs,
 * immutable installed defaults, EditorConfig editor options and direnv's own
 * approval command. No fake language server or injected trust state may supply
 * success. Finite markers MUST be written with the personal filesystem API.
 * Public AI commands MUST exist but return without opening native AI UI; restore
 * resources may refuse with a typed error and MUST leave the same UI absent.
 */
export function activate(context: vscode.ExtensionContext): void {
  for (const [name, id] of [
    ['Chat', 'workbench.action.chat.open'],
    ['Editor', 'workbench.action.openChat'],
    ['Quick', 'workbench.action.openQuickChat'],
    ['Inline', 'inlineChat.start'],
  ] as const) {
    context.subscriptions.push(vscode.commands.registerCommand('overalls.nativeAI' + name, async (): Promise<void> => {
      requireFixture((await vscode.commands.getCommands(true)).includes(id));
      requireFixture(await vscode.commands.executeCommand<unknown>(id) === undefined);
      await marker('native-ai-' + name.toLowerCase());
    }));
  }
  for (const [name, resource] of [
    ['RestoreChat', vscode.Uri.from({ scheme: 'vscode-chat-editor', path: '/chat-1' })],
    ['RestoreSession', vscode.Uri.from({ scheme: 'vscode-chat-session', authority: 'local', path: '/Zml4dHVyZQ' })],
    ['RestoreDebug', vscode.Uri.from({ scheme: 'chat-debug', path: 'default' })],
  ] as const) {
    context.subscriptions.push(vscode.commands.registerCommand('overalls.nativeAI' + name, async (): Promise<void> => {
      try {
        await vscode.commands.executeCommand<unknown>('vscode.open', resource);
      } catch (error: unknown) {
        requireFixture(error instanceof Error);
      }
      await marker('native-ai-' + name.toLowerCase());
    }));
  }
  let toolInvoked = false;
  context.subscriptions.push(vscode.lm.registerTool<Record<string, never>>('overalls_fixture_tool', {
    invoke: (): vscode.LanguageModelToolResult => {
      toolInvoked = true;
      return new vscode.LanguageModelToolResult([new vscode.LanguageModelTextPart('fixture')]);
    },
  }));
  context.subscriptions.push(vscode.commands.registerCommand('overalls.nativePolicy', async (): Promise<void> => {
    requireFixture(vscode.workspace.isTrusted);
    for (const id of defaults) {
      const extension = vscode.extensions.getExtension<unknown>(id);
      requireFixture(extension !== undefined && extension.extensionPath.startsWith('/nix/store/'));
    }
    const rust = vscode.workspace.getConfiguration('rust-analyzer').inspect<string>('server.path');
    const elixir = vscode.workspace.getConfiguration('elixirLS').inspect<string>('languageServerOverridePath');
    requireFixture(rust?.defaultValue === 'rust-analyzer');
    requireFixture(typeof elixir?.defaultValue === 'string' && elixir.defaultValue.startsWith('/nix/store/'));
    requireFixture(vscode.workspace.getConfiguration('rust-analyzer').get<string>('server.path') === rust?.defaultValue);
    requireFixture(vscode.workspace.getConfiguration('elixirLS').get<string>('languageServerOverridePath') === elixir?.defaultValue);
    requireFixture(vscode.workspace.getConfiguration('security.workspace.trust').get<boolean>('enabled') === true);
    requireFixture(vscode.workspace.getConfiguration('chat').get<boolean>('disableAIFeatures') === true);
    requireFixture(vscode.workspace.getConfiguration('workbench').get<boolean>('disableAICustomizations') === true);
    requireFixture((await vscode.lm.selectChatModels({})).length === 0);
    toolInvoked = false;
    let refusal: unknown;
    try {
      await vscode.lm.invokeTool('overalls_fixture_tool', { input: {}, toolInvocationToken: undefined });
    } catch (error: unknown) {
      refusal = error;
    }
    requireFixture(refusal instanceof Error && refusal.message === 'Built-in AI features are disabled in this editor.');
    requireFixture(toolInvoked === false);
    const editorconfig = vscode.extensions.getExtension<unknown>('EditorConfig.EditorConfig');
    if (!editorconfig) throw new Error('EditorConfig fixture unavailable');
    requireFixture(extensionVersion(editorconfig) === '0.18.2');
    await editorconfig.activate();
    const folder = vscode.workspace.workspaceFolders?.[0];
    if (!folder) throw new Error('Native fixture workspace required');
    const document = await vscode.workspace.openTextDocument(vscode.Uri.joinPath(folder.uri, 'indent.txt'));
    const editor = await vscode.window.showTextDocument(document);
    await waitFor(() => editor.options.tabSize === 3 && editor.options.insertSpaces === true);
    await marker('native-policy');
  }));
  context.subscriptions.push(vscode.commands.registerCommand('overalls.nativeDirenv', async (): Promise<void> => {
    requireFixture(vscode.workspace.isTrusted && process.env['OVERALLS_FIXTURE_DIRENV'] === undefined);
    const direnv = vscode.extensions.getExtension<unknown>('cab404.vscode-direnv');
    if (!direnv) throw new Error('Direnv fixture unavailable');
    await direnv.activate();
    requireFixture(process.env['OVERALLS_FIXTURE_DIRENV'] === undefined);
    await vscode.commands.executeCommand('direnv.allow');
    await waitFor(() => process.env['OVERALLS_FIXTURE_DIRENV'] === 'approved');
    await marker('native-direnv');
  }));
  context.subscriptions.push(vscode.commands.registerCommand('overalls.nativeOverrides', async (): Promise<void> => {
    const folder = vscode.workspace.workspaceFolders?.[0];
    if (!folder) throw new Error('Native fixture workspace required');
    const override = vscode.Uri.joinPath(folder.uri, 'project-language-server').fsPath;
    await vscode.workspace.getConfiguration('elixirLS').update('languageServerOverridePath', override, vscode.ConfigurationTarget.Global);
    await vscode.workspace.getConfiguration('rust-analyzer').update('server.path', override, vscode.ConfigurationTarget.Global);
    requireFixture(vscode.workspace.getConfiguration('elixirLS').get<string>('languageServerOverridePath') === override);
    requireFixture(vscode.workspace.getConfiguration('rust-analyzer').get<string>('server.path') === override);
    await marker('native-overrides');
  }));
  context.subscriptions.push(vscode.commands.registerCommand('overalls.nativeDisabled', async (): Promise<void> => {
    requireFixture(vscode.workspace.isTrusted);
    requireFixture(vscode.extensions.getExtension<unknown>('EditorConfig.EditorConfig') === undefined);
    for (const id of defaults.filter(id => id !== 'EditorConfig.EditorConfig')) {
      requireFixture(vscode.extensions.getExtension<unknown>(id) !== undefined);
    }
    await marker('native-disabled');
  }));
  context.subscriptions.push(vscode.commands.registerCommand('overalls.nativeRust', async (): Promise<void> => {
    requireFixture(vscode.workspace.isTrusted);
    const rust = vscode.extensions.getExtension<unknown>('rust-lang.rust-analyzer');
    if (!rust) throw new Error('Rust fixture unavailable');
    await rust.activate();
    const folder = vscode.workspace.workspaceFolders?.[0];
    if (!folder) throw new Error('Native fixture workspace required');
    const document = await vscode.workspace.openTextDocument(vscode.Uri.joinPath(folder.uri, 'src/main.rs'));
    await vscode.window.showTextDocument(document);
    await waitFor(() => vscode.languages.getDiagnostics(document.uri).some(isRustTypeMismatch), 45000);
    await marker('native-rust');
  }));
  context.subscriptions.push(vscode.commands.registerCommand('overalls.nativeElixir', async (): Promise<void> => {
    requireFixture(vscode.workspace.isTrusted);
    const elixir = vscode.extensions.getExtension<unknown>('elixir-lsp.elixir-ls');
    if (!elixir) throw new Error('Elixir fixture unavailable');
    await elixir.activate();
    const folder = vscode.workspace.workspaceFolders?.[0];
    if (!folder) throw new Error('Native fixture workspace required');
    const document = await vscode.workspace.openTextDocument(vscode.Uri.joinPath(folder.uri, 'lib/fixture.ex'));
    await vscode.window.showTextDocument(document);
    await waitFor(() => vscode.languages.getDiagnostics(document.uri).some(item => item.severity === vscode.DiagnosticSeverity.Error && item.source?.startsWith('Elixir') === true), 45000);
    await marker('native-elixir');
  }));
  context.subscriptions.push(vscode.commands.registerCommand('overalls.nativeVersion', async (): Promise<void> => {
    requireFixture(vscode.workspace.isTrusted);
    const extension = vscode.extensions.getExtension<unknown>('EditorConfig.EditorConfig');
    if (!extension) throw new Error('Personal extension fixture unavailable');
    const personalHome = process.env['HOME'];
    requireFixture(typeof personalHome === 'string' && /^\/home\/[a-z_][a-z0-9_-]*$/.test(personalHome));
    requireFixture(extensionVersion(extension) === '0.18.3' && extension.extensionPath.startsWith(personalHome + '/'));
    await marker('native-version');
  }));
}
