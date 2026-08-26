[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$KeyDirectory,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $true)]
    [ValidateSet("moderation-v1", "moderation-v2")]
    [string]$ModerationKeyId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$ExpectedPublicKeySHA256,

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

    $keyProof = & $windowsPowerShell `
        -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $securityScript `
        -Mode ValidateKeyDirectory `
        -OutputDirectory $KeyDirectory `
        -ModerationKeyId $ModerationKeyId `
        -ConfirmLocalEncryptedNoSync
    if ($LASTEXITCODE -ne 0 -or
        $keyProof -ne "NEKO_MODERATION_KEYGEN_WINDOWS_VALIDATEKEYDIRECTORY_V1") {
        throw "key-directory proof missing"
    }

    $preparation = & $windowsPowerShell `
        -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $securityScript `
        -Mode PrepareDrillDirectory `
        -OutputDirectory $OutputDirectory `
        -DisjointDirectory $KeyDirectory `
        -ConfirmLocalEncryptedNoSync
    if ($LASTEXITCODE -ne 0 -or
        $preparation -ne "NEKO_MODERATION_KEYGEN_WINDOWS_PREPAREDRILLDIRECTORY_V1") {
        throw "drill-directory preparation proof missing"
    }

    $node = Get-TrustedModerationNodeExecutable
    $script = Join-Path $PSScriptRoot "generate-moderation-staging-drill.mjs"
    $publicKeyFile = Join-Path $KeyDirectory "$ModerationKeyId.public.base64url"
    & $node $script `
        --public-key-file $publicKeyFile `
        --moderation-key-id $ModerationKeyId `
        --expected-public-key-sha256 $ExpectedPublicKeySHA256 `
        --output-dir $OutputDirectory `
        --confirm-local-encrypted-nosync
    if ($LASTEXITCODE -ne 0) { throw "Node helper failed" }

    Write-Output "Synthetic staging moderation bundle passed public-key-only, BitLocker, local NTFS, and restricted ACL checks. Runtime and upload remain off."
} catch {
    # Do not print operator paths or raw exceptions. Node performs
    # identity-bound cleanup; a restricted partial directory is quarantined
    # instead of deleting a user-controlled/replaced path here.
    throw "Synthetic staging moderation drill generation refused; a restricted partial directory may require quarantine."
} finally {
    Restore-InheritedModerationNodeEnvironment -Saved $savedNodeEnvironment
}
