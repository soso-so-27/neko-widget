[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$KeyDirectory,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $true)]
    [switch]$ConfirmLocalEncryptedNoSync
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

try {
    if (-not $ConfirmLocalEncryptedNoSync.IsPresent) { throw "confirmation missing" }
    $securityScript = Join-Path $PSScriptRoot "moderation-staging-keygen-windows-security.ps1"
    $windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

    $keyProof = & $windowsPowerShell `
        -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $securityScript `
        -Mode ValidateKeyDirectory `
        -OutputDirectory $KeyDirectory `
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

    $node = (Get-Command node -CommandType Application).Source
    $script = Join-Path $PSScriptRoot "generate-moderation-staging-drill.mjs"
    $publicKeyFile = Join-Path $KeyDirectory "moderation-v1.public.base64url"
    & $node $script `
        --public-key-file $publicKeyFile `
        --output-dir $OutputDirectory `
        --confirm-local-encrypted-nosync
    if ($LASTEXITCODE -ne 0) { throw "Node helper failed" }

    Write-Output "Synthetic staging moderation bundle passed public-key-only, BitLocker, local NTFS, and restricted ACL checks. Runtime and upload remain off."
} catch {
    # Do not print operator paths or raw exceptions. Node performs
    # identity-bound cleanup; a restricted partial directory is quarantined
    # instead of deleting a user-controlled/replaced path here.
    throw "Synthetic staging moderation drill generation refused; a restricted partial directory may require quarantine."
}
