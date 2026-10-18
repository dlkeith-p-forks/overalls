# Public configuration and source-built clients; no GitHub credential is used.
# @cc [owner:ghuntley,label:security] windows-managed-github-machine-scope
# Managed GitHub binaries MUST replace the machine-wide stock commands after
# winget validation. Only SYSTEM/Administrators may write their public config.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[string]$source = 'C:\overalls\github-tools'
[string]$gh = 'C:\Program Files\GitHub CLI\gh.exe'
[string]$lfs = 'C:\Program Files\Git\mingw64\bin\git-lfs.exe'
[string]$git = 'C:\Program Files\Git\cmd\git.exe'
foreach ($path in @($gh, $lfs, $git)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'managed_github_missing_machine_tool'
    }
}
Copy-Item -LiteralPath (Join-Path $source 'gh.exe') -Destination $gh -Force
Copy-Item -LiteralPath (Join-Path $source 'git-lfs.exe') -Destination $lfs -Force
& icacls.exe $source /inheritance:r /grant:r 'SYSTEM:(OI)(CI)(F)' 'Administrators:(OI)(CI)(F)' 'Users:(OI)(CI)(RX)' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'managed_github_acl_failed' }
& $git config --system --add include.path 'C:/overalls/github-tools/github.gitconfig'
if ($LASTEXITCODE -ne 0) { throw 'managed_github_include_failed' }
[string]$version = & $gh --version | Select-Object -First 1
if (-not $version.StartsWith('gh version 2.102.0 (overalls)')) {
    throw 'managed_github_version_failed'
}
