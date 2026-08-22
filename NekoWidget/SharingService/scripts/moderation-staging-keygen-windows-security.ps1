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

function Test-SafeParentAcl(
    [string]$LiteralPath,
    [System.Security.Principal.SecurityIdentifier]$CurrentUserSid
) {
    $security = [System.IO.Directory]::GetAccessControl($LiteralPath)
    $allowed = Get-AllowedSidValues -CurrentUserSid $CurrentUserSid
    $owner = $security.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($allowed -notcontains $owner) { return $false }
    $writeLike = [System.Security.AccessControl.FileSystemRights]::Write -bor
        [System.Security.AccessControl.FileSystemRights]::Modify -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership
    $rules = @($security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    foreach ($rule in $rules) {
        $appliesToParent = ($rule.PropagationFlags -band
            [System.Security.AccessControl.PropagationFlags]::InheritOnly) -eq 0
        $appliesToNewDirectory = ($rule.InheritanceFlags -band
            [System.Security.AccessControl.InheritanceFlags]::ContainerInherit) -ne 0
        if ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
            $allowed -notcontains $rule.IdentityReference.Value -and
            ($rule.FileSystemRights -band $writeLike) -ne 0 -and
            ($appliesToParent -or $appliesToNewDirectory)) {
            return $false
        }
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
        if (-not (Test-ExactAcl -LiteralPath $testDirectory -CurrentUserSid $currentSid -Directory $true) -or
            -not (Test-SafeParentAcl -LiteralPath $testDirectory -CurrentUserSid $currentSid)) {
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
        $inheritableUnsafe = [System.IO.Directory]::GetAccessControl($testDirectory)
        $everyone = New-Object System.Security.Principal.SecurityIdentifier("S-1-1-0")
        $inheritableUnsafeRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $everyone,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
            [System.Security.AccessControl.PropagationFlags]::InheritOnly,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$inheritableUnsafe.AddAccessRule($inheritableUnsafeRule)
        [System.IO.Directory]::SetAccessControl($testDirectory, $inheritableUnsafe)
        if (Test-SafeParentAcl -LiteralPath $testDirectory -CurrentUserSid $currentSid) {
            throw "unsafe inheritable parent ACL fixture was accepted"
        }

        Set-ExactAcl -LiteralPath $testDirectory -CurrentUserSid $currentSid -Directory $true
        $unsafe = [System.IO.Directory]::GetAccessControl($testDirectory)
        $unsafeRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $everyone,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]::None,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$unsafe.AddAccessRule($unsafeRule)
        [System.IO.Directory]::SetAccessControl($testDirectory, $unsafe)
        if (Test-SafeParentAcl -LiteralPath $testDirectory -CurrentUserSid $currentSid) {
            throw "unsafe parent ACL fixture was accepted"
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
    if (-not (Test-SafeParentAcl -LiteralPath $parent -CurrentUserSid $currentSid)) {
        Stop-SecurityCheck "the output parent permits an untrusted principal to replace children"
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
