# Shared Windows editor image custody checks. Paths are fixed by the image;
# these checks never authorize a caller-supplied executable or account.
Set-StrictMode -Version 2

# @cc [owner:ghuntley,label:security] windows-editor-image-path-custody
# Every checked path MUST reject reparse points and foreign replacement, delete
# or ACL authority in every ancestor. Package leaves MUST be owned by SYSTEM
# or Administrators with no foreign write authority; private leaves MUST be
# SYSTEM-owned and grant access only to SYSTEM. Only ancestors may retain the
# exact Windows TrustedInstaller service SID as owner or platform-update
# authority; every other ancestor owner MUST also be SYSTEM or Administrators.
function Assert-EditorPath {
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [bool]$Private = $false,
        [bool]$Ancestor = $false
    )
    if ($Path -notmatch '^C:\\' -or $Path.Contains('..')) { throw 'editor_path_invalid' }
    [System.IO.FileSystemInfo]$Item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'editor_path_reparse' }
    [System.Security.AccessControl.FileSystemSecurity]$Acl = Get-Acl -LiteralPath $Path
    [string]$Owner = $Acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    [string]$TrustedInstaller = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    [bool]$TrustedOwner = $Owner -in @('S-1-5-18', 'S-1-5-32-544') -or ($Ancestor -and $Owner -eq $TrustedInstaller)
    if (($Private -and $Owner -ne 'S-1-5-18') -or (-not $Private -and -not $TrustedOwner)) {
        throw 'editor_path_owner'
    }
    if (-not $Acl.AreAccessRulesProtected -and $Private) { throw 'editor_path_private_acl' }
    [long]$Forbidden = 0x500D0040
    if (-not $Ancestor) { $Forbidden = $Forbidden -bor 0x116 }
    $Rules = $Acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
    if ($Rules.Count -eq 0) { throw 'editor_path_missing_acl' }
    foreach ($Rule in $Rules) {
        if ($Rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny) { continue }
        if (($Rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
        [string]$Sid = $Rule.IdentityReference.Value
        if ($Sid -eq 'S-1-5-18') { continue }
        if ($Private) { throw 'editor_path_private_acl' }
        if ($Sid -eq 'S-1-5-32-544') { continue }
        if ($Ancestor -and $Sid -eq $TrustedInstaller) { continue }
        if (([long]$Rule.FileSystemRights -band $Forbidden) -ne 0) { throw 'editor_path_foreign_write' }
    }
    [System.IO.DirectoryInfo]$Parent = $null
    if ($Item -is [System.IO.DirectoryInfo]) { $Parent = $Item.Parent } else { $Parent = $Item.Directory }
    if ($null -ne $Parent) { Assert-EditorPath -Path $Parent.FullName -Ancestor $true }
}

function Assert-EditorSystem {
    [OutputType([void])]
    param()
    [string]$Sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($Sid -ne 'S-1-5-18') { throw 'editor_system_required' }
}
