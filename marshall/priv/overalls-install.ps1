# Overalls CLI installer for Windows workstations (Windows PowerShell 5.1 and
# PowerShell 7). The Windows counterpart of install.sh: it installs the
# windows-amd64 `overalls.exe`, configures SSH through `overalls config-ssh` and
# connects to the machine. Usage, from the machine page:
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Invoke-RestMethod 'ORIGIN/bin/install.ps1'))) 'ORIGIN' 'ZONE' 'HOST'"
param(
    [Parameter(Mandatory = $true, Position = 0)][string] $Origin,
    [Parameter(Mandatory = $true, Position = 1)][string] $Zone,
    [Parameter(Mandatory = $true, Position = 2)][string] $Machine
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Substituted by Marshall from the deployment's SSH host trust policy.
$ManagementHost = '@OVERALLS_MANAGEMENT_HOST@'
$GuestZone = '@OVERALLS_GUEST_ZONE@'
$Target = 'windows-amd64'
$MaximumBytes = 104857600

function Fail([string] $Message) {
    [Console]::Error.WriteLine("overalls install: $Message")
    exit 1
}

# 1. Validate every argument against the values this installer was issued for.
$Label = '[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
$DnsName = "^$Label(\.$Label)*$"
if (-not ($Origin -cmatch '^https://([^/:@?#]+)(:([0-9]{1,5}))?$')) { Fail 'origin must be an https:// URL' }
$OriginHost = $Matches[1]
if ($OriginHost -cnotmatch $DnsName -or $OriginHost -cne $ManagementHost) { Fail 'origin does not match this installer' }
if ($Zone -cne $GuestZone) { Fail 'zone does not match this installer' }
if ($Machine.Length -gt 253 -or $Machine -cnotmatch $DnsName -or -not $Machine.EndsWith(".$Zone")) { Fail 'invalid machine host' }

# 2. Platform: the x86_64 build (Windows on Arm runs it under x64 emulation).
$Architecture = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $Architecture = $env:PROCESSOR_ARCHITEW6432 }
if ($Architecture -ne 'AMD64' -and $Architecture -ne 'ARM64') { Fail "unsupported processor $Architecture" }
if (-not $env:LOCALAPPDATA -or -not [IO.Path]::IsPathRooted($env:LOCALAPPDATA)) { Fail 'LOCALAPPDATA is unavailable' }

# 3. An OpenSSH client with hostname protection (9.6 or newer): it must refuse
# the hostname `invalid;hostname`. The Windows in-box client (9.5) does not.
function Test-OpenSsh([string] $Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    & $Path -V *> $null
    if ($LASTEXITCODE -ne 0) { return $false }
    & $Path -F NUL -G 'invalid;hostname' *> $null
    return ($LASTEXITCODE -ne 0)
}

function Find-OpenSsh {
    $candidates = @()
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'OpenSSH\ssh.exe') }
    $candidates += @(Get-Command ssh.exe -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-OpenSsh $candidate) { return $candidate }
    }
    return $null
}

# 3a. Install the Microsoft build (winget, machine scope) when the
# administrator-owned %ProgramFiles%\OpenSSH lacks a 9.6+ client. The MSI asks
# for administrator approval itself.
$ProgramFilesSsh = $null
if ($env:ProgramFiles) { $ProgramFilesSsh = Join-Path $env:ProgramFiles 'OpenSSH\ssh.exe' }
if (-not (Test-OpenSsh $ProgramFilesSsh) -and (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine('Installing OpenSSH 9.6 or newer (Microsoft.OpenSSH.Preview) with winget; the Windows in-box client is older.')
    & winget.exe install --id Microsoft.OpenSSH.Preview --exact --silent --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine('overalls install: winget could not install OpenSSH') }
}
$Ssh = Find-OpenSsh
if (-not $Ssh) {
    Fail 'install OpenSSH 9.6 or newer (https://github.com/PowerShell/Win32-OpenSSH/releases), then run this command again'
}

# 3b. Make plain `ssh` in new terminals run the verified client. The in-box
# %SystemRoot%\System32\OpenSSH sits in the machine PATH, which Windows searches
# before the user PATH, so only an elevated machine PATH change can put the new
# client first.
# @cc [owner:ghuntley,label:security] installer-machine-path-ssh
# The machine PATH MUST only gain %ProgramFiles%\OpenSSH, an administrator-owned
# directory resolved inside the elevated process, never a path supplied by this
# unelevated script or a user-writable directory. Declined or failed elevation
# MUST leave the machine PATH unchanged and the installation usable through
# `overalls ssh HOST`.
function Get-NormalPath([string] $Entry) {
    return [Environment]::ExpandEnvironmentVariables($Entry.Trim().Trim('"')).TrimEnd('\')
}

function Get-NewTerminalSsh {
    $Paths = @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User'))
    foreach ($Entry in (($Paths | Where-Object { $_ }) -join ';') -split ';') {
        if (-not $Entry.Trim()) { continue }
        $Candidate = Join-Path (Get-NormalPath $Entry) 'ssh.exe'
        if (Test-Path -LiteralPath $Candidate -PathType Leaf) { return $Candidate }
    }
    return $null
}

$Elevated = @'
$ErrorActionPreference = 'Stop'
$Directory = Join-Path $env:ProgramFiles 'OpenSSH'
if (-not (Test-Path -LiteralPath (Join-Path $Directory 'ssh.exe') -PathType Leaf)) { exit 3 }
function Get-NormalPath([string] $Entry) {
    return [Environment]::ExpandEnvironmentVariables($Entry.Trim().Trim('"')).TrimEnd('\')
}
$Wanted = Get-NormalPath $Directory
$InBox = Get-NormalPath (Join-Path $env:SystemRoot 'System32\OpenSSH')
$Key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
$Raw = [string]$Key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
$Entries = [Collections.Generic.List[string]]::new()
foreach ($Entry in $Raw -split ';') {
    if ($Entry.Trim() -and (Get-NormalPath $Entry) -ine $Wanted) { $Entries.Add($Entry) }
}
$Index = -1
for ($i = 0; $i -lt $Entries.Count; $i++) {
    if ((Get-NormalPath $Entries[$i]) -ieq $InBox) { $Index = $i; break }
}
if ($Index -lt 0) { $Entries.Add($Directory) } else { $Entries.Insert($Index, $Directory) }
$Key.SetValue('Path', ($Entries -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
$Key.Close()
Add-Type -Namespace Overalls -Name Native -MemberDefinition '[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr SendMessageTimeout(System.IntPtr window, uint message, System.UIntPtr wParam, string lParam, uint flags, uint timeout, out System.UIntPtr result);'
$Result = [UIntPtr]::Zero
[void][Overalls.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$Result)
exit 0
'@

if ($ProgramFilesSsh -and (Test-OpenSsh $ProgramFilesSsh) -and
    ((Get-NewTerminalSsh) -ine $ProgramFilesSsh)) {
    [Console]::Error.WriteLine('Making OpenSSH 9.6+ the default ssh for new terminals; Windows will ask for administrator approval.')
    try {
        $Encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Elevated))
        $Process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $Encoded)
        if ($Process.ExitCode -ne 0) { [Console]::Error.WriteLine('overalls install: could not update the machine PATH') }
    }
    catch {
        [Console]::Error.WriteLine('overalls install: administrator approval was not granted')
    }
}
if ((Get-NewTerminalSsh) -ine $Ssh) {
    [Console]::Error.WriteLine("Plain ssh in new terminals still runs an older client; connect with: overalls ssh $Machine")
}

# 4. Download the published binary and verify its SHA-256 digest.
$BinDirectory = Join-Path $env:LOCALAPPDATA 'Overalls\bin'
New-Item -ItemType Directory -Force -Path $BinDirectory | Out-Null
$Installed = Join-Path $BinDirectory 'overalls.exe'
$Temporary = Join-Path $BinDirectory ('.overalls-' + [guid]::NewGuid().ToString('N') + '.exe')
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
try {
    Invoke-WebRequest -UseBasicParsing -MaximumRedirection 0 -Uri "$Origin/bin/$Target" -OutFile $Temporary
    $Size = (Get-Item -LiteralPath $Temporary).Length
    if ($Size -le 0 -or $Size -gt $MaximumBytes) { Fail 'invalid binary size' }
    $Expected = ([string](Invoke-RestMethod -UseBasicParsing -MaximumRedirection 0 -Uri "$Origin/bin/sha256/$Target")).Trim()
    if ($Expected -cnotmatch '^[0-9a-f]{64}$') { Fail 'invalid checksum' }
    $Actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Temporary).Hash.ToLowerInvariant()
    if ($Actual -cne $Expected) { Fail 'Binary checksum mismatch' }

    # 5. Configure SSH with the downloaded binary before it replaces anything.
    & $Temporary config-ssh --origin $Origin --zone $Zone --ssh $Ssh --staged-installer
    if ($LASTEXITCODE -ne 0) { Fail 'SSH configuration failed' }
    Move-Item -LiteralPath $Temporary -Destination $Installed -Force
}
finally {
    if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -Force -ErrorAction SilentlyContinue }
}

# 6. Put overalls.exe on the user's PATH for new terminals.
$UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $UserPath) { $UserPath = '' }
if (-not (($UserPath -split ';') -contains $BinDirectory)) {
    [Environment]::SetEnvironmentVariable('Path', (($UserPath.TrimEnd(';') + ';' + $BinDirectory).TrimStart(';')), 'User')
}
$env:Path = "$env:Path;$BinDirectory"

# 7. Connect with the verified OpenSSH client.
& $Installed ssh $Machine
exit $LASTEXITCODE
