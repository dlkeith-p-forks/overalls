# Fixed SYSTEM TCP task action. The broker validates MMDS, gateway and preface
# admission; the independently supervised custodian owns worker admission/jobs.
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
try {
    . 'C:\overalls\editor-broker\custody.ps1'
    Assert-EditorSystem
    Assert-EditorPath -Path 'C:\overalls\editor-broker\broker.json'
    Assert-EditorPath -Path 'C:\overalls\editor-broker\overalls-vscode-web-broker.exe'
    Assert-EditorPath -Path 'C:\overalls\editor-state' -Private $true
    [System.Diagnostics.Stopwatch]$Waiting = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath 'C:\overalls\trust\current')) {
        if ($Waiting.Elapsed.TotalMinutes -ge 10) { throw 'editor_trust_unavailable' }
        Start-Sleep -Seconds 2
    }
    Assert-EditorPath -Path 'C:\overalls\trust\current'
    if ((Get-Item -LiteralPath 'C:\overalls\trust\current').Length -ne 71) { throw 'editor_trust_pointer_invalid' }
    [string]$Bundle = [System.IO.File]::ReadAllText('C:\overalls\trust\current')
    if ($Bundle -cnotmatch '^bundle-[0-9a-f]{64}$') { throw 'editor_trust_pointer_invalid' }
    [string]$Certificate = 'C:\overalls\trust\' + $Bundle + '\ca-bundle.pem'
    Assert-EditorPath -Path $Certificate
    [System.IO.FileInfo]$CertificateFile = Get-Item -LiteralPath $Certificate
    if ($CertificateFile.Length -lt 1 -or $CertificateFile.Length -gt 4194304) { throw 'editor_trust_bundle_invalid' }
    Copy-Item -LiteralPath $Certificate -Destination 'C:\overalls\editor-broker\ca-bundle.pem' -Force
    Assert-EditorPath -Path 'C:\overalls\editor-broker\ca-bundle.pem'
    & 'C:\overalls\editor-broker\overalls-vscode-web-broker.exe' 'C:\overalls\editor-broker\broker.json'
    # @cc [owner:ghuntley,label:recovery] windows-editor-retryable-task-failure
    # Native success MUST remain zero. Every nonzero native status, including
    # forced termination's -1, MUST become ordinary task failure 1 for the
    # unchanged Task Scheduler restart policy; no status may become success.
    if ($LASTEXITCODE -eq 0) { exit 0 }
    exit 1
} catch {
    # Never render exception text: it can contain account, path or input data.
    [Console]::Error.WriteLine('{"service":"windows-editor-broker","event":"startup_refused"}')
    exit 1
}
