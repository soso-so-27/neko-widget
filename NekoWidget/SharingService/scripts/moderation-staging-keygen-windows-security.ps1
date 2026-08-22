[CmdletBinding()]
param(
    [ValidateSet("PrepareDirectory", "VerifyDirectory", "HardenFiles")]
    [string]$Mode,

    [string]$OutputDirectory,

    [switch]$ConfirmLocalEncryptedNoSync,

    [switch]$PolicySelfTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Stop-SecurityCheck([string]$Message) {
    throw "Windows staging key security check refused: $Message"
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
    $fullOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
    if ($fullOutput -notmatch '^[A-Za-z]:\\' -or $fullOutput.Substring(3).Contains(":")) {
        Stop-SecurityCheck "UNC, device, extended, and alternate-stream paths are not allowed"
    }
    if (Test-KnownProviderPath -FullOutput $fullOutput) {
        Stop-SecurityCheck "known cloud-sync roots are not allowed"
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

    if ($Mode -eq "PrepareDirectory") {
        if (Test-Path -LiteralPath $fullOutput) {
            Stop-SecurityCheck "the output directory must not already exist"
        }
        [void][System.IO.Directory]::CreateDirectory($fullOutput)
        Set-ExactAcl -LiteralPath $fullOutput -CurrentUserSid $currentSid -Directory $true
        $prepared = Get-Item -LiteralPath $fullOutput -Force
        if (Test-ForbiddenFileAttributes -Attributes $prepared.Attributes) {
            Stop-SecurityCheck "the prepared output directory is offline"
        }
    } else {
        $directory = Get-Item -LiteralPath $fullOutput -Force
        if (-not $directory.PSIsContainer -or
            (Test-ForbiddenFileAttributes -Attributes $directory.Attributes) -or
            -not (Test-ExactAcl -LiteralPath $fullOutput -CurrentUserSid $currentSid -Directory $true)) {
            Stop-SecurityCheck "the prepared output directory is not exact and restricted"
        }
    }

    if ($Mode -eq "PrepareDirectory" -or $Mode -eq "VerifyDirectory") {
        if (@(Get-ChildItem -LiteralPath $fullOutput -Force).Count -ne 0) {
            Stop-SecurityCheck "the prepared output directory is not empty"
        }
    } else {
        $expected = @{
            "moderation-v1.private.raw" = 32
            "moderation-v1.public.base64url" = 43
        }
        $items = @(Get-ChildItem -LiteralPath $fullOutput -Force)
        if ($items.Count -ne 2) { Stop-SecurityCheck "the fixed key file set is incomplete" }
        foreach ($item in $items) {
            if (-not $expected.ContainsKey($item.Name) -or $item.PSIsContainer -or
                (Test-ForbiddenFileAttributes -Attributes $item.Attributes) -or
                $item.Length -ne $expected[$item.Name]) {
                Stop-SecurityCheck "a fixed key file is invalid"
            }
            Set-ExactAcl -LiteralPath $item.FullName -CurrentUserSid $currentSid -Directory $false
        }
    }

    Write-Output "NEKO_MODERATION_KEYGEN_WINDOWS_$($Mode.ToUpperInvariant())_V1"
} catch {
    # Never echo raw exceptions: filesystem errors commonly contain the
    # operator's output path. The caller only receives a fixed refusal.
    Write-Error "Windows staging moderation key security verification failed."
    exit 1
}
