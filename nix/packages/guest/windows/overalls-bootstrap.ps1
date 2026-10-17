# Overalls Windows guest bootstrap. Runs as SYSTEM at every boot (scheduled task
# Overalls\Bootstrap registered by SetupComplete.cmd) and configures the guest
# from Firecracker's MMDS, which Lilly seeds before the guest runs:
#
#   GET http://169.254.169.254/lilly  (MMDS V2, session token required)
#   {"version":1,"placement":...,"execution_epoch":...,"boot_challenge":...,
#    "ipv4":"10.X.0.N","prefix_length":32,"gateway":"10.X.0.1","mac":"02:fc:..."}
#
# It assigns exactly that /32 with an on-link host route to the gateway and a
# default route through it (the host guard drops any other source address),
# grows C: into a disk Lilly may have extended, and leaves evidence under
# C:\overalls. It never logs the session token or the boot challenge, changes no
# account, and touches nothing when the current boot was already applied.
#
# Windows PowerShell 5.1 compatible: no -NoProxy, no ternaries, no ?? operator.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$Base = 'C:\overalls'
$LogDir = Join-Path $Base 'logs'
$StateDir = Join-Path $Base 'network'
$StateFile = Join-Path $StateDir 'state.json'
$Mmds = '169.254.169.254'
$BootstrapAddress = '169.254.169.1'
$Uuid = '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
$Hex64 = '^[0-9a-f]{64}$'
$Dotted = '^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}$'

New-Item -ItemType Directory -Force -Path $LogDir, $StateDir | Out-Null
$Log = Join-Path $LogDir ('bootstrap-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

function Write-Log {
    param([string]$Message)
    ((Get-Date).ToString('o') + ' ' + $Message) | Out-File -FilePath $Log -Append -Encoding utf8
}

function Write-OverallsEvent {
    param([string]$EntryType, [string]$Message)
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists('Overalls')) {
            New-EventLog -LogName Application -Source 'Overalls'
        }
        Write-EventLog -LogName Application -Source 'Overalls' -EventId 1000 -EntryType $EntryType -Message $Message
    } catch {
        Write-Log ('event log unavailable: ' + $_.Exception.Message)
    }
}

# EMS/SAC owns COM1 while Windows runs, so the serial marker is best effort;
# the host observes readiness by reaching the /32, not by this line.
function Write-Serial {
    param([string]$Text)
    try {
        $port = New-Object System.IO.Ports.SerialPort 'COM1', 115200, 'None', 8, 'One'
        $port.WriteTimeout = 1000
        $port.Open()
        $port.WriteLine($Text)
        $port.Close()
    } catch {
        Write-Log ('serial marker not written: ' + $_.Exception.Message)
    }
}

# Publish the log on the EFI system partition (FAT32) so the host can read it
# from the raw disk with mtools without logging in, as SetupComplete.cmd does
# for the installation logs. Best effort; never fails the bootstrap.
function Publish-Log {
    try {
        & mountvol.exe S: /S | Out-Null
        if (Test-Path 'S:\') {
            New-Item -ItemType Directory -Force -Path 'S:\overalls\logs' | Out-Null
            Copy-Item -Force $Log 'S:\overalls\logs\bootstrap-latest.log'
            if (Test-Path $StateFile) { Copy-Item -Force $StateFile 'S:\overalls\logs\network-state.json' }
            & mountvol.exe S: /D | Out-Null
        }
    } catch {
        Write-Log ('log publication skipped: ' + $_.Exception.Message)
    }
}

function Fail {
    param([string]$Message)
    Write-Log ('FAIL ' + $Message)
    Write-OverallsEvent 'Error' ('Overalls bootstrap failed: ' + $Message)
    Write-Serial 'OVERALLS-BOOTSTRAP-FAILED'
    Publish-Log
    exit 1
}

function Normalize-Mac {
    param([string]$Mac)
    return ($Mac -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
}

function Invoke-Mmds {
    param([string]$Method, [string]$Path, [hashtable]$Headers)
    $last = $null
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            return Invoke-WebRequest -UseBasicParsing -Method $Method -Uri ('http://' + $Mmds + $Path) `
                -Headers $Headers -TimeoutSec 5
        } catch {
            $last = $_.Exception.Message
            Start-Sleep -Seconds 2
        }
    }
    Fail ('MMDS ' + $Method + ' ' + $Path + ' unreachable: ' + $last)
}

Write-Log 'bootstrap start'

# 1. The virtio NIC. Lilly presents exactly one adapter; under Firecracker it is
#    a different PnP instance than the one the image was installed with, so no
#    per-adapter setting from the installation is assumed.
$adapter = $null
for ($i = 0; $i -lt 120 -and -not $adapter; $i++) {
    $adapter = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if (-not $adapter) { Start-Sleep -Seconds 2 }
}
if (-not $adapter) { Fail 'no physical network adapter came up' }
$ifIndex = $adapter.ifIndex
Write-Log ('adapter ' + $adapter.Name + ' ifIndex ' + $ifIndex + ' mac ' + $adapter.MacAddress)
$observed = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    ForEach-Object { $_.IPAddress + '/' + $_.PrefixLength + ':' + $_.AddressState }
Write-Log ('addresses before: ' + ($observed -join ' '))

# 2. Reach MMDS. Firecracker answers ARP for 169.254.169.254 inside the VMM, so
#    any link-local source works; add a temporary one when the stack has none.
$temporary = $false
$linkLocal = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -like '169.254.*' }
if (-not $linkLocal) {
    New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $BootstrapAddress -PrefixLength 16 `
        -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
    $temporary = $true
    for ($i = 0; $i -lt 30; $i++) {
        $state = Get-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $BootstrapAddress -ErrorAction SilentlyContinue
        if ($state -and $state.AddressState -ne 'Tentative') { break }
        Start-Sleep -Seconds 1
    }
    Write-Log 'temporary link-local address added for MMDS'
}

# 3. MMDS V2: session token, then the lilly document. No proxy may intercept it.
[System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy
$tokenResponse = Invoke-Mmds 'Put' '/latest/api/token' @{ 'X-metadata-token-ttl-seconds' = '60' }
$token = [string]$tokenResponse.Content
if ([string]::IsNullOrWhiteSpace($token)) { Fail 'empty MMDS session token' }
$document = Invoke-Mmds 'Get' '/lilly' @{ 'X-metadata-token' = $token; 'Accept' = 'application/json' }
try {
    $lilly = $document.Content | ConvertFrom-Json
} catch {
    Fail 'MMDS lilly document is not JSON'
}

# 4. Validate every field before touching the stack.
if ($lilly.version -ne 1) { Fail 'unsupported lilly metadata version' }
if (-not ($lilly.placement -match $Uuid)) { Fail 'placement is not a UUID' }
if (-not ($lilly.execution_epoch -is [int] -or $lilly.execution_epoch -is [long]) -or $lilly.execution_epoch -lt 1) {
    Fail 'execution_epoch is not a positive integer'
}
if (-not ($lilly.boot_challenge -match $Hex64)) { Fail 'boot_challenge is not 64 hex characters' }
if (-not ($lilly.ipv4 -match $Dotted)) { Fail 'ipv4 is not a dotted address' }
if ($lilly.prefix_length -ne 32) { Fail 'prefix_length is not 32' }
if (-not ($lilly.gateway -match $Dotted)) { Fail 'gateway is not a dotted address' }
if ((Normalize-Mac $lilly.mac) -ne (Normalize-Mac $adapter.MacAddress)) { Fail 'MMDS mac does not match the adapter' }
$ipv4 = [string]$lilly.ipv4
$gateway = [string]$lilly.gateway
Write-Log ('identity placement ' + $lilly.placement + ' epoch ' + $lilly.execution_epoch + ' ipv4 ' + $ipv4 + ' gateway ' + $gateway)

# 5. Idempotency: the same boot already applied leaves the stack untouched.
$previous = $null
if (Test-Path $StateFile) {
    try { $previous = Get-Content $StateFile -Raw | ConvertFrom-Json } catch { $previous = $null }
}
$present = Get-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $ipv4 -PrefixLength 32 -ErrorAction SilentlyContinue
$defaultRoute = Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Where-Object { $_.NextHop -eq $gateway }
if ($previous -and $previous.boot_challenge -eq $lilly.boot_challenge -and $previous.ipv4 -eq $ipv4 -and $present -and $defaultRoute) {
    if ($temporary) { Remove-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $BootstrapAddress -Confirm:$false }
    Write-Log 'already applied for this boot'
    Publish-Log
    Write-Serial 'OVERALLS-NETWORK-READY'
    exit 0
}

# 6. Apply the single validated /32: DHCP off, no other IPv4 address or default
#    route on the interface, on-link host route to the gateway, default via it.
Set-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -Dhcp Disabled
Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -ne $ipv4 -and $_.IPAddress -ne $BootstrapAddress } |
    Remove-NetIPAddress -Confirm:$false
Get-NetRoute -InterfaceIndex $ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false
if (-not $present) {
    New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $ipv4 -PrefixLength 32 | Out-Null
}
if (-not (Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix ($gateway + '/32') -ErrorAction SilentlyContinue)) {
    New-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix ($gateway + '/32') -NextHop 0.0.0.0 | Out-Null
}
New-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '0.0.0.0/0' -NextHop $gateway | Out-Null
if ($temporary) { Remove-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $BootstrapAddress -Confirm:$false }
# The guest agents re-read MMDS during the boot (ADR-0171); Firecracker answers
# ARP for its address inside the VMM, so an on-link host route keeps it
# reachable from the applied /32 without any link-local address.
if (-not (Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix ($Mmds + '/32') -ErrorAction SilentlyContinue)) {
    New-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix ($Mmds + '/32') -NextHop 0.0.0.0 | Out-Null
}
# Lilly's private services (SSH roster, telemetry, agents) answer at a fixed
# link-local address bound to the host side's loopback, so nothing answers ARP
# for it on the tap: like Linux guests, send it to the gateway. An on-link
# route would leave every private request unanswered.
Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '169.254.254.1/32' -ErrorAction SilentlyContinue |
    Where-Object { $_.NextHop -ne $gateway } |
    Remove-NetRoute -Confirm:$false
if (-not (Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '169.254.254.1/32' -ErrorAction SilentlyContinue)) {
    New-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '169.254.254.1/32' -NextHop $gateway | Out-Null
}
# Private service names (*.internal, such as the agent endpoint llm.internal)
# resolve only through that endpoint's resolver, as Linux guests route
# ~internal; no other name uses it and no other DNS server is configured.
Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
    Where-Object { $_.Namespace -contains '.internal' } |
    Remove-DnsClientNrptRule -Force -ErrorAction SilentlyContinue
Add-DnsClientNrptRule -Namespace '.internal' -NameServers '169.254.254.1' | Out-Null
# Public names use the same resolvers as Linux guests (1.1.1.1, 9.9.9.9); the
# rule above still sends every .internal name to the private resolver only.
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses @('1.1.1.1', '9.9.9.9')
Write-Log 'network applied'

# 7. Grow C: into a disk Lilly extended (truncate only; Windows relocates the
#    backup GPT header when the partition grows). Never shrink.
try {
    Update-HostStorageCache
    $partition = Get-Partition -DriveLetter C
    $supported = Get-PartitionSupportedSize -DriveLetter C
    if ($supported.SizeMax - $partition.Size -ge 64MB) {
        Resize-Partition -DriveLetter C -Size $supported.SizeMax
        Write-Log ('C: grown to ' + $supported.SizeMax + ' bytes')
    }
} catch {
    Write-Log ('disk growth skipped: ' + $_.Exception.Message)
}

# 8. Evidence: the applied identity (readable by SYSTEM and Administrators only),
#    an Application event and the best-effort serial marker.
$state = @{
    version = 1
    placement = $lilly.placement
    execution_epoch = $lilly.execution_epoch
    boot_challenge = $lilly.boot_challenge
    ipv4 = $ipv4
    gateway = $gateway
    applied_at = (Get-Date).ToString('o')
}
$state | ConvertTo-Json | Out-File -FilePath $StateFile -Encoding utf8
& icacls.exe $StateFile /inheritance:r /grant:r 'SYSTEM:(F)' 'Administrators:(R)' | Out-Null
Write-OverallsEvent 'Information' ('Overalls bootstrap applied ' + $ipv4 + '/32 via ' + $gateway + ' for placement ' + $lilly.placement)
Write-Log 'bootstrap complete'
Publish-Log
Write-Serial 'OVERALLS-NETWORK-READY'
exit 0
