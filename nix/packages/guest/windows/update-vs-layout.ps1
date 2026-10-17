# Operator tool (ADR-0173): record a pinned Visual Studio Community offline layout.
#
# Runs by hand on a Windows Server 2025 Desktop Experience machine with internet
# access (a Overalls Windows guest), as an administrator; the image build never
# runs it. It downloads the bootstrapper pinned in winget.json, verifies its
# SHA-256, asks it for an offline layout of the image's workloads and records
# every file of that layout in vs-layout.json, by URL and SHA-256 or, for the
# small files the layout generates, by content (see the mapping below).
# Review and commit vs-layout.json like any other pin; the build fetches each
# payload by URL and digest.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File update-vs-layout.ps1 `
#     -BootstrapperUrl <url> -BootstrapperSha256 <hex> -Out C:\vs-layout.json
param(
    [Parameter(Mandatory)][string]$BootstrapperUrl,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$BootstrapperSha256,
    [Parameter(Mandatory)][string]$Out,
    [string]$Layout = 'C:\vslayout',
    [string[]]$Workloads = @('Microsoft.VisualStudio.Workload.NativeDesktop', 'Microsoft.VisualStudio.Workload.ManagedDesktop'),
    [string]$Language = 'en-US'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-Sha256([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }

New-Item -ItemType Directory -Force -Path $Layout | Out-Null
$bootstrapper = Join-Path $Layout 'vs_Community.exe'
Invoke-WebRequest -UseBasicParsing -Uri $BootstrapperUrl -OutFile $bootstrapper
$digest = Get-Sha256 $bootstrapper
if ($digest -ne $BootstrapperSha256.ToLowerInvariant()) { throw "bootstrapper digest $digest does not match the pin" }

$arguments = @('--layout', $Layout, '--lang', $Language, '--includeRecommended', '--quiet', '--wait')
foreach ($workload in $Workloads) { $arguments += @('--add', $workload) }
$started = Get-Date
$process = Start-Process -FilePath $bootstrapper -ArgumentList $arguments -PassThru -Wait
if ($process.ExitCode -ne 0) { throw "layout failed with exit code $($process.ExitCode)" }
Write-Host ("layout done in {0:n0} s" -f ((Get-Date) - $started).TotalSeconds)

# Every layout file is reproduced by URL and digest or by content:
# - payloads: matched by SHA-256 against the layout's Catalog.json (the layout
#   renames files, e.g. *.vsix to payload.vsix, so names do not match);
# - Catalog.json: the channel manifest's VisualStudio manifest URL serves it
#   byte for byte (the size and digest the channel lists describe another form);
# - bootstrapper copies (vs_Community.exe, vs_setup.exe): the pinned URL;
# - vs_installer.opc: the content-addressed URL the bootstrapper log records;
# - everything else must be small and is embedded (ChannelManifest.json,
#   Response*.json, Layout.json, vs_installer.version.json, certificates).
$catalog = Get-Content -Raw -LiteralPath (Join-Path $Layout 'Catalog.json') | ConvertFrom-Json
$bySha = @{}
foreach ($package in $catalog.packages) {
    foreach ($payload in @($package.payloads)) {
        if ($payload -and $payload.url -and $payload.sha256) { $bySha[$payload.sha256.ToLowerInvariant()] = $payload.url }
    }
}
$bySha[$digest] = $BootstrapperUrl
$channel = Get-Content -Raw -LiteralPath (Join-Path $Layout 'ChannelManifest.json') | ConvertFrom-Json
$manifestItem = $channel.channelItems | Where-Object { $_.type -eq 'Manifest' } | Select-Object -First 1
$catalogUrl = $manifestItem.payloads[0].url
$probe = Join-Path $env:TEMP 'overalls-vs-catalog.json'
Invoke-WebRequest -UseBasicParsing -Uri $catalogUrl -OutFile $probe
$bySha[(Get-Sha256 $probe)] = $catalogUrl
$bootstrapLogs = Get-ChildItem -Path $env:TEMP, "$env:SystemRoot\SystemTemp", "$env:SystemRoot\Temp" -Filter 'dd_bootstrapper*.log' -ErrorAction SilentlyContinue
foreach ($log in $bootstrapLogs) {
    foreach ($match in (Select-String -LiteralPath $log.FullName -Pattern 'https://download\.visualstudio\.microsoft\.com/[^ ''"]+' -AllMatches).Matches) {
        $url = $match.Value.TrimEnd('.')
        foreach ($segment in $url.Split('/')) {
            if ($segment -match '^[0-9A-Fa-f]{64}$') { $bySha[$segment.ToLowerInvariant()] = $url }
        }
    }
}

$files = @()
$embedded = @()
$total = 0
foreach ($file in Get-ChildItem -LiteralPath $Layout -Recurse -File) {
    $relative = $file.FullName.Substring($Layout.TrimEnd('\').Length + 1)
    $sha = Get-Sha256 $file.FullName
    $total += $file.Length
    if ($bySha.ContainsKey($sha)) {
        $files += [ordered]@{ path = $relative; url = $bySha[$sha]; sha256 = $sha; size = $file.Length }
    } elseif ($file.Length -le 262144) {
        $embedded += [ordered]@{ path = $relative; sha256 = $sha; size = $file.Length; content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file.FullName)) }
    } else {
        throw "no source for $relative ($($file.Length) bytes, $sha)"
    }
}

$result = [ordered]@{
    bootstrapper = [ordered]@{ url = $BootstrapperUrl; sha256 = $digest }
    workloads = $Workloads
    language = $Language
    includeRecommended = $true
    catalog = [ordered]@{ productVersion = $catalog.info.productDisplayVersion; buildVersion = $catalog.info.buildVersion }
    bytes = $total
    files = $files
    embedded = $embedded
}
$result | ConvertTo-Json -Depth 6 -Compress | Set-Content -Encoding UTF8 -LiteralPath $Out
Write-Host ("{0} files by URL, {1} embedded, {2:n2} GiB in {3}" -f $files.Count, $embedded.Count, ($total / 1GB), $Out)
foreach ($entry in $embedded) { Write-Host ("embedded: {0} ({1} bytes)" -f $entry.path, $entry.size) }
