import * as vscode from 'vscode';

/**
 * @cc [owner:ghuntley,label:verification] fixture-web-only-activation
 * The fixture MUST have only a browser entry. Its command MUST write through
 * the real workspace filesystem API and display a fixed activation notice.
 */
export function activate(context: vscode.ExtensionContext): void {
  context.subscriptions.push(vscode.commands.registerCommand('overalls.browserFixture', async (): Promise<void> => {
    const folder = vscode.workspace.workspaceFolders?.[0];
    if (!folder) throw new Error('Fixture workspace required');
    const marker = vscode.Uri.joinPath(folder.uri, 'web-extension.marker');
    await vscode.workspace.fs.writeFile(marker, new TextEncoder().encode('Browser-only extension activated\n'));
    await vscode.window.showInformationMessage('Browser-only extension activated');
  }));
}
