function Stop-TrustedModerationNodeCheck([string]$Message) {
    throw "Trusted moderation Node check refused: $Message"
}

function Initialize-TrustedModerationNodeIdentityHelper {
    if ("NekoWidget.TrustedModerationNodeIdentity" -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace NekoWidget {
    public static class TrustedModerationNodeIdentity {
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
                if (handle.IsInvalid)
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                BY_HANDLE_FILE_INFORMATION information;
                if (!GetFileInformationByHandle(handle, out information))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                var buffer = new System.Text.StringBuilder(32768);
                uint length = GetFinalPathNameByHandle(
                    handle, buffer, (uint)buffer.Capacity, 0);
                if (length == 0 || length >= buffer.Capacity)
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                string finalPath = buffer.ToString();
                if (finalPath.StartsWith(@"\\?\", StringComparison.Ordinal))
                    finalPath = finalPath.Substring(4);
                return finalPath + "\n" + information.NumberOfLinks.ToString();
            }
        }
    }
}
'@
}

function Test-TrustedModerationNodeAcl([string]$LiteralPath, [bool]$Directory) {
    try {
        $security = if ($Directory) {
            [System.IO.Directory]::GetAccessControl($LiteralPath)
        } else {
            [System.IO.File]::GetAccessControl($LiteralPath)
        }
        $trusted = @(
            "S-1-5-18",
            "S-1-5-32-544",
            "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"
        )
        $owner = $security.GetOwner(
            [System.Security.Principal.SecurityIdentifier]
        ).Value
        if ($trusted -notcontains $owner) { return $false }

        $dangerous = [System.Security.AccessControl.FileSystemRights]::Write -bor
            [System.Security.AccessControl.FileSystemRights]::Delete -bor
            [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
            [System.Security.AccessControl.FileSystemRights]::TakeOwnership
        if ($Directory) {
            $dangerous = $dangerous -bor
                [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles
        }
        $rules = @($security.GetAccessRules(
            $true,
            $true,
            [System.Security.Principal.SecurityIdentifier]
        ))
        foreach ($rule in $rules) {
            $inheritOnly = ($rule.PropagationFlags -band
                [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0
            if ($rule.AccessControlType -eq
                    [System.Security.AccessControl.AccessControlType]::Allow -and
                -not $inheritOnly -and
                $trusted -notcontains $rule.IdentityReference.Value -and
                ($rule.FileSystemRights -band $dangerous) -ne 0) {
                return $false
            }
        }
        return $true
    } catch {
        return $false
    }
}

function Get-TrustedModerationNodeExecutable {
    try {
        Initialize-TrustedModerationNodeIdentityHelper
        $programFiles = [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::ProgramFiles
        )
        if ([string]::IsNullOrWhiteSpace($programFiles)) {
            Stop-TrustedModerationNodeCheck "the fixed Program Files root is unavailable"
        }
        $programFiles = [System.IO.Path]::GetFullPath($programFiles).TrimEnd('\')
        if ($programFiles -notmatch '^[A-Za-z]:\\' -or
            $programFiles.Substring(3).Contains(":")) {
            Stop-TrustedModerationNodeCheck "the fixed Program Files root is invalid"
        }
        $nodeDirectory = Join-Path $programFiles "nodejs"
        $candidate = Join-Path $nodeDirectory "node.exe"
        if (-not $candidate.StartsWith(
                $programFiles + "\",
                [System.StringComparison]::OrdinalIgnoreCase)) {
            Stop-TrustedModerationNodeCheck "the fixed Node path escaped Program Files"
        }

        foreach ($directory in @($programFiles, $nodeDirectory)) {
            $item = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or
                ($item.Attributes -band
                 ([System.IO.FileAttributes]::ReparsePoint -bor
                  [System.IO.FileAttributes]::Offline)) -ne 0 -or
                -not (Test-TrustedModerationNodeAcl `
                    -LiteralPath $directory `
                    -Directory $true)) {
                Stop-TrustedModerationNodeCheck "the fixed Node directory is not trusted"
            }
            $inspection = [NekoWidget.TrustedModerationNodeIdentity]::Inspect(
                $directory,
                $true
            ).Split("`n")
            if ($inspection.Count -ne 2 -or
                -not $inspection[0].TrimEnd('\').Equals(
                    [System.IO.Path]::GetFullPath($directory).TrimEnd('\'),
                    [System.StringComparison]::OrdinalIgnoreCase)) {
                Stop-TrustedModerationNodeCheck "the fixed Node directory is not canonical"
            }
        }

        $nodeItem = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        if ($nodeItem.PSIsContainer -or $nodeItem.Length -lt 1 -or
            ($nodeItem.Attributes -band
             ([System.IO.FileAttributes]::ReparsePoint -bor
              [System.IO.FileAttributes]::Offline)) -ne 0 -or
            -not (Test-TrustedModerationNodeAcl `
                -LiteralPath $candidate `
                -Directory $false)) {
            Stop-TrustedModerationNodeCheck "the fixed Node executable is not trusted"
        }
        $nodeInspection = [NekoWidget.TrustedModerationNodeIdentity]::Inspect(
            $candidate,
            $false
        ).Split("`n")
        if ($nodeInspection.Count -ne 2 -or [uint32]$nodeInspection[1] -ne 1 -or
            -not $nodeInspection[0].Equals(
                [System.IO.Path]::GetFullPath($candidate),
                [System.StringComparison]::OrdinalIgnoreCase)) {
            Stop-TrustedModerationNodeCheck "the fixed Node executable is linked or noncanonical"
        }

        $nodeVersion = & $candidate --version 2>$null
        if ($LASTEXITCODE -ne 0 -or $nodeVersion -isnot [string] -or
            $nodeVersion -notmatch '^v([0-9]+)\.[0-9]+\.[0-9]+$' -or
            [int]$Matches[1] -lt 22) {
            Stop-TrustedModerationNodeCheck "Node 22 or later is required"
        }
        return $candidate
    } catch {
        if ($_.Exception.Message -like "Trusted moderation Node check refused:*") {
            throw
        }
        Stop-TrustedModerationNodeCheck "the fixed Node executable could not be proved"
    }
}

function Disable-InheritedModerationNodeEnvironment {
    $saved = @{}
    foreach ($entry in @(Get-ChildItem Env:)) {
        if ($entry.Name.StartsWith(
                "NODE_",
                [System.StringComparison]::OrdinalIgnoreCase)) {
            $saved[$entry.Name] = $entry.Value
            Remove-Item -LiteralPath "Env:$($entry.Name)" -ErrorAction Stop
        }
    }
    if (Test-Path -LiteralPath "Env:PSModulePath") {
        $saved["PSModulePath"] = $env:PSModulePath
        Remove-Item -LiteralPath "Env:PSModulePath" -ErrorAction Stop
    }
    if (-not (Test-Path -LiteralPath "Env:SystemRoot")) {
        Stop-TrustedModerationNodeCheck "the inherited Windows system root is unavailable"
    }
    $saved["SystemRoot"] = $env:SystemRoot
    $env:SystemRoot = "C:\Windows"
    return ,$saved
}

function Restore-InheritedModerationNodeEnvironment([hashtable]$Saved) {
    if ($null -eq $Saved) { return }
    foreach ($entry in $Saved.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable(
            [string]$entry.Key,
            [string]$entry.Value,
            [EnvironmentVariableTarget]::Process
        )
    }
}
