[CmdletBinding()]
param(
    [ValidateSet(
        "PrepareDirectory",
        "VerifyDirectory",
        "HardenFiles",
        "ValidateKeyDirectory",
        "PrepareDrillDirectory",
        "VerifyDrillDirectory",
        "HardenDrillFiles",
        "ValidateDrillForReview",
        "HardenDrillReviewFiles",
        "ValidateDrillForDelete",
        "ValidateDrillAfterDelete"
    )]
    [string]$Mode,

    [string]$OutputDirectory,

    [string]$DisjointDirectory,

    [switch]$ConfirmLocalEncryptedNoSync,

    [switch]$PolicySelfTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Stop-SecurityCheck([string]$Message) {
    throw "Windows staging key security check refused: $Message"
}

function Test-Administrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-FileIdentityHelper {
    if ("NekoWidget.Win32FileIdentity" -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace NekoWidget {
    public static class Win32FileIdentity {
        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string name, uint access, uint share, IntPtr security,
            uint creation, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION information);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(
            SafeFileHandle handle, System.Text.StringBuilder path,
            uint pathLength, uint flags);

        public static string Inspect(string path, bool directory) {
            const uint ShareAll = 0x00000001 | 0x00000002 | 0x00000004;
            const uint OpenExisting = 3;
            const uint BackupSemantics = 0x02000000;
            using (SafeFileHandle handle = CreateFile(
                path, 0, ShareAll, IntPtr.Zero, OpenExisting,
                directory ? BackupSemantics : 0, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                BY_HANDLE_FILE_INFORMATION info;
                if (!GetFileInformationByHandle(handle, out info))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                var buffer = new System.Text.StringBuilder(32768);
                uint length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
                if (length == 0 || length >= buffer.Capacity)
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                string finalPath = buffer.ToString();
                if (finalPath.StartsWith(@"\\?\", StringComparison.Ordinal))
                    finalPath = finalPath.Substring(4);
                return finalPath + "\n" + info.NumberOfLinks.ToString();
            }
        }
    }
}
'@
}

function Get-CanonicalSingleLinkPath([string]$LiteralPath, [bool]$Directory) {
    try {
        Initialize-FileIdentityHelper
        $parts = [NekoWidget.Win32FileIdentity]::Inspect($LiteralPath, $Directory).Split("`n")
        if ($parts.Count -ne 2 -or [uint32]$parts[1] -ne 1) { return $null }
        return $parts[0].TrimEnd('\')
    } catch {
        return $null
    }
}

function Test-CanonicalSingleLinkPath([string]$LiteralPath, [bool]$Directory) {
    try {
        $final = Get-CanonicalSingleLinkPath -LiteralPath $LiteralPath -Directory $Directory
        if ([string]::IsNullOrWhiteSpace($final)) { return $false }
        $full = [System.IO.Path]::GetFullPath($LiteralPath).TrimEnd('\')
        return $full.Equals($final, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Test-FullyQualifiedLocalPath([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value -notmatch '^[A-Za-z]:[\\/]' -or
        $Value.StartsWith("\\") -or $Value.StartsWith("//")) {
        return $false
    }
    try {
        $full = [System.IO.Path]::GetFullPath($Value)
        return $full -match '^[A-Za-z]:\\' -and -not $full.Substring(3).Contains(":")
    } catch {
        return $false
    }
}

function Test-ForbiddenFileAttributes([System.IO.FileAttributes]$Attributes) {
    $forbidden = [System.IO.FileAttributes]::ReparsePoint -bor
        [System.IO.FileAttributes]::Offline
    return ($Attributes -band $forbidden) -ne 0
}

function Test-VolumeProtection($Volume, $BitLocker) {
    try {
        return $Volume.DriveType.ToString() -eq "Fixed" -and
            $Volume.FileSystem -eq "NTFS" -and
            $BitLocker.VolumeStatus.ToString() -eq "FullyEncrypted" -and
            $BitLocker.ProtectionStatus.ToString() -eq "On" -and
            [int]$BitLocker.EncryptionPercentage -eq 100 -and
            $BitLocker.LockStatus.ToString() -eq "Unlocked"
    } catch {
        return $false
    }
}

function Get-AllowedSidValues(
    [System.Security.Principal.SecurityIdentifier]$CurrentUserSid
) {
    return @($CurrentUserSid.Value, "S-1-5-18", "S-1-5-32-544")
}

function Test-ExactAcl(
    [string]$LiteralPath,
    [System.Security.Principal.SecurityIdentifier]$CurrentUserSid,
    [bool]$Directory
) {
    $security = if ($Directory) {
        [System.IO.Directory]::GetAccessControl($LiteralPath)
    } else {
        [System.IO.File]::GetAccessControl($LiteralPath)
    }
    if (-not $security.AreAccessRulesProtected) { return $false }
    if ($security.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -ne $CurrentUserSid.Value) {
        return $false
    }
    $expected = Get-AllowedSidValues -CurrentUserSid $CurrentUserSid
    $rules = @($security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne 3) { return $false }
    foreach ($rule in $rules) {
        if ($expected -notcontains $rule.IdentityReference.Value -or
            $rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
            $rule.IsInherited -or
            (($rule.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne
             [System.Security.AccessControl.FileSystemRights]::FullControl)) {
            return $false
        }
        if ($Directory) {
            $required = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
            if ($rule.InheritanceFlags -ne $required) { return $false }
        } elseif ($rule.InheritanceFlags -ne [System.Security.AccessControl.InheritanceFlags]::None) {
            return $false
        }
    }
    foreach ($sid in $expected) {
        if (@($rules | Where-Object { $_.IdentityReference.Value -eq $sid }).Count -ne 1) {
            return $false
        }
    }
    return $true
}

function Set-ExactAcl(
    [string]$LiteralPath,
    [System.Security.Principal.SecurityIdentifier]$CurrentUserSid,
    [bool]$Directory
) {
    $security = if ($Directory) {
        New-Object System.Security.AccessControl.DirectorySecurity
    } else {
        New-Object System.Security.AccessControl.FileSecurity
    }
    $security.SetOwner($CurrentUserSid)
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sidText in (Get-AllowedSidValues -CurrentUserSid $CurrentUserSid)) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($sidText)
        $inheritance = if ($Directory) {
            [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        } else {
            [System.Security.AccessControl.InheritanceFlags]::None
        }
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$security.AddAccessRule($rule)
    }
    if ($Directory) {
        [System.IO.Directory]::SetAccessControl($LiteralPath, $security)
    } else {
        [System.IO.File]::SetAccessControl($LiteralPath, $security)
    }
    if (-not (Test-ExactAcl -LiteralPath $LiteralPath -CurrentUserSid $CurrentUserSid -Directory $Directory)) {
        Stop-SecurityCheck "the exact restricted ACL could not be proved"
    }
}

function Get-TrustedPathSidValues(
    [System.Security.Principal.SecurityIdentifier]$CurrentUserSid
) {
    return @(
        $CurrentUserSid.Value,
        "S-1-5-18",
        "S-1-5-32-544",
        "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"
    )
}

function Test-SafeDirectorySecurity(
    [System.Security.AccessControl.DirectorySecurity]$Security,
    [System.Security.Principal.SecurityIdentifier]$CurrentUserSid,
    [bool]$CheckProspectiveChildInheritance
) {
    $trusted = Get-TrustedPathSidValues -CurrentUserSid $CurrentUserSid
    $security = $Security
    $owner = $security.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($trusted -notcontains $owner) { return $false }
    $componentReplacement = [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership
    $deleteChild = [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles
    $replacementRights = $componentReplacement -bor $deleteChild
    $writeIntoDirectory = [System.Security.AccessControl.FileSystemRights]::Write
    $rules = @($security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
            $trusted -contains $rule.IdentityReference.Value) {
            continue
        }
        $appliesToThisDirectory = ($rule.PropagationFlags -band
            [System.Security.AccessControl.PropagationFlags]::InheritOnly) -eq 0
        $appliesToProspectiveChild = $CheckProspectiveChildInheritance -and
            (($rule.InheritanceFlags -band
             [System.Security.AccessControl.InheritanceFlags]::ContainerInherit) -ne 0)
        if (($appliesToThisDirectory -and
             ($rule.FileSystemRights -band $replacementRights) -ne 0) -or
            ($CheckProspectiveChildInheritance -and $appliesToThisDirectory -and
             ($rule.FileSystemRights -band $writeIntoDirectory) -ne 0) -or
            ($appliesToProspectiveChild -and
             ($rule.FileSystemRights -band
              ($replacementRights -bor $writeIntoDirectory)) -ne 0)) {
            return $false
        }
    }
    return $true
}

function Test-SafeAncestorChain(
    [string]$LiteralParent,
    [System.Security.Principal.SecurityIdentifier]$CurrentUserSid
) {
    $cursor = [System.IO.DirectoryInfo]::new($LiteralParent)
    $immediateParent = $true
    while ($null -ne $cursor) {
        if (Test-ForbiddenFileAttributes -Attributes $cursor.Attributes) {
            return $false
        }
        $security = [System.IO.Directory]::GetAccessControl($cursor.FullName)
        if (-not (Test-SafeDirectorySecurity `
            -Security $security `
            -CurrentUserSid $CurrentUserSid `
            -CheckProspectiveChildInheritance $immediateParent)) {
            return $false
        }
        $immediateParent = $false
        $cursor = $cursor.Parent
    }
    return $true
}

function Test-KnownProviderPath([string]$FullOutput) {
    $providerRoots = @(
        $env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial,
        $env:Dropbox, $env:DropboxPath, $env:iCloudDrive,
        $env:GoogleDrive, $env:GoogleDriveFS, $env:Box, $env:BoxDrive
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($providerRoot in $providerRoots) {
        $providerFull = [System.IO.Path]::GetFullPath($providerRoot).TrimEnd('\')
        if ($FullOutput.Equals($providerFull, [System.StringComparison]::OrdinalIgnoreCase) -or
            $FullOutput.StartsWith($providerFull + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $FullOutput -match '(?i)\\(?:OneDrive(?:\s*-\s*[^\\]+)?|Dropbox|iCloud(?: Drive)?|Google Drive|Box(?: Sync)?|pCloud|Nextcloud)(?:\\|$)'
}

function Test-PathWithin([string]$Candidate, [string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
    try {
        $candidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\')
        $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
        return $candidateFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
            $candidateFull.StartsWith($rootFull + "\", [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $true
    }
}

function Test-DisjointOperationalDirectories(
    [string]$ExistingDirectory,
    [string]$ProspectiveDirectory
) {
    try {
        if (-not (Test-FullyQualifiedLocalPath -Value $ExistingDirectory) -or
            -not (Test-FullyQualifiedLocalPath -Value $ProspectiveDirectory)) {
            return $false
        }
        $keyCanonical = Get-CanonicalSingleLinkPath `
            -LiteralPath $ExistingDirectory `
            -Directory $true
        $outputFull = [System.IO.Path]::GetFullPath($ProspectiveDirectory)
        $outputParent = [System.IO.Path]::GetDirectoryName($outputFull)
        $parentCanonical = Get-CanonicalSingleLinkPath `
            -LiteralPath $outputParent `
            -Directory $true
        if ([string]::IsNullOrWhiteSpace($keyCanonical) -or
            [string]::IsNullOrWhiteSpace($parentCanonical)) {
            return $false
        }
        $prospectiveCanonical = Join-Path `
            $parentCanonical `
            ([System.IO.Path]::GetFileName($outputFull.TrimEnd('\')))
        return -not (Test-PathWithin -Candidate $prospectiveCanonical -Root $keyCanonical) -and
            -not (Test-PathWithin -Candidate $keyCanonical -Root $prospectiveCanonical)
    } catch {
        return $false
    }
}

function Test-RestrictedOperationalPath([string]$FullOutput) {
    $repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
    $roots = @(
        (Get-Location).Path,
        $repositoryRoot,
        [System.IO.Path]::GetTempPath(),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    )
    foreach ($root in $roots) {
        if (Test-PathWithin -Candidate $FullOutput -Root $root) { return $true }
    }
    return $false
}

function Test-ExactFixedFiles(
    [string]$LiteralDirectory,
    [hashtable]$Contract,
    [System.Security.Principal.SecurityIdentifier]$CurrentUserSid,
    [bool]$Harden
) {
    $items = @(Get-ChildItem -LiteralPath $LiteralDirectory -Force)
    if ($items.Count -ne $Contract.Count) { return $false }
    foreach ($item in $items) {
        if ($Contract.Keys -cnotcontains $item.Name -or $item.PSIsContainer -or
            (Test-ForbiddenFileAttributes -Attributes $item.Attributes) -or
            -not (Test-CanonicalSingleLinkPath -LiteralPath $item.FullName -Directory $false)) {
            return $false
        }
        $bounds = $Contract[$item.Name]
        if ($item.Length -lt $bounds[0] -or $item.Length -gt $bounds[1]) { return $false }
        if ($Harden) {
            Set-ExactAcl -LiteralPath $item.FullName -CurrentUserSid $CurrentUserSid -Directory $false
        } elseif (-not (Test-ExactAcl `
            -LiteralPath $item.FullName `
            -CurrentUserSid $CurrentUserSid `
            -Directory $false)) {
            return $false
        }
    }
    return $true
}

function Invoke-PolicySelfTest {
    if (-not (Test-FullyQualifiedLocalPath -Value "C:\safe\keys") -or
        (Test-FullyQualifiedLocalPath -Value "C:relative") -or
        (Test-FullyQualifiedLocalPath -Value "\\server\share\keys") -or
        (Test-FullyQualifiedLocalPath -Value "C:\safe\keys:hidden")) {
        throw "path policy fixture failed"
    }
    if (-not (Test-ForbiddenFileAttributes -Attributes ([System.IO.FileAttributes]::Offline)) -or
        -not (Test-ForbiddenFileAttributes -Attributes ([System.IO.FileAttributes]::ReparsePoint)) -or
        (Test-ForbiddenFileAttributes -Attributes ([System.IO.FileAttributes]::Normal))) {
        throw "attribute policy fixture failed"
    }

    $validVolume = [pscustomobject]@{ DriveType = "Fixed"; FileSystem = "NTFS" }
    $validBitLocker = [pscustomobject]@{
        VolumeStatus = "FullyEncrypted"
        ProtectionStatus = "On"
        EncryptionPercentage = 100
        LockStatus = "Unlocked"
    }
    if (-not (Test-VolumeProtection -Volume $validVolume -BitLocker $validBitLocker)) {
        throw "valid volume fixture failed"
    }
    foreach ($invalid in @(
        @([pscustomobject]@{ DriveType = "Removable"; FileSystem = "NTFS" }, $validBitLocker),
        @([pscustomobject]@{ DriveType = "Fixed"; FileSystem = "ReFS" }, $validBitLocker),
        @($validVolume, [pscustomobject]@{ VolumeStatus = "EncryptionInProgress"; ProtectionStatus = "On"; EncryptionPercentage = 99; LockStatus = "Unlocked" }),
        @($validVolume, [pscustomobject]@{ VolumeStatus = "FullyEncrypted"; ProtectionStatus = "Off"; EncryptionPercentage = 100; LockStatus = "Unlocked" }),
        @($validVolume, [pscustomobject]@{ VolumeStatus = "FullyEncrypted"; ProtectionStatus = "On"; EncryptionPercentage = 100; LockStatus = "Locked" })
    )) {
        if (Test-VolumeProtection -Volume $invalid[0] -BitLocker $invalid[1]) {
            throw "invalid volume fixture was accepted"
        }
    }

    $testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("neko-keygen-acl-test-" + [guid]::NewGuid().ToString("N"))
    $privateFile = Join-Path $testDirectory "moderation-v1.private.raw"
    $publicFile = Join-Path $testDirectory "moderation-v1.public.base64url"
    try {
        [void][System.IO.Directory]::CreateDirectory($testDirectory)
        if (-not (Test-CanonicalSingleLinkPath -LiteralPath $testDirectory -Directory $true)) {
            throw "directory identity fixture failed"
        }
        $childCandidate = Join-Path $testDirectory "drill-child"
        $siblingCandidate = Join-Path `
            ([System.IO.Path]::GetDirectoryName($testDirectory)) `
            ("neko-drill-sibling-" + [guid]::NewGuid().ToString("N"))
        if ((Test-DisjointOperationalDirectories `
                -ExistingDirectory $testDirectory `
                -ProspectiveDirectory $testDirectory) -or
            (Test-DisjointOperationalDirectories `
                -ExistingDirectory $testDirectory `
                -ProspectiveDirectory $childCandidate) -or
            -not (Test-DisjointOperationalDirectories `
                -ExistingDirectory $testDirectory `
                -ProspectiveDirectory $siblingCandidate) -or
            (Test-Path -LiteralPath $childCandidate) -or
            (Test-Path -LiteralPath $siblingCandidate)) {
            throw "key/drill directory disjointness fixture failed"
        }
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        Set-ExactAcl -LiteralPath $testDirectory -CurrentUserSid $currentSid -Directory $true
        $exactDirectorySecurity = [System.IO.Directory]::GetAccessControl($testDirectory)
        if (-not (Test-ExactAcl -LiteralPath $testDirectory -CurrentUserSid $currentSid -Directory $true) -or
            -not (Test-SafeDirectorySecurity `
                -Security $exactDirectorySecurity `
                -CurrentUserSid $currentSid `
                -CheckProspectiveChildInheritance $true)) {
            throw "directory ACL round-trip failed"
        }
        [System.IO.File]::WriteAllBytes($privateFile, [byte[]]::new(32))
        [System.IO.File]::WriteAllBytes($publicFile, [byte[]]::new(43))
        if (-not (Test-CanonicalSingleLinkPath -LiteralPath $privateFile -Directory $false) -or
            -not (Test-CanonicalSingleLinkPath -LiteralPath $publicFile -Directory $false)) {
            throw "file identity fixture failed"
        }
        Set-ExactAcl -LiteralPath $privateFile -CurrentUserSid $currentSid -Directory $false
        Set-ExactAcl -LiteralPath $publicFile -CurrentUserSid $currentSid -Directory $false
        if (-not (Test-ExactAcl -LiteralPath $privateFile -CurrentUserSid $currentSid -Directory $false) -or
            -not (Test-ExactAcl -LiteralPath $publicFile -CurrentUserSid $currentSid -Directory $false)) {
            throw "file ACL round-trip failed"
        }
        $everyone = New-Object System.Security.Principal.SecurityIdentifier("S-1-1-0")
        foreach ($dangerousRight in @(
            [System.Security.AccessControl.FileSystemRights]::Delete,
            [System.Security.AccessControl.FileSystemRights]::ChangePermissions,
            [System.Security.AccessControl.FileSystemRights]::TakeOwnership,
            [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles
        )) {
            $unsafe = [System.IO.Directory]::GetAccessControl($testDirectory)
            $unsafeRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $everyone,
                $dangerousRight,
                [System.Security.AccessControl.InheritanceFlags]::None,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            [void]$unsafe.AddAccessRule($unsafeRule)
            if (Test-SafeDirectorySecurity `
                -Security $unsafe `
                -CurrentUserSid $currentSid `
                -CheckProspectiveChildInheritance $false) {
                throw "unsafe component replacement ACL fixture was accepted"
            }
        }

        $inheritableUnsafe = [System.IO.Directory]::GetAccessControl($testDirectory)
        $inheritableUnsafeRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $everyone,
            [System.Security.AccessControl.FileSystemRights]::Delete,
            [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
            [System.Security.AccessControl.PropagationFlags]::InheritOnly,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$inheritableUnsafe.AddAccessRule($inheritableUnsafeRule)
        if ((Test-SafeDirectorySecurity `
                -Security $inheritableUnsafe `
                -CurrentUserSid $currentSid `
                -CheckProspectiveChildInheritance $true) -or
            -not (Test-SafeDirectorySecurity `
                -Security $inheritableUnsafe `
                -CurrentUserSid $currentSid `
                -CheckProspectiveChildInheritance $false)) {
            throw "prospective child inheritance ACL fixture failed"
        }

        foreach ($creationRight in @(
            [System.Security.AccessControl.FileSystemRights]::CreateDirectories,
            [System.Security.AccessControl.FileSystemRights]::CreateFiles,
            [System.Security.AccessControl.FileSystemRights]::Write
        )) {
            foreach ($inheritanceFixture in @($false, $true)) {
                $creation = [System.IO.Directory]::GetAccessControl($testDirectory)
                $inheritance = if ($inheritanceFixture) {
                    [System.Security.AccessControl.InheritanceFlags]::ContainerInherit
                } else {
                    [System.Security.AccessControl.InheritanceFlags]::None
                }
                $propagation = if ($inheritanceFixture) {
                    [System.Security.AccessControl.PropagationFlags]::InheritOnly
                } else {
                    [System.Security.AccessControl.PropagationFlags]::None
                }
                $creationRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $everyone,
                    $creationRight,
                    $inheritance,
                    $propagation,
                    [System.Security.AccessControl.AccessControlType]::Allow
                )
                [void]$creation.AddAccessRule($creationRule)
                if ((Test-SafeDirectorySecurity `
                        -Security $creation `
                        -CurrentUserSid $currentSid `
                        -CheckProspectiveChildInheritance $true) -or
                    -not (Test-SafeDirectorySecurity `
                        -Security $creation `
                        -CurrentUserSid $currentSid `
                        -CheckProspectiveChildInheritance $false)) {
                    throw "immediate-parent creation race ACL fixture failed"
                }
            }
        }

        $untrustedOwner = New-Object System.Security.AccessControl.DirectorySecurity
        $untrustedOwner.SetOwner($everyone)
        if (Test-SafeDirectorySecurity `
            -Security $untrustedOwner `
            -CurrentUserSid $currentSid `
            -CheckProspectiveChildInheritance $false) {
            throw "untrusted owner fixture was accepted"
        }
        $trustedInstaller = New-Object System.Security.Principal.SecurityIdentifier(
            "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"
        )
        $trustedOwner = New-Object System.Security.AccessControl.DirectorySecurity
        $trustedOwner.SetOwner($trustedInstaller)
        if (-not (Test-SafeDirectorySecurity `
            -Security $trustedOwner `
            -CurrentUserSid $currentSid `
            -CheckProspectiveChildInheritance $false)) {
            throw "trusted owner fixture was rejected"
        }
    } finally {
        foreach ($file in @($privateFile, $publicFile)) {
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                Remove-Item -LiteralPath $file -Force
            }
        }
        if (Test-Path -LiteralPath $testDirectory -PathType Container) {
            Remove-Item -LiteralPath $testDirectory -Force
        }
    }
    Write-Output "NEKO_MODERATION_KEYGEN_WINDOWS_POLICY_SELFTEST_V1"
}

if ($PolicySelfTest.IsPresent) {
    try {
        Invoke-PolicySelfTest
        return
    } catch {
        throw "Windows staging moderation key policy self-test failed."
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($Mode) -or
        [string]::IsNullOrWhiteSpace($OutputDirectory) -or
        -not $ConfirmLocalEncryptedNoSync.IsPresent) {
        Stop-SecurityCheck "explicit local encrypted no-sync confirmation is required"
    }
    if (-not (Test-FullyQualifiedLocalPath -Value $OutputDirectory)) {
        Stop-SecurityCheck "an absolute local drive path is required"
    }
    if (-not (Test-Administrator)) {
        Stop-SecurityCheck "an elevated Windows administrator session is required"
    }
    $fullOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
    if ($fullOutput -notmatch '^[A-Za-z]:\\' -or $fullOutput.Substring(3).Contains(":")) {
        Stop-SecurityCheck "UNC, device, extended, and alternate-stream paths are not allowed"
    }
    if (Test-KnownProviderPath -FullOutput $fullOutput) {
        Stop-SecurityCheck "known cloud-sync roots are not allowed"
    }
    if (Test-RestrictedOperationalPath -FullOutput $fullOutput) {
        Stop-SecurityCheck "repository, working, temporary, and user-profile roots are not allowed"
    }

    $parent = [System.IO.Path]::GetDirectoryName($fullOutput)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        Stop-SecurityCheck "the output parent directory must already exist"
    }
    $cursor = [System.IO.DirectoryInfo]::new($parent)
    while ($null -ne $cursor) {
        if (Test-ForbiddenFileAttributes -Attributes $cursor.Attributes) {
            Stop-SecurityCheck "linked, junction, reparse, and offline ancestors are not allowed"
        }
        $cursor = $cursor.Parent
    }

    $driveLetter = $fullOutput.Substring(0, 1)
    $volume = Get-Volume -DriveLetter $driveLetter
    $bitLocker = Get-BitLockerVolume -MountPoint "$driveLetter`:"
    if (-not (Test-VolumeProtection -Volume $volume -BitLocker $bitLocker)) {
        Stop-SecurityCheck "the volume must be fixed local NTFS with BitLocker fully encrypted, On, 100 percent, and unlocked"
    }

    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    if (-not (Test-SafeAncestorChain -LiteralParent $parent -CurrentUserSid $currentSid)) {
        Stop-SecurityCheck "an output ancestor permits untrusted path-component replacement"
    }

    if ($Mode -eq "PrepareDrillDirectory" -and
        ([string]::IsNullOrWhiteSpace($DisjointDirectory) -or
         -not (Test-CanonicalSingleLinkPath -LiteralPath $DisjointDirectory -Directory $true) -or
         -not (Test-DisjointOperationalDirectories `
            -ExistingDirectory $DisjointDirectory `
            -ProspectiveDirectory $fullOutput))) {
        Stop-SecurityCheck "the key and drill directories must be canonically disjoint before creation"
    }

    if ($Mode -eq "PrepareDirectory" -or $Mode -eq "PrepareDrillDirectory") {
        if (Test-Path -LiteralPath $fullOutput) {
            Stop-SecurityCheck "the output directory must not already exist"
        }
        [void][System.IO.Directory]::CreateDirectory($fullOutput)
        Set-ExactAcl -LiteralPath $fullOutput -CurrentUserSid $currentSid -Directory $true
        $prepared = Get-Item -LiteralPath $fullOutput -Force
        if ((Test-ForbiddenFileAttributes -Attributes $prepared.Attributes) -or
            -not (Test-CanonicalSingleLinkPath -LiteralPath $fullOutput -Directory $true)) {
            Stop-SecurityCheck "the prepared output directory identity is invalid"
        }
    } else {
        $directory = Get-Item -LiteralPath $fullOutput -Force
        if (-not $directory.PSIsContainer -or
            (Test-ForbiddenFileAttributes -Attributes $directory.Attributes) -or
            -not (Test-CanonicalSingleLinkPath -LiteralPath $fullOutput -Directory $true) -or
            -not (Test-ExactAcl -LiteralPath $fullOutput -CurrentUserSid $currentSid -Directory $true)) {
            Stop-SecurityCheck "the prepared output directory is not exact and restricted"
        }
    }

    $keyContract = @{
        "moderation-v1.private.raw" = @(32L, 32L)
        "moderation-v1.public.base64url" = @(43L, 43L)
    }
    $drillContract = @{
        "synthetic-export.json" = @(1L, 16384L)
        "synthetic-report.ciphertext" = @(29L, 1048576L)
    }
    $reviewContract = @{
        "synthetic-export.json" = @(1L, 16384L)
        "synthetic-report.ciphertext" = @(29L, 1048576L)
        "synthetic-review.jpg" = @(1L, 950244L)
        "synthetic-review.jpg.receipt" = @(107L, 107L)
        "synthetic-audit.jsonl" = @(1L, 4194304L)
    }
    $postDeleteContract = @{
        "synthetic-export.json" = @(1L, 16384L)
        "synthetic-audit.jsonl" = @(1L, 4194304L)
    }

    if ($Mode -eq "PrepareDirectory" -or $Mode -eq "VerifyDirectory" -or
        $Mode -eq "PrepareDrillDirectory" -or $Mode -eq "VerifyDrillDirectory") {
        if (@(Get-ChildItem -LiteralPath $fullOutput -Force).Count -ne 0) {
            Stop-SecurityCheck "the prepared output directory is not empty"
        }
    } elseif ($Mode -eq "HardenFiles") {
        if (-not (Test-ExactFixedFiles -LiteralDirectory $fullOutput -Contract $keyContract `
            -CurrentUserSid $currentSid -Harden $true)) {
            Stop-SecurityCheck "the fixed key file set could not be hardened"
        }
    } elseif ($Mode -eq "ValidateKeyDirectory") {
        if (-not (Test-ExactFixedFiles -LiteralDirectory $fullOutput -Contract $keyContract `
            -CurrentUserSid $currentSid -Harden $false)) {
            Stop-SecurityCheck "the existing fixed key file set is not exact and restricted"
        }
    } elseif ($Mode -eq "HardenDrillFiles") {
        if (-not (Test-ExactFixedFiles -LiteralDirectory $fullOutput -Contract $drillContract `
            -CurrentUserSid $currentSid -Harden $true)) {
            Stop-SecurityCheck "the fixed drill bundle could not be hardened"
        }
    } elseif ($Mode -eq "ValidateDrillForReview") {
        if (-not (Test-ExactFixedFiles -LiteralDirectory $fullOutput -Contract $drillContract `
            -CurrentUserSid $currentSid -Harden $false)) {
            Stop-SecurityCheck "the fixed drill bundle is not exact and restricted"
        }
    } elseif ($Mode -eq "HardenDrillReviewFiles") {
        if (-not (Test-ExactFixedFiles -LiteralDirectory $fullOutput -Contract $reviewContract `
            -CurrentUserSid $currentSid -Harden $true)) {
            Stop-SecurityCheck "the fixed drill review artifacts could not be hardened"
        }
    } elseif ($Mode -eq "ValidateDrillForDelete") {
        if (-not (Test-ExactFixedFiles -LiteralDirectory $fullOutput -Contract $reviewContract `
            -CurrentUserSid $currentSid -Harden $false)) {
            Stop-SecurityCheck "the fixed drill review artifacts are not exact and restricted"
        }
    } elseif ($Mode -eq "ValidateDrillAfterDelete") {
        if (-not (Test-ExactFixedFiles -LiteralDirectory $fullOutput -Contract $postDeleteContract `
            -CurrentUserSid $currentSid -Harden $false)) {
            Stop-SecurityCheck "plaintext, receipt, or ciphertext remains after the drill deletion boundary"
        }
    } else {
        Stop-SecurityCheck "the requested security mode is unsupported"
    }

    Write-Output "NEKO_MODERATION_KEYGEN_WINDOWS_$($Mode.ToUpperInvariant())_V1"
} catch {
    # Never echo raw exceptions: filesystem errors commonly contain the
    # operator's output path. The caller only receives a fixed refusal.
    Write-Error "Windows staging moderation key security verification failed."
    exit 1
}
