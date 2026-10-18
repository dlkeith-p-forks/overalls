# Candidate-only image installation. Task Scheduler supplies boot and failure
# supervision; this console broker does not claim an SCM service entry point.
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
. 'C:\overalls\editor-broker\custody.ps1'
Assert-EditorSystem

function Set-EditorAcl {
    [OutputType([void])]
    param([Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item, [bool]$Private = $false)
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'editor_path_reparse' }
    [System.Security.AccessControl.FileSystemSecurity]$Acl = Get-Acl -LiteralPath $Item.FullName
    $Acl.SetAccessRuleProtection($true, $false)
    foreach ($Rule in $Acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])) {
        [void]$Acl.RemoveAccessRuleSpecific($Rule)
    }
    [System.Security.AccessControl.InheritanceFlags]$Inheritance = [System.Security.AccessControl.InheritanceFlags]::None
    if ($Item -is [System.IO.DirectoryInfo]) { $Inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' }
    [System.Security.Principal.SecurityIdentifier]$SystemSid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'
    $Acl.SetOwner($SystemSid)
    [System.Security.AccessControl.FileSystemAccessRule]$SystemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $SystemSid, [System.Security.AccessControl.FileSystemRights]::FullControl, $Inheritance,
        [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
    $Acl.AddAccessRule($SystemRule)
    if (-not $Private) {
        foreach ($Entry in @(@('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
            [System.Security.Principal.SecurityIdentifier]$Sid = New-Object System.Security.Principal.SecurityIdentifier $Entry[0]
            [System.Security.AccessControl.FileSystemAccessRule]$Rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $Sid, [System.Security.AccessControl.FileSystemRights]$Entry[1], $Inheritance,
                [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
            $Acl.AddAccessRule($Rule)
        }
    }
    Set-Acl -LiteralPath $Item.FullName -AclObject $Acl
    Assert-EditorPath -Path $Item.FullName -Private $Private
}

function Set-EditorTreeAcl {
    [OutputType([void])]
    param([Parameter(Mandatory = $true)][string]$Path)
    [System.Collections.Generic.Queue[System.IO.DirectoryInfo]]$Pending = New-Object 'System.Collections.Generic.Queue[System.IO.DirectoryInfo]'
    [System.IO.DirectoryInfo]$Root = Get-Item -LiteralPath $Path -Force
    Set-EditorAcl -Item $Root
    $Pending.Enqueue($Root)
    while ($Pending.Count -gt 0) {
        [System.IO.DirectoryInfo]$Directory = $Pending.Dequeue()
        foreach ($Child in Get-ChildItem -LiteralPath $Directory.FullName -Force) {
            Set-EditorAcl -Item $Child
            if ($Child -is [System.IO.DirectoryInfo]) { $Pending.Enqueue($Child) }
        }
    }
}

# @cc [owner:ghuntley,label:security] windows-editor-task-installation
# Candidate installation MUST restrict package/configuration/authorizer writes
# to SYSTEM and Administrators and receipts to SYSTEM, register only the fixed
# SYSTEM boot task, and verify its action, principal, unlimited lifetime and
# private scheduler DACL. Any failed prerequisite MUST prevent completion.
Set-EditorAcl -Item (Get-Item -LiteralPath 'C:\overalls' -Force)
foreach ($Tree in @('C:\overalls\editor', 'C:\overalls\editor-broker', 'C:\overalls\agents', 'C:\overalls\trust')) {
    Set-EditorTreeAcl -Path $Tree
}
[void](New-Item -ItemType Directory -Path 'C:\overalls\editor-state' -Force)
Set-EditorAcl -Item (Get-Item -LiteralPath 'C:\overalls\editor-state' -Force) -Private $true
Assert-EditorPath -Path 'C:\overalls\agents\overalls-ssh-sync-windows.exe'
[System.IO.DriveInfo]$SystemDrive = New-Object System.IO.DriveInfo 'C:'
if ($SystemDrive.AvailableFreeSpace -lt 2GB) { throw 'editor_disk_headroom_insufficient' }
[pscustomobject]$Configuration = Get-Content -LiteralPath 'C:\overalls\editor-broker\broker.json' -Raw | ConvertFrom-Json
[pscustomobject]$Release = Get-Content -LiteralPath 'C:\overalls\editor\overalls-editor-release.json' -Raw | ConvertFrom-Json
if ($Configuration.descriptor.protocol -ne $Release.editor_protocol -or
    $Configuration.descriptor.commit -cne $Release.source_commit -or
    $Configuration.descriptor.release -cne $Release.release_id) { throw 'editor_release_mismatch' }
[pscustomobject]$Manifest = Get-Content -LiteralPath 'C:\overalls\editor-broker\manifest.json' -Raw | ConvertFrom-Json
[System.IO.FileInfo]$Executable = Get-Item -LiteralPath 'C:\overalls\editor-broker\overalls-vscode-web-broker.exe'
if ($Manifest.version -ne 1 -or $Manifest.target -cne 'win32-x64' -or $Manifest.editor_capability -ne $false -or
    $Manifest.broker.path -cne 'bin/overalls-vscode-web-broker.exe' -or
    $Manifest.broker.bytes -ne $Executable.Length -or
    $Manifest.broker.sha256 -cne (Get-FileHash -LiteralPath $Executable.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) {
    throw 'editor_broker_manifest_mismatch'
}
[string]$PowerShell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
[string]$Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\overalls\editor-broker\start.ps1'
$Action = New-ScheduledTaskAction -Execute $PowerShell -Argument $Arguments -WorkingDirectory 'C:\overalls\editor-broker'
$Principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
$Trigger = New-ScheduledTaskTrigger -AtStartup
$Settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
[void](Register-ScheduledTask -TaskPath '\Overalls\' -TaskName 'EditorBroker' -Action $Action -Principal $Principal -Trigger $Trigger -Settings $Settings -Force)
$Scheduler = New-Object -ComObject 'Schedule.Service'
$Scheduler.Connect()
$Task = $Scheduler.GetFolder('\Overalls').GetTask('EditorBroker')
# TASK_DONT_ADD_PRINCIPAL_ACE prevents the scheduler appending a redundant
# principal Read ACE. Its API omits DACL-protection flags when reading back;
# verify protection on the exact task file in addition to the API descriptor.
$Task.SetSecurityDescriptor('O:SYG:SYD:P(A;;FA;;;SY)(A;;FR;;;BA)', 0x10)
[System.Security.AccessControl.RawSecurityDescriptor]$Security = New-Object System.Security.AccessControl.RawSecurityDescriptor($Task.GetSecurityDescriptor(7))
if ($Security.DiscretionaryAcl.Count -ne 2 -or $Security.Owner.Value -cne 'S-1-5-18' -or
    $Security.Group.Value -cne 'S-1-5-18') {
    throw 'editor_task_acl_mismatch'
}
[System.Collections.Generic.HashSet[string]]$TaskSids = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($Ace in $Security.DiscretionaryAcl) {
    if ($Ace.AceType -ne [System.Security.AccessControl.AceType]::AccessAllowed -or
        $Ace.SecurityIdentifier.Value -notin @('S-1-5-18', 'S-1-5-32-544') -or
        -not $TaskSids.Add($Ace.SecurityIdentifier.Value) -or $Ace.AceFlags -ne [System.Security.AccessControl.AceFlags]::None) {
        throw 'editor_task_acl_mismatch'
    }
    [int]$ExpectedMask = 0x120089
    if ($Ace.SecurityIdentifier.Value -eq 'S-1-5-18') { $ExpectedMask = 0x1F01FF }
    if ($Ace.AccessMask -ne $ExpectedMask) { throw 'editor_task_acl_mismatch' }
}
Assert-EditorPath -Path 'C:\Windows\System32\Tasks\Overalls\EditorBroker'
if (-not (Get-Acl -LiteralPath 'C:\Windows\System32\Tasks\Overalls\EditorBroker').AreAccessRulesProtected) {
    throw 'editor_task_acl_mismatch'
}
$Installed = Get-ScheduledTask -TaskPath '\Overalls\' -TaskName 'EditorBroker'
if ($Installed.Principal.UserId -notin @('SYSTEM', 'S-1-5-18') -or
    $Installed.Principal.LogonType -ne 'ServiceAccount' -or $Installed.Principal.RunLevel -ne 'Highest' -or
    @($Installed.Actions).Count -ne 1 -or $Installed.Actions[0].Execute -cne $PowerShell -or
    $Installed.Actions[0].Arguments -cne $Arguments -or $Installed.Settings.ExecutionTimeLimit -ne 'PT0S' -or
    $Installed.Settings.MultipleInstances -ne 'IgnoreNew' -or $Installed.Settings.RestartCount -ne 999) {
    throw 'editor_task_definition_mismatch'
}
Get-NetFirewallRule -Name 'OverallsEditorBroker' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
[void](New-NetFirewallRule -Name 'OverallsEditorBroker' -DisplayName 'Overalls editor broker' -Direction Inbound `
    -Action Allow -Protocol TCP -LocalPort 4444 -RemoteAddress @('10.10.0.1', '10.20.0.1', '10.30.0.1', '10.40.0.1') `
    -Program 'C:\overalls\editor-broker\overalls-vscode-web-broker.exe' -Profile Any)
[System.IO.File]::WriteAllText('C:\overalls\editor-broker\installed', 'editor_capability=false')
Write-Output 'OVERALLS-EDITOR-CANDIDATE-INSTALLED'
