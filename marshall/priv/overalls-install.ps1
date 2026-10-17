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

$Ssh = Find-OpenSsh
if (-not $Ssh) {
    [Console]::Error.WriteLine('Overalls needs OpenSSH 9.6 or newer; the Windows in-box client is older.')
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        $Answer = Read-Host 'Install OpenSSH (Microsoft.OpenSSH.Preview) now with winget? [Y/n]'
        if ($Answer -and $Answer -notmatch '^[Yy]') { Fail 'OpenSSH 9.6 or newer is required' }
        & winget.exe install --id Microsoft.OpenSSH.Preview --exact --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { Fail 'winget could not install OpenSSH' }
        $Ssh = Find-OpenSsh
    }
    if (-not $Ssh) {
        Fail 'install OpenSSH 9.6 or newer (https://github.com/PowerShell/Win32-OpenSSH/releases), then run this command again'
    }
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
