[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $true)]
    [switch]$ConfirmLocalEncryptedNoSync
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "moderation-windows-trusted-node.ps1")

$savedNodeEnvironment = $null

try {
    if (-not $ConfirmLocalEncryptedNoSync.IsPresent) { throw "confirmation missing" }
    $savedNodeEnvironment = Disable-InheritedModerationNodeEnvironment
    $securityScript = Join-Path $PSScriptRoot "moderation-staging-keygen-windows-security.ps1"
    $windowsPowerShell = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    $preparation = & $windowsPowerShell `
        -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $securityScript `
        -Mode PrepareDirectory `
        -OutputDirectory $OutputDirectory `
        -ModerationKeyId moderation-v2 `
        -ConfirmLocalEncryptedNoSync
    if ($LASTEXITCODE -ne 0 -or
        $preparation -ne "NEKO_MODERATION_KEYGEN_WINDOWS_PREPAREDIRECTORY_V1") {
        throw "preparation proof missing"
    }

    $node = Get-TrustedModerationNodeExecutable
    $script = Join-Path $PSScriptRoot "generate-moderation-staging-key.mjs"
    & $node $script --output-dir $OutputDirectory --confirm-local-encrypted-nosync
    if ($LASTEXITCODE -ne 0) { throw "Node helper failed" }

    Write-Output "Staging moderation-v2 key directory passed BitLocker, local NTFS, and restricted ACL checks."
} catch {
    # The Node helper performs identity-bound cleanup for files it creates.
    # Never delete by a user-controlled path here: a restricted partial
    # directory is safer than deleting a replaced path after a race.
    throw "Staging moderation key generation refused; a restricted partial directory may require quarantine."
} finally {
    Restore-InheritedModerationNodeEnvironment -Saved $savedNodeEnvironment
}
