import * as vscode from 'vscode';

declare const process: { readonly platform: string; readonly env: Record<string, string | undefined> };

function requireFixture(condition: boolean): asserts condition {
  if (!condition) throw new Error('Windows editor fixture refused');
}

interface Fixture {
  readonly username: string;
  readonly sid: string;
  readonly workspace: string;
}

function fixture(value: unknown): Fixture {
  requireFixture(typeof value === 'object' && value !== null);
  requireFixture('username' in value && typeof value.username === 'string' && /^u[0-9]{6,10}$/.test(value.username));
  requireFixture('sid' in value && typeof value.sid === 'string' && /^S-1-5-21-(?:[0-9]+-){3}[0-9]+$/.test(value.sid));
  requireFixture('workspace' in value && typeof value.workspace === 'string' && /^C:\\workspace\\overalls-editor-acceptance-[a-f0-9]{12}$/.test(value.workspace));
  requireFixture(Object.keys(value).length === 3);
  return { username: value.username, sid: value.sid, workspace: value.workspace };
}

async function waitForFile(uri: vscode.Uri): Promise<Uint8Array> {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    try { return await vscode.workspace.fs.readFile(uri); } catch { /* bounded native file wait */ }
    await new Promise<void>(resolve => setTimeout(resolve, 100));
  }
  throw new Error('Windows terminal fixture deadline');
}

/** @cc [owner:ghuntley,label:verification] windows-editor-real-personal-native-host
 * Success MUST use the native Windows extension host, its actual personal HOME,
 * trusted outside-HOME workspace, real saved document and a real PowerShell PTY.
 * The terminal MUST report the exact fixture SAM SID before the success notice.
 * Conflicting personal trust/AI settings MUST NOT enable a trust prompt or AI.
 */
export function activate(context: vscode.ExtensionContext): void {
  context.subscriptions.push(vscode.commands.registerCommand('overalls.windowsAcceptance', async (): Promise<void> => {
    const expected = fixture(JSON.parse(new TextDecoder().decode(await vscode.workspace.fs.readFile(vscode.Uri.joinPath(context.extensionUri, 'fixture.json')))));
    requireFixture(process.platform === 'win32' && process.env['USERNAME']?.toLowerCase() === expected.username);
    const home = process.env['USERPROFILE'];
    requireFixture(typeof home === 'string' && process.env['HOME'] === home && !expected.workspace.toLowerCase().startsWith(home.toLowerCase() + '\\'));
    const folder = vscode.workspace.workspaceFolders?.[0];
    requireFixture(folder !== undefined && folder.uri.fsPath.toLowerCase() === expected.workspace.toLowerCase());
    requireFixture(vscode.workspace.isTrusted);
    requireFixture(vscode.workspace.getConfiguration('security.workspace.trust').get<boolean>('enabled') === true);
    requireFixture(vscode.workspace.getConfiguration('chat').get<boolean>('disableAIFeatures') === true);
    requireFixture(vscode.workspace.getConfiguration('workbench').get<boolean>('disableAICustomizations') === true);
    const uri = vscode.Uri.joinPath(folder.uri, 'saved.txt');
    const document = await vscode.workspace.openTextDocument(uri);
    const editor = await vscode.window.showTextDocument(document);
    if (document.getText() !== 'windows-editor-saved\r\n') {
      requireFixture(await editor.edit(edit => edit.replace(new vscode.Range(0, 0, document.lineCount, 0), 'windows-editor-saved\r\n')));
      requireFixture(await document.save());
    }
    requireFixture(new TextDecoder().decode(await vscode.workspace.fs.readFile(uri)) === 'windows-editor-saved\r\n');
    const terminal = vscode.window.createTerminal({ name: 'overalls-windows-acceptance', cwd: folder.uri.fsPath, shellPath: 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe', shellArgs: ['-NoProfile'] });
    terminal.show();
    const output = vscode.Uri.joinPath(folder.uri, 'terminal.json');
    try { await vscode.workspace.fs.delete(output); } catch { /* first invocation has no marker */ }
    terminal.sendText("[IO.File]::WriteAllText('" + output.fsPath + "', ( @{sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value; username=$env:USERNAME} | ConvertTo-Json -Compress )); Write-Output 'WINDOWS-EDITOR-PTY-PASSED'", true);
    const result: unknown = JSON.parse(new TextDecoder().decode(await waitForFile(output)));
    requireFixture(typeof result === 'object' && result !== null && 'sid' in result && result.sid === expected.sid && 'username' in result && typeof result.username === 'string' && result.username.toLowerCase() === expected.username);
    await vscode.window.showInformationMessage('Windows native editor acceptance passed');
  }));
}
