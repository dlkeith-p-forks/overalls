param(
    [Parameter(Mandatory = $true)][ValidateSet('setup', 'snapshot', 'kill-broker', 'kill-worker')][string]$Operation,
    [Parameter(Mandatory = $true)][ValidateRange(200000, 2147483647)][int]$Uid,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{12}$')][string]$RunId,
    [switch]$SystemStage
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
[string]$Root = 'C:\overalls\editor-acceptance\' + $RunId
[string]$Output = $Root + '\result.json'
[string]$Username = 'u' + $Uid
[string]$Workspace = 'C:\workspace\overalls-editor-acceptance-' + $RunId

function Assert-PlainTree {
    [OutputType([void])]
    param([Parameter(Mandatory = $true)][string]$Path)
    [System.IO.FileSystemInfo]$Item = Get-Item -LiteralPath $Path -Force
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'fixture_reparse' }
    [System.IO.DirectoryInfo]$Parent = $null
    if ($Item -is [IO.DirectoryInfo]) { $Parent = $Item.Parent } else { $Parent = $Item.Directory }
    if ($null -ne $Parent) { Assert-PlainTree -Path $Parent.FullName }
}

# @cc [owner:ghuntley,label:verification;security] windows-editor-system-fixture-control
# The administrator adapter MUST execute only this fixture's closed operation
# as SYSTEM, using an administrator/SYSTEM-only script directory and task. It
# MUST NOT change the production broker task, credential or account authorizer.
if (-not $SystemStage) {
    [Security.Principal.WindowsPrincipal]$Principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'fixture_administrator_required' }
    Assert-PlainTree -Path $Root
    & icacls.exe $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T /q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'fixture_acl_failed' }
    [string]$TaskName = 'EditorAcceptance-' + $RunId
    [string]$Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + $Root + '\control.ps1 -Operation ' + $Operation + ' -Uid ' + $Uid + ' -RunId ' + $RunId + ' -SystemStage'
    [void](Remove-Item -LiteralPath $Output -Force -ErrorAction SilentlyContinue)
    $Action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument $Arguments
    $TaskPrincipal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    [void](Register-ScheduledTask -TaskPath '\Overalls\' -TaskName $TaskName -Action $Action -Principal $TaskPrincipal -Force)
    try {
        Start-ScheduledTask -TaskPath '\Overalls\' -TaskName $TaskName
        [datetime]$Deadline = [datetime]::UtcNow.AddSeconds(120)
        while (-not (Test-Path -LiteralPath $Output)) {
            if ([datetime]::UtcNow -ge $Deadline) { throw 'fixture_task_deadline' }
            Start-Sleep -Milliseconds 200
        }
        [string]$Result = Get-Content -LiteralPath $Output -Raw
        [pscustomobject]$Parsed = $Result | ConvertFrom-Json
        if ($Parsed.ok -ne $true) { throw 'fixture_operation_failed' }
        Write-Output $Result
    } finally {
        Unregister-ScheduledTask -TaskPath '\Overalls\' -TaskName $TaskName -Confirm:$false
    }
    exit 0
}

function Get-FixtureAccountSid {
    [OutputType([Security.Principal.SecurityIdentifier])]
    param()
    $Account = Get-LocalUser -Name $Username
    if (-not $Account.Enabled -or $Account.Name -cne $Username -or
        $Account.SID.Value -notmatch '^S-1-5-21-(\d+-){3}\d+$') { throw 'fixture_account_invalid' }
    return [Security.Principal.SecurityIdentifier]$Account.SID
}

function Get-FixtureBroker {
    [OutputType([Microsoft.Management.Infrastructure.CimInstance])]
    param()
    [object[]]$Matches = @(Get-CimInstance Win32_Process -Filter "Name='overalls-vscode-web-broker.exe'" | Where-Object {
        $_.ExecutablePath -ceq 'C:\overalls\editor-broker\overalls-vscode-web-broker.exe'
    })
    if ($Matches.Count -ne 1) { throw 'fixture_broker_count' }
    $Owner = Invoke-CimMethod -InputObject $Matches[0] -MethodName GetOwnerSid
    if ($Owner.ReturnValue -ne 0 -or $Owner.Sid -cne 'S-1-5-18') { throw 'fixture_broker_sid' }
    return $Matches[0]
}

function Test-CustodyRefusal {
    [OutputType([void])]
    param([Parameter(Mandatory = $true)][string]$Path, [bool]$Private = $false)
    [bool]$Refused = $false
    try { Assert-EditorPath -Path $Path -Private $Private } catch { $Refused = $true }
    if (-not $Refused) { throw 'fixture_custody_refusal_missing' }
}

function Set-FixtureAcl {
    [OutputType([void])]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Sddl)
    [System.Security.AccessControl.FileSystemSecurity]$Acl = Get-Acl -LiteralPath $Path
    $Acl.SetSecurityDescriptorSddlForm($Sddl)
    Set-Acl -LiteralPath $Path -AclObject $Acl
}

# @cc [owner:ghuntley,label:verification;security] windows-editor-native-custody-refusals
# SYSTEM's disposable fixture MUST accept public SYSTEM/Administrators full and
# Users RX, reject foreign write and non-SYSTEM private access, and permit the
# exact TrustedInstaller SID only on ancestors. Production ACLs MUST NOT change.
function Test-FixtureCustody {
    [OutputType([void])]
    param()
    [string]$Tree = $Root + '\custody'
    [string]$Leaf = $Tree + '\package'
    [void](New-Item -ItemType Directory -Path $Leaf)
    [string]$Public = 'O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)'
    [string]$TrustedInstaller = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    Set-FixtureAcl -Path $Tree -Sddl $Public
    Set-FixtureAcl -Path $Leaf -Sddl $Public
    Assert-EditorPath -Path $Leaf
    Set-FixtureAcl -Path $Leaf -Sddl ($Public + '(A;;FW;;;BU)')
    Test-CustodyRefusal -Path $Leaf
    Set-FixtureAcl -Path $Leaf -Sddl 'O:SYG:SYD:P(A;OICI;FA;;;SY)'
    Assert-EditorPath -Path $Leaf -Private $true
    Set-FixtureAcl -Path $Leaf -Sddl 'O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FR;;;BA)'
    Test-CustodyRefusal -Path $Leaf -Private $true
    Set-FixtureAcl -Path $Leaf -Sddl ($Public + '(A;;FA;;;' + $TrustedInstaller + ')')
    Test-CustodyRefusal -Path $Leaf
    Set-FixtureAcl -Path $Leaf -Sddl $Public
    Set-FixtureAcl -Path $Tree -Sddl ($Public + '(A;;FA;;;' + $TrustedInstaller + ')')
    Assert-EditorPath -Path $Leaf
    Remove-Item -LiteralPath $Tree -Recurse -Force
}

function Read-FixtureMetadata {
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][bool]$Token, [string]$SessionToken = '')
    [string]$Endpoint = 'http://169.254.169.254/'
    if ($Token) { $Endpoint += 'latest/api/token' } else { $Endpoint += 'lilly' }
    [Net.HttpWebRequest]$Request = [Net.WebRequest]::Create($Endpoint)
    $Request.Proxy = $null
    $Request.AllowAutoRedirect = $false
    $Request.Timeout = 5000
    $Request.ReadWriteTimeout = 5000
    if ($Token) {
        $Request.Method = 'PUT'
        $Request.ContentLength = 0
        $Request.Headers.Add('X-metadata-token-ttl-seconds', '60')
    } else {
        $Request.Accept = 'application/json'
        $Request.Headers.Add('X-metadata-token', $SessionToken)
    }
    [Net.HttpWebResponse]$Response = $Request.GetResponse()
    try {
        [int]$Bound = 8192
        if ($Token) { $Bound = 512 }
        if ($Response.StatusCode -ne [Net.HttpStatusCode]::OK -or
            $Response.ContentLength -le 0 -or $Response.ContentLength -gt $Bound) { throw 'fixture_metadata_bound' }
        [IO.Stream]$Stream = $Response.GetResponseStream()
        [byte[]]$Bytes = New-Object byte[] ([int]$Response.ContentLength)
        [int]$Count = 0
        while ($Count -lt $Bytes.Length) {
            [int]$Read = $Stream.Read($Bytes, $Count, ($Bytes.Length - $Count))
            if ($Read -le 0) { throw 'fixture_metadata_truncated' }
            $Count += $Read
        }
        return [Text.Encoding]::ASCII.GetString($Bytes)
    } finally { $Response.Dispose() }
}

# @cc [owner:ghuntley,label:verification;security] windows-editor-exact-physical-boot-receipt
# Receipt lookup MUST derive the exact current physical-boot namespace from
# fresh fixed-endpoint MMDS v2 metadata and the current binding. It MUST NOT
# select a prior boot by directory age or expose metadata/token/challenge bytes.
function Get-FixtureReceiptPath {
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][pscustomobject]$Binding)
    [string]$Token = Read-FixtureMetadata -Token $true
    if ($Token -notmatch '^[a-zA-Z0-9=/+_-]{1,512}$') { throw 'fixture_metadata_token' }
    [pscustomobject]$Metadata = Read-FixtureMetadata -Token $false -SessionToken $Token | ConvertFrom-Json
    if (@($Metadata.PSObject.Properties).Count -ne 8 -or $Metadata.version -ne 1 -or
        $Metadata.placement -cne $Binding.placement_id -or
        $Metadata.execution_epoch -ne $Binding.execution_epoch -or
        $Metadata.boot_challenge -cnotmatch '^[a-f0-9]{64}$') { throw 'fixture_metadata_identity' }
    [IO.MemoryStream]$InputBytes = New-Object IO.MemoryStream
    [Security.Cryptography.SHA256]$Hash = [Security.Cryptography.SHA256]::Create()
    try {
        [byte[]]$Domain = [Text.Encoding]::ASCII.GetBytes("overalls-windows-editor-physical-boot-v1`0")
        [byte[]]$Placement = [Text.Encoding]::ASCII.GetBytes($Metadata.placement)
        [byte[]]$Epoch = [BitConverter]::GetBytes([uint64]$Metadata.execution_epoch)
        if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($Epoch) }
        [byte[]]$Challenge = [Text.Encoding]::ASCII.GetBytes($Metadata.boot_challenge)
        foreach ($Part in @($Domain, $Placement, $Epoch, $Challenge)) { $InputBytes.Write($Part, 0, $Part.Length) }
        [string]$Key = ([BitConverter]::ToString($Hash.ComputeHash($InputBytes.ToArray()))).Replace('-', '').ToLowerInvariant()
        return 'C:\overalls\editor-state\b' + $Key + '\u' + $Uid + '\worker.json'
    } finally { $Hash.Dispose(); $InputBytes.Dispose() }
}

function Get-FixtureWorker {
    [OutputType([pscustomobject])]
    param()
    . 'C:\overalls\editor-broker\custody.ps1'
    [pscustomobject]$Binding = Get-Content -LiteralPath ($Root + '\binding.json') -Raw | ConvertFrom-Json
    [string]$ReceiptPath = Get-FixtureReceiptPath -Binding $Binding.binding
    Assert-EditorPath -Path ([IO.Path]::GetDirectoryName($ReceiptPath)) -Private $true
    Assert-EditorPath -Path $ReceiptPath -Private $true
    [pscustomobject]$Receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json
    foreach ($Property in $Binding.binding.PSObject.Properties) {
        if ($Property.Name -in @('session_id', 'generation')) { continue }
        if ($Receipt.binding.($Property.Name) -cne $Property.Value) { throw 'fixture_receipt_binding' }
    }
    if (@($Receipt.binding.PSObject.Properties).Count -ne 17) { throw 'fixture_receipt_shape' }
    [uint32]$WorkerPid = $Receipt.process.pid
    [uint64]$Created = $Receipt.process.created
    [Diagnostics.Process]$Process = Get-Process -Id $WorkerPid
    [Microsoft.Management.Infrastructure.CimInstance]$Native = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $WorkerPid)
    [string]$Sid = (Get-FixtureAccountSid).Value
    $Owner = Invoke-CimMethod -InputObject $Native -MethodName GetOwnerSid
    if ($Owner.ReturnValue -ne 0 -or $Owner.Sid -cne $Sid -or
        $Native.ExecutablePath -cne 'C:\overalls\editor\node.exe' -or
        [uint64]$Process.StartTime.ToFileTimeUtc() -ne $Created) { throw 'fixture_worker_custody' }
    [System.Text.RegularExpressions.Match]$PipeMatch = [regex]::Match($Native.CommandLine, '\\\\\.\\pipe\\(overalls-editor-' + $Uid + '-[a-f0-9]{64})')
    if (-not $PipeMatch.Success) { throw 'fixture_pipe_name' }
    if (-not ('OverallsAcceptancePipe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class OverallsAcceptancePipe {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint pid);
}
'@
    }
    [IO.Pipes.NamedPipeClientStream]$Pipe = New-Object IO.Pipes.NamedPipeClientStream('.', $PipeMatch.Groups[1].Value, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $Pipe.Connect(5000)
        [uint32]$ServerPid = 0
        if (-not [OverallsAcceptancePipe]::GetNamedPipeServerProcessId($Pipe.SafePipeHandle, [ref]$ServerPid) -or $ServerPid -ne $WorkerPid) { throw 'fixture_pipe_peer' }
    } finally { $Pipe.Dispose() }
    return [pscustomobject]@{worker_pid=$WorkerPid; worker_created=$Created; sid=$Sid}
}

function Invoke-FixtureOperation {
    [OutputType([pscustomobject])]
    param()
    if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne 'S-1-5-18') { throw 'fixture_system_required' }
    Assert-PlainTree -Path $Root
    [string]$Sid = (Get-FixtureAccountSid).Value
    if ($Operation -eq 'setup') {
        . 'C:\overalls\editor-broker\custody.ps1'
        Test-FixtureCustody
        Assert-EditorPath -Path 'C:\overalls\editor-broker\broker.json'
        [pscustomobject]$Configuration = Get-Content -LiteralPath 'C:\overalls\editor-broker\broker.json' -Raw | ConvertFrom-Json
        if ($Configuration.account_authorizer -cne 'C:\overalls\agents\overalls-ssh-sync-windows.exe') { throw 'fixture_real_authorizer_required' }
        [string]$Profile = (Get-ItemProperty -LiteralPath ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $Sid)).ProfileImagePath
        if ($Profile -cne ('C:\Users\' + $Username)) { throw 'fixture_profile_invalid' }
        [string]$Data = $Profile + '\.overalls-code-server'
        if ((Test-Path -LiteralPath $Data) -or (Test-Path -LiteralPath $Workspace)) { throw 'fixture_fresh_account_required' }
        [string]$Extension = $Data + '\extensions\overalls.windows-native-acceptance-0.0.1'
        [void](New-Item -ItemType Directory -Path $Extension)
        Copy-Item -LiteralPath ($Root + '\extension.js') -Destination ($Extension + '\extension.js')
        Copy-Item -LiteralPath ($Root + '\package.json') -Destination ($Extension + '\package.json')
        [void](New-Item -ItemType Directory -Path ($Data + '\data\User') -Force)
        [IO.File]::WriteAllText(($Data + '\data\User\settings.json'), '{"security.workspace.trust.enabled":true,"security.workspace.trust.startupPrompt":"always","chat.disableAIFeatures":false,"workbench.disableAICustomizations":false}')
        [void](New-Item -ItemType Directory -Path $Workspace)
        [IO.File]::WriteAllText(($Workspace + '\saved.txt'), '')
        [IO.File]::WriteAllText(($Extension + '\fixture.json'), (@{username=$Username; sid=$Sid; workspace=$Workspace} | ConvertTo-Json -Compress))
        foreach ($Tree in @($Data, $Workspace)) {
            & icacls.exe $Tree /inheritance:r /grant:r ($Sid + ':(OI)(CI)F') '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T /q | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'fixture_personal_acl_failed' }
            & icacls.exe $Tree /setowner $Sid /T /q | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'fixture_personal_owner_failed' }
        }
        return [pscustomobject]@{ok=$true; operation=$Operation; sid=$Sid}
    }
    [pscustomobject]$Worker = Get-FixtureWorker
    [Microsoft.Management.Infrastructure.CimInstance]$Broker = Get-FixtureBroker
    if ($Operation -eq 'kill-broker') {
        Stop-Process -Id $Broker.ProcessId -Force
        [datetime]$Deadline = [datetime]::UtcNow.AddSeconds(100)
        do {
            Start-Sleep -Milliseconds 500
            try { $Replacement = Get-FixtureBroker } catch { $Replacement = $null }
            if ([datetime]::UtcNow -ge $Deadline) { throw 'fixture_broker_recovery_deadline' }
        } while ($null -eq $Replacement -or $Replacement.ProcessId -eq $Broker.ProcessId)
        [pscustomobject]$Retained = Get-FixtureWorker
        if ($Retained.worker_pid -ne $Worker.worker_pid -or $Retained.worker_created -ne $Worker.worker_created) { throw 'fixture_worker_not_retained' }
    } elseif ($Operation -eq 'kill-worker') {
        Stop-Process -Id $Worker.worker_pid -Force
        return [pscustomobject]@{ok=$true; operation=$Operation; worker_pid=$Worker.worker_pid; worker_created=$Worker.worker_created; sid=$Sid}
    }
    [bool]$Saved = (Test-Path -LiteralPath ($Workspace + '\saved.txt')) -and ([IO.File]::ReadAllText($Workspace + '\saved.txt') -ceq "windows-editor-saved`r`n")
    if (-not $Saved) { throw 'fixture_saved_data_missing' }
    [pscustomobject]$Terminal = Get-Content -LiteralPath ($Workspace + '\terminal.json') -Raw | ConvertFrom-Json
    if ($Terminal.sid -cne $Sid -or $Terminal.username -cne $Username) { throw 'fixture_terminal_identity' }
    return [pscustomobject]@{ok=$true; operation=$Operation; worker_pid=$Worker.worker_pid; worker_created=$Worker.worker_created; sid=$Sid; saved=$Saved}
}

try {
    [pscustomobject]$Result = Invoke-FixtureOperation
    [IO.File]::WriteAllText($Output + '.tmp', ($Result | ConvertTo-Json -Compress))
} catch {
    [IO.File]::WriteAllText($Output + '.tmp', '{"ok":false,"reason":"fixture_operation_failed"}')
}
[IO.File]::Move($Output + '.tmp', $Output)
