# Overalls Windows image: install winget and the pinned winget packages (ADR-0173).
#
# Runs during the offline installation (QEMU user networking with restrict=on).
# Inputs come from the boot media at C:\overalls\winget (stage-winget.py): the
# App Installer bundle with its license and x64 framework packages, and one
# local manifest directory per package, listed dependencies first in
# packages.txt. Every manifest points its single installer at the build host's
# pinned file server; winget verifies each installer against the manifest's
# SHA-256 before running it.
#
# Phase "provision" (SYSTEM, SetupComplete.cmd): provision App Installer with
# its framework packages for every account and record the network the install
# phase will use.
#
# Phase "install" (the bootstrap Administrator's one-shot interactive first
# logon, FirstLogon.cmd): register App Installer for the account and install
# every package machine-wide (--scope machine). winget needs package identity
# (as SYSTEM it fails with 0xC0000135), and the shell launch it uses for .exe
# installers never returns in a non-interactive session-0 logon, so this phase
# runs only in the interactive first logon.
#
# Phase "verify" (same logon): every package command resolves from the machine
# PATH alone, under Program Files or the Windows directory, and answers
# --version.
#
# Exit code 0 only when the phase succeeded; serial markers report each step.
param(
    [ValidateSet('provision', 'install', 'verify')][string]$Phase = 'provision',
    [string]$Root = 'C:\overalls\winget'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Log = 'C:\overalls\evidence\winget.log'
$Commands = 'git', 'gh', 'claude', 'codex', 'rg', 'podman', 'wsl'

function Write-Log([string]$Message) {
    Add-Content -Path $Log -Value ('[{0}] [{1}] {2}' -f (Get-Date -Format o), $Phase, $Message)
}

function Write-Marker([string]$Marker) {
    Write-Log $Marker
    try {
        $port = New-Object System.IO.Ports.SerialPort 'COM1', 115200
        $port.Open(); $port.WriteLine($Marker); $port.Close()
    } catch { Write-Log "COM1 unavailable: $($_.Exception.Message)" }
}

# Every process with its parent and command line, for a stalled install.
function Write-ProcessTree {
    Get-Process | Where-Object { $_.MainWindowTitle } | ForEach-Object {
        Write-Log ("window: pid={0} {1} '{2}'" -f $_.Id, $_.ProcessName, $_.MainWindowTitle)
    }
    Get-CimInstance Win32_Process | Sort-Object ParentProcessId, ProcessId | ForEach-Object {
        $line = '{0,6} {1,6} {2}' -f $_.ProcessId, $_.ParentProcessId, $_.CommandLine
        if (-not $_.CommandLine) { $line = '{0,6} {1,6} {2}' -f $_.ProcessId, $_.ParentProcessId, $_.Name }
        $line.Substring(0, [Math]::Min(300, $line.Length))
    } | Out-String | ForEach-Object { Write-Log "process tree:`r`n$_" }
}

# winget's own diagnostics and any installer logs, kept with the evidence.
function Save-WingetLogs {
    $target = 'C:\overalls\evidence\winget-diag'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $sources = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir'),
        $env:TEMP
    )
    foreach ($source in $sources) {
        Get-ChildItem -Path $source -Recurse -File -Include *.log, *.txt -ErrorAction SilentlyContinue |
            Where-Object Length -lt 4MB | Select-Object -Last 40 |
            ForEach-Object { Copy-Item $_.FullName (Join-Path $target ($_.Directory.Name + '-' + $_.Name)) -ErrorAction SilentlyContinue }
    }
}

# One winget call with a deadline: a stalled install fails its package instead
# of the whole installation's budget, and leaves the process tree as evidence.
function Invoke-Winget([string]$Winget, [string[]]$Arguments, [int]$TimeoutMinutes = 4) {
    Write-Log ('winget ' + ($Arguments -join ' '))
    $out = Join-Path $env:TEMP 'overalls-winget.out'
    $quoted = $Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    $process = Start-Process -FilePath $Winget -ArgumentList $quoted -NoNewWindow -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    # Windows PowerShell 5.1 reports no ExitCode unless the handle was opened
    # while the process ran.
    $null = $process.Handle
    if (-not $process.WaitForExit($TimeoutMinutes * 60000)) {
        Write-Log "timed out after $TimeoutMinutes minutes`r`n$((Get-Content $out -Raw -ErrorAction SilentlyContinue))"
        Write-ProcessTree
        # End winget and everything it started, so the next package runs alone.
        & taskkill.exe /T /F /PID $process.Id 2>&1 | Out-String | ForEach-Object { Write-Log $_.Trim() }
        return -1
    }
    $code = $process.ExitCode
    $output = (Get-Content $out, "$out.err" -Raw -ErrorAction SilentlyContinue) -join ''
    Write-Log ("exit {0}`r`n{1}" -f $code, $output.Trim())
    return $code
}

# Visual Studio Community installs from a pinned offline layout (vs-layout.json).
# The layout is rebuilt in C:\vslayout from the build's file server (each file
# checked against its SHA-256), the small generated files come from the media,
# and the installer's signer intermediate goes to the machine's intermediate
# store (offline, Windows cannot fetch it; it grants no trust by itself).
# winget then runs the pinned bootstrapper against the layout; the layout is
# deleted afterwards.
$VsLayout = 'C:\vslayout'
$VsMedia = Join-Path $Root 'vslayout'
$PackageOptions = @{
    'Microsoft.VisualStudio.Community' = @{
        Override = "--in $VsLayout\Response.overalls.json --installLayoutPath $VsLayout --noWeb --quiet --wait --norestart"
        TimeoutMinutes = 150
    }
}

function Invoke-VsLayout {
    $list = Join-Path $VsMedia 'files.tsv'
    if (-not (Test-Path $list)) { return $false }
    Write-Marker 'OVERALLS-VS-LAYOUT-BEGIN'
    $started = Get-Date
    $client = New-Object Net.WebClient
    $count = 0; $bytes = 0
    foreach ($line in Get-Content -Path $list | Where-Object { $_ }) {
        $sha, $path = $line.Split("`t", 2)
        $target = Join-Path $VsLayout $path
        New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
        $client.DownloadFile("http://10.0.2.100/$sha/f", $target)
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant() -ne $sha) { throw "layout file $path does not match $sha" }
        $count++; $bytes += (Get-Item -LiteralPath $target).Length
    }
    Copy-Item -Recurse -Force -Path (Join-Path $VsMedia 'embedded\*') -Destination $VsLayout
    Copy-Item -Force -Path (Join-Path $VsMedia 'response.json') -Destination (Join-Path $VsLayout 'Response.overalls.json')
    foreach ($certificate in Get-ChildItem -Path (Join-Path $VsMedia 'intermediates') -Filter *.crt) {
        Import-Certificate -FilePath $certificate.FullName -CertStoreLocation Cert:\LocalMachine\CA | ForEach-Object { Write-Log "intermediate: $($_.Subject)" }
    }
    $seconds = [int]((Get-Date) - $started).TotalSeconds
    Write-Marker ("OVERALLS-VS-LAYOUT-READY files={0} bytes={1} seconds={2}" -f $count, $bytes, $seconds)
    return $true
}

function Invoke-ProvisionPhase {
    Write-Marker 'OVERALLS-WINGET-START'
    $dependencies = Get-ChildItem -Path (Join-Path $Root 'dependencies') -Filter *.appx | ForEach-Object FullName
    Add-AppxProvisionedPackage -Online `
        -PackagePath (Join-Path $Root 'Microsoft.DesktopAppInstaller.msixbundle') `
        -DependencyPackagePath $dependencies `
        -LicensePath (Join-Path $Root 'license.xml') | Out-Null
    $provisioned = Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'Microsoft.DesktopAppInstaller'
    Write-Log ('provisioned ' + (($provisioned | ForEach-Object PackageName) -join ', '))
    Write-Marker 'OVERALLS-WINGET-PROVISIONED'
}

function Invoke-InstallPhase {
    $label = whoami.exe /groups | Select-String -Pattern 'Mandatory Label' | ForEach-Object { $_.Line.Trim() -replace '\s+', ' ' }
    Write-Log "running as $([Security.Principal.WindowsIdentity]::GetCurrent().Name); $label; session=$([Diagnostics.Process]::GetCurrentProcess().SessionId) interactive=$([Environment]::UserInteractive)"
    $addresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { "$($_.InterfaceAlias)=$($_.IPAddress)/$($_.PrefixLength)" }
    Write-Log ('IPv4 ' + ($addresses -join ', '))

    # The first interactive logon may register the provisioned App Installer
    # for the account; if it has not after 30 s, install the same pinned bundle
    # and framework packages for this account directly. (Registering the
    # provisioned bundle after the reboot into this logon fails with
    # 0x80073CF0: its bundle manifest cannot be opened.)
    $winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Test-Path $winget) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    if (-not (Test-Path $winget)) {
        Write-Log 'installing App Installer for this account'
        Add-AppxPackage -Path (Join-Path $Root 'Microsoft.DesktopAppInstaller.msixbundle') `
            -DependencyPath (Get-ChildItem -Path (Join-Path $Root 'dependencies') -Filter *.appx | ForEach-Object FullName)
        $deadline = (Get-Date).AddMinutes(1)
        while (-not (Test-Path $winget) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    }
    Write-Log ('App Installer for this account: ' + ((Get-AppxPackage Microsoft.DesktopAppInstaller | ForEach-Object PackageFullName) -join ', '))
    if ((Invoke-Winget $winget @('--version')) -ne 0) { throw 'winget --version failed' }
    # Plain WinINet GETs: Delivery Optimization, the default downloader, does
    # not suit a one-request-per-connection file server.
    $settings = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json'
    New-Item -ItemType Directory -Force -Path (Split-Path $settings) | Out-Null
    Set-Content -Path $settings -Encoding UTF8 -Value '{ "network": { "downloader": "wininet" } }'
    if ((Invoke-Winget $winget @('settings', '--enable', 'LocalManifestFiles')) -ne 0) { throw 'enabling local manifests failed' }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $vsLayoutBuilt = Invoke-VsLayout
    # winget marks each download with its URL's security zone and starts .exe
    # installers through the shell, which raises a security prompt for an
    # Internet-zone file; nobody can answer it during the build (winget owned a
    # dialog while Git, the Visual C++ redistributable and Podman stalled; the
    # same Git installer started directly ran to completion; MSI and zip
    # packages never take that path). For this step only, the build's file
    # server address alone is the Local Intranet zone for this account, in the
    # map Internet Explorer Enhanced Security Configuration (on for
    # administrators on Windows Server) reads, EscRanges, and the ordinary one.
    $zoneMap = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap'
    $zoneRanges = "$zoneMap\EscRanges\OverallsBuildServer", "$zoneMap\Ranges\OverallsBuildServer"
    foreach ($zoneRange in $zoneRanges) {
        New-Item -Force -Path $zoneRange | Out-Null
        Set-ItemProperty -Path $zoneRange -Name ':Range' -Value '10.0.2.100'
        Set-ItemProperty -Path $zoneRange -Name 'http' -Value 1 -Type DWord
    }
    $zone = [System.Security.Policy.Zone]::CreateFromUrl('http://10.0.2.100/').SecurityZone
    Write-Log "build file server zone for this step: $zone"
    if ($zone -ne 'Intranet') { throw "build file server zone is $zone, not Intranet" }
    try {
        $index = 0
        $failed = @()
        foreach ($id in Get-Content -Path (Join-Path $Root 'packages.txt') | Where-Object { $_ }) {
            $index++
            # One serial checkpoint before and one after every package, so the
            # build timeline places a stall or failure on a named package.
            Write-Marker "OVERALLS-WINGET-PACKAGE-BEGIN-$index $id"
            $started = Get-Date
            $arguments = @(
                'install', '--manifest', (Join-Path $Root "packages\$id"),
                '--scope', 'machine', '--architecture', 'x64', '--silent', '--skip-dependencies',
                '--accept-package-agreements', '--disable-interactivity')
            $timeout = 4
            $options = $PackageOptions[$id]
            if ($options) {
                $arguments += @('--override', $options.Override)
                $timeout = $options.TimeoutMinutes
            }
            $code = Invoke-Winget $winget $arguments $timeout
            # No --log: winget hands that path to the installer (/LOG= for Inno),
            # and Git's setup never started with it; winget's own diagnostics
            # are kept by Save-WingetLogs.
            $seconds = [int]((Get-Date) - $started).TotalSeconds
            if ($code -ne 0) {
                Write-Marker "OVERALLS-WINGET-PACKAGE-FAILED-$index $id exit=$code seconds=$seconds"
                $failed += $id
                continue
            }
            Write-Marker "OVERALLS-WINGET-PACKAGE-INSTALLED-$index $id seconds=$seconds"
        }
        if ($vsLayoutBuilt) {
            Remove-Item -Recurse -Force -Path $VsLayout -ErrorAction SilentlyContinue
            Write-Log "Visual Studio layout removed: $(-not (Test-Path $VsLayout))"
        }
        # Every package is attempted so one installation reports them all.
        if ($failed) { throw ('packages failed: ' + ($failed -join ', ')) }
    } finally {
        Invoke-Winget $winget @('settings', '--disable', 'LocalManifestFiles') | Out-Null
        foreach ($zoneRange in $zoneRanges) { Remove-Item -Recurse -Force -Path $zoneRange -ErrorAction SilentlyContinue }
        Write-Log "zone mapping removed: $(-not ($zoneRanges | Where-Object { Test-Path $_ }))"
        Save-WingetLogs
    }
    # Machine-wide only: an install that put itself on this account's PATH
    # would be invisible to every other account.
    # The one per-account entry allowed is the .NET SDK's global-tools folder
    # (%USERPROFILE%\.dotnet\tools), which the SDK Visual Studio installs adds
    # for whoever first runs it; the SDK itself is on the machine PATH.
    $before = @($userPath -split ';' | Where-Object { $_ })
    $added = @([Environment]::GetEnvironmentVariable('Path', 'User') -split ';' | Where-Object { $_ -and $before -notcontains $_ })
    $unexpected = @($added | Where-Object { $_ -ne (Join-Path $env:USERPROFILE '.dotnet\tools') })
    if ($unexpected) { throw "a package changed the installing account's PATH: added $($unexpected -join ';')" }
    if ($added) { Write-Log "per-account PATH entries left by installers: $($added -join ';')" }
    Write-Marker 'OVERALLS-WINGET-INSTALLED'
}

function Invoke-VerifyPhase {
    # Every package command must resolve from the machine PATH a new process
    # (an SSH session, an agent's shell) gets.
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    Write-Log "machine PATH: $env:Path"
    foreach ($command in $Commands) {
        $resolved = Get-Command $command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $resolved) { throw "$command is not on the machine PATH" }
        if ($resolved.Source -notlike "$env:ProgramFiles\*" -and $resolved.Source -notlike "$env:SystemRoot\*") {
            throw "$command resolves outside the machine-wide locations: $($resolved.Source)"
        }
        # The whole output first: Select-Object -First stops the pipeline early
        # and can leave a failing exit code behind for a command that answered.
        $output = & $resolved.Source --version 2>&1
        $code = $LASTEXITCODE
        Write-Log "$command -> $($resolved.Source): $(($output | Select-Object -First 1)) (exit $code)"
        if ($code -ne 0) { throw "$command --version failed with $code" }
    }
    # Visual Studio is verified by its installer's own query: both workloads
    # present in one installation.
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path (Join-Path $VsMedia 'files.tsv')) {
        if (-not (Test-Path $vswhere)) { throw 'vswhere.exe is missing: Visual Studio is not installed' }
        $installation = & $vswhere -products * -requires Microsoft.VisualStudio.Workload.NativeDesktop Microsoft.VisualStudio.Workload.ManagedDesktop -property installationPath
        $version = & $vswhere -products * -property catalog_productDisplayVersion
        Write-Log "Visual Studio: $installation ($version)"
        if (-not $installation) { throw 'Visual Studio with the C++ and .NET desktop workloads is not installed' }
    }
    Write-Marker 'OVERALLS-WINGET-COMPLETE'
}

try {
    switch ($Phase) {
        'provision' { Invoke-ProvisionPhase }
        'install' { Invoke-InstallPhase }
        'verify' { Invoke-VerifyPhase }
    }
    exit 0
} catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    Write-Marker "OVERALLS-WINGET-FAILED phase=$Phase"
    exit 1
}
