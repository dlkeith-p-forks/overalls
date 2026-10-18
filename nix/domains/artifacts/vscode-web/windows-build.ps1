# Build the official patched Code OSS source natively inside the offline Windows
# builder. This script has no image-admission or user-account authority.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PayloadRoot,
    [string]$OutputDirectory = 'C:\overalls\editor-built'
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# @cc [owner:ghuntley,label:build;security] windows-editor-native-build-offline
# The build MUST use only the staged source, patch stack, npm caches, native
# Node/Python inputs and installed C++ toolchain. Every native command MUST
# succeed before a completion marker is published. No prebuilt Code OSS bundle
# or image capability may be substituted when a dependency or build fails.
function Invoke-Native {
    [OutputType([void])]
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'native_editor_build_failed' }
}

function Write-Checkpoint {
    [OutputType([void])]
    param([string]$Name)
    # Fixed stage names only: source paths and compiler output stay in the
    # private build log, and no user workspace or credentials exist here.
    Write-Output $Name
    try { [System.IO.File]::WriteAllText('COM1', $Name + "`r`n") } catch { }
}

$Source = Join-Path $PayloadRoot 'source'
$NodeDirectory = Join-Path $PayloadRoot 'node'
$Node = Join-Path $NodeDirectory 'node.exe'
$Npm = Join-Path $NodeDirectory 'node_modules\npm\bin\npm-cli.js'
$Python = Join-Path $PayloadRoot 'python\python.exe'
$Headers = Join-Path $PayloadRoot 'headers'
$CacheRoot = Join-Path $PayloadRoot 'npm-cache'
$PythonScript = Join-Path $PayloadRoot 'extensions.py'
$ExtensionLock = Join-Path $PayloadRoot 'extensions.lock.json'
$SigningKey = Join-Path $PayloadRoot 'open-vsx-key.pem'
$VsWhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
foreach ($Required in @($Source, $Node, $Npm, $Python, $Headers, $CacheRoot, $PythonScript, $ExtensionLock, $SigningKey, $VsWhere)) {
    if (-not (Test-Path -LiteralPath $Required)) { throw 'native_editor_input_missing' }
}
$Toolchain = & $VsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Toolchain)) { throw 'native_editor_toolchain_missing' }
$DeveloperCommand = Join-Path ([string]$Toolchain).Trim() 'Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path -LiteralPath $DeveloperCommand)) { throw 'native_editor_toolchain_missing' }
$DeveloperShim = 'C:\overalls\overalls-vsdevcmd.cmd'
Set-Content -LiteralPath $DeveloperShim -Encoding ASCII -Value @(
    ('call "' + $DeveloperCommand + '" -no_logo -arch=x64 -host_arch=x64')
    'set'
)
$Environment = & $env:ComSpec /d /s /c $DeveloperShim
if ($LASTEXITCODE -ne 0) { throw 'native_editor_toolchain_failed' }
foreach ($Line in $Environment) {
    if ($Line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process') }
}
$env:PATH = $NodeDirectory + ';' + (Join-Path $PayloadRoot 'python') + ';C:\Program Files\Git\cmd;' + $env:PATH
$env:NODE_ENV = 'development'
$env:NODE_OPTIONS = '--max-old-space-size=16384'
$env:BUILD_SOURCEVERSION = (Get-Content -LiteralPath (Join-Path $PayloadRoot 'source-commit') -Raw).Trim()
$env:PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = '1'
$env:ELECTRON_SKIP_BINARY_DOWNLOAD = '1'
$env:npm_config_offline = 'true'
$env:npm_config_progress = 'false'
$env:npm_config_runtime = 'node'
$env:npm_config_target = (Get-Content -LiteralPath (Join-Path $PayloadRoot 'node-version') -Raw).Trim()
$env:npm_config_build_from_source = 'true'
$env:npm_config_nodedir = $Headers
$env:npm_config_python = $Python
$env:NODE_GYP_FORCE_PYTHON = $Python
$env:npm_config_node_gyp = Join-Path $NodeDirectory 'node_modules\npm\node_modules\node-gyp\bin\node-gyp.js'
# The reviewed Windows builder may not have the optional Spectre library
# workload. Native addons are compiled with the toolchain's ordinary CRT; an
# addon must never silently fall back to a downloaded prebuild.
$env:SpectreMitigation = 'false'
$Directories = Get-Content -LiteralPath (Join-Path $PayloadRoot 'npm-directories.json') -Raw | ConvertFrom-Json
if (-not ($Directories -is [System.Array]) -or $Directories.Count -gt 128) { throw 'native_editor_directory_inventory_invalid' }

Push-Location $Source
try {
    # Nix payload files arrive read-only. The native build mutates package
    # manifests and creates node_modules in this private staging tree only.
    Invoke-Native 'attrib.exe' @('-R', (Join-Path $Source '*'), '/S', '/D')
    Write-Checkpoint 'OVERALLS-EDITOR-NPM-START'
    foreach ($Directory in $Directories) {
        if (-not ($Directory -is [string]) -or $Directory -notmatch '^(\.|[a-z][a-z0-9/-]*)$' -or $Directory.Contains('..')) {
            throw 'native_editor_directory_inventory_invalid'
        }
        Push-Location (Join-Path $Source $Directory)
        try {
            $env:npm_config_cache = Join-Path $CacheRoot $Directory
            Invoke-Native $Node @($Npm, 'ci', '--ignore-scripts', '--no-audit', '--no-fund', '--offline')
        } finally { Pop-Location }
    }
    Invoke-Native $Node @((Join-Path $PayloadRoot 'prepare-windows.mts'), $Source, $PayloadRoot)
    $env:npm_config_cache = Join-Path $CacheRoot 'remote'
    Invoke-Native $Node @($Npm, '--prefix', 'remote', 'prune', '--ignore-scripts', '--no-audit', '--no-fund', '--offline')
    Write-Checkpoint 'OVERALLS-EDITOR-NATIVE-START'
    Invoke-Native $Node @($Npm, '--prefix', 'remote', 'rebuild', '--build-from-source', '--no-audit', '--no-fund', '--offline')
    Write-Checkpoint 'OVERALLS-EDITOR-COMPILE-START'
    Invoke-Native $Node @($Npm, 'run', 'typecheck-client')
    $TypeScript = Join-Path $Source 'node_modules\typescript\bin\tsc6'
    if (-not (Test-Path -LiteralPath $TypeScript)) { throw 'native_editor_typescript_missing' }
    Invoke-Native $Node @($TypeScript, '--noEmit', '--strict', '--skipLibCheck', '--target', 'es2022', '--module', 'nodenext', '--types', 'node', '--typeRoots', (Join-Path $Source 'node_modules\@types'), (Join-Path $Source 'prepare-windows.mts'))
    $Esbuild = Join-Path $Source 'build\node_modules\esbuild\bin\esbuild'
    if (-not (Test-Path -LiteralPath $Esbuild)) { throw 'native_editor_esbuild_missing' }
    $MaintenanceRoot = Join-Path $OutputDirectory 'lib\overalls-maintenance'
    $MaintenanceStage = Join-Path $env:TEMP 'overalls-maintenance.bundle.mjs'
    Invoke-Native $Node @($Esbuild, (Join-Path $Source 'maintenance-entry.ts'), '--bundle', '--platform=node', '--format=esm', '--packages=external', ('--outfile=' + $MaintenanceStage))
    Invoke-Native $Node @($Npm, 'run', 'gulp', '--', 'vscode-reh-web-win32-x64-min')
    $Bundle = Join-Path (Split-Path $Source -Parent) 'vscode-reh-web-win32-x64'
    foreach ($Required in @('node.exe', 'out\server-main.js', 'product.json', 'bin\overalls-code.cmd')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Bundle $Required))) { throw 'native_editor_bundle_incomplete' }
    }
    if (Test-Path -LiteralPath $OutputDirectory) { throw 'native_editor_output_exists' }
    Copy-Item -LiteralPath $Bundle -Destination $OutputDirectory -Recurse
    Copy-Item -LiteralPath (Join-Path $PayloadRoot 'overalls-editor-release.json') -Destination $OutputDirectory
    New-Item -ItemType Directory -Path $MaintenanceRoot -Force | Out-Null
    Copy-Item -LiteralPath $MaintenanceStage -Destination (Join-Path $MaintenanceRoot 'maintenance.bundle.mjs')
    Copy-Item -LiteralPath (Join-Path $PayloadRoot 'check-extension.mts') -Destination $MaintenanceRoot
    Copy-Item -LiteralPath (Join-Path $PayloadRoot 'extensions.lock.json') -Destination (Join-Path $OutputDirectory 'overalls-editor-extensions.json')
    New-Item -ItemType Directory -Path (Join-Path $OutputDirectory 'project-language-adapters') -Force | Out-Null
    Copy-Item -Path (Join-Path $PayloadRoot 'windows-language-adapters\*.bat') -Destination (Join-Path $OutputDirectory 'project-language-adapters')
    $ExtensionInputRoot = Join-Path $PayloadRoot 'extension-inputs'
    foreach ($Input in (Get-ChildItem -LiteralPath $ExtensionInputRoot -Directory | Sort-Object Name)) {
        $ExtensionOutput = Join-Path $OutputDirectory ('extensions\' + $Input.Name)
        $ExtensionArgs = @(
            $PythonScript, 'extract', '--lock', $ExtensionLock,
            '--id', $Input.Name, '--vsix', (Join-Path $Input.FullName 'extension.vsix'),
            '--signature', (Join-Path $Input.FullName 'extension.sigzip'),
            '--node', $Node, '--validator', (Join-Path $MaintenanceRoot 'check-extension.mts'),
            '--key', $SigningKey, '--editor-version', '1.141.0', '--output', $ExtensionOutput
        )
        Invoke-Native $Python @ExtensionArgs
    }
    # Successful source compilation is explicitly separate from native browser
    # acceptance and leaves the retained windows-v1 manifest unchanged.
    [System.IO.File]::WriteAllText((Join-Path $OutputDirectory 'native-build-complete'), 'editor_capability=false')
    Write-Checkpoint 'OVERALLS-EDITOR-NATIVE-COMPLETE'
} finally { Pop-Location }
