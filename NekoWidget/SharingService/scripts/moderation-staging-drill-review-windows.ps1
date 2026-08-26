[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("DecryptForHumanReview", "DeleteAfterHumanReview")]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [ValidateSet("moderation-v1", "moderation-v2")]
    [string]$ModerationKeyId,

    [Parameter(Mandatory = $true)]
    [string]$PrivateKeyPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$ExpectedPublicKeySHA256,

    [Parameter(Mandatory = $true)]
    [string]$DrillDirectory,

    [Parameter(Mandatory = $true)]
    [switch]$ConfirmLocalEncryptedNoSync,

    [switch]$ConfirmSyntheticStagingOnly,

    [switch]$ConfirmHumanReviewCompleteAndDelete
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "moderation-windows-trusted-node.ps1")

$savedNodeEnvironment = $null

function Invoke-SecurityProof([string]$SecurityMode, [string]$Directory) {
    $securityScript = Join-Path $PSScriptRoot "moderation-staging-keygen-windows-security.ps1"
    $windowsPowerShell = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    $proof = & $windowsPowerShell `
        -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $securityScript `
        -Mode $SecurityMode `
        -OutputDirectory $Directory `
        -ModerationKeyId $ModerationKeyId `
        -ConfirmLocalEncryptedNoSync
    $expected = "NEKO_MODERATION_KEYGEN_WINDOWS_$($SecurityMode.ToUpperInvariant())_V1"
    if ($LASTEXITCODE -ne 0 -or $proof -ne $expected) {
        throw "security proof missing"
    }
}

try {
    if (-not $ConfirmLocalEncryptedNoSync.IsPresent) { throw "confirmation missing" }
    $savedNodeEnvironment = Disable-InheritedModerationNodeEnvironment
    $node = Get-TrustedModerationNodeExecutable
    $tool = Join-Path $PSScriptRoot "moderation-report-tool.mjs"
    $verifier = Join-Path $PSScriptRoot "verify-moderation-staging-drill-completion.mjs"
    $metadata = Join-Path $DrillDirectory "synthetic-export.json"
    $ciphertext = Join-Path $DrillDirectory "synthetic-report.ciphertext"
    $review = Join-Path $DrillDirectory "synthetic-review.jpg"
    $receipt = Join-Path $DrillDirectory "synthetic-review.jpg.receipt"
    $audit = Join-Path $DrillDirectory "synthetic-audit.jsonl"
    if ([System.IO.Path]::GetFileName($PrivateKeyPath) -cne "$ModerationKeyId.private.raw") {
        throw "private key path does not match reviewed key ID"
    }
    $KeyDirectory = [System.IO.Path]::GetDirectoryName(
        [System.IO.Path]::GetFullPath($PrivateKeyPath)
    )
    if ([string]::IsNullOrWhiteSpace($KeyDirectory)) { throw "key directory missing" }
    Invoke-SecurityProof -SecurityMode "ValidateKeyDirectory" -Directory $KeyDirectory

    if ($Mode -eq "DecryptForHumanReview") {
        if (-not $ConfirmSyntheticStagingOnly.IsPresent) {
            throw "synthetic staging confirmation missing"
        }
        Invoke-SecurityProof -SecurityMode "ValidateDrillForReview" -Directory $DrillDirectory
        & $node $verifier `
            --phase bundle `
            --drill-dir $DrillDirectory `
            --moderation-key-id $ModerationKeyId
        if ($LASTEXITCODE -ne 0) { throw "fixed synthetic bundle preflight failed" }
        & $node $tool decrypt `
            --metadata $metadata `
            --ciphertext $ciphertext `
            --moderation-key-id $ModerationKeyId `
            --private-key $PrivateKeyPath `
            --expected-public-key-sha256 $ExpectedPublicKeySHA256 `
            --output $review `
            --audit-log $audit
        if ($LASTEXITCODE -ne 0) { throw "offline decrypt failed" }
        Invoke-SecurityProof -SecurityMode "HardenDrillReviewFiles" -Directory $DrillDirectory
        & $node $verifier `
            --phase review `
            --drill-dir $DrillDirectory `
            --moderation-key-id $ModerationKeyId
        if ($LASTEXITCODE -ne 0) { throw "fixed synthetic review verification failed" }
        Write-Output "Synthetic staging report decrypted and ACL-hardened. Stop here: a human operator must inspect the fixed review JPEG locally; nothing was deleted."
        return
    }

    if (-not $ConfirmHumanReviewCompleteAndDelete.IsPresent) {
        throw "human review deletion confirmation missing"
    }
    Invoke-SecurityProof -SecurityMode "ValidateDrillForDelete" -Directory $DrillDirectory
    & $node $verifier `
        --phase review `
        --drill-dir $DrillDirectory `
        --moderation-key-id $ModerationKeyId
    if ($LASTEXITCODE -ne 0) { throw "fixed synthetic review revalidation failed" }
    & $node $tool delete `
        --metadata $metadata `
        --file $review `
        --kind plaintext `
        --receipt $receipt `
        --moderation-key-id $ModerationKeyId `
        --private-key $PrivateKeyPath `
        --expected-public-key-sha256 $ExpectedPublicKeySHA256 `
        --audit-log $audit `
        --confirm-delete
    if ($LASTEXITCODE -ne 0) { throw "plaintext deletion failed" }
    & $node $tool delete `
        --metadata $metadata `
        --file $ciphertext `
        --kind ciphertext `
        --moderation-key-id $ModerationKeyId `
        --private-key $PrivateKeyPath `
        --expected-public-key-sha256 $ExpectedPublicKeySHA256 `
        --audit-log $audit `
        --confirm-delete
    if ($LASTEXITCODE -ne 0) { throw "ciphertext deletion failed" }
    Invoke-SecurityProof -SecurityMode "ValidateDrillAfterDelete" -Directory $DrillDirectory
    & $node $verifier `
        --phase deleted `
        --drill-dir $DrillDirectory `
        --moderation-key-id $ModerationKeyId
    if ($LASTEXITCODE -ne 0) { throw "completion evidence verification failed" }
    Write-Output "Synthetic staging moderation decrypt/delete drill completed. Plaintext, receipt, and ciphertext absence plus exact audit transitions were verified. Runtime and upload remain off."
} catch {
    # Never print paths, private/public key values, decrypted bytes, or raw
    # exceptions. Any partial review directory stays restricted for incident
    # recovery; this wrapper never guesses at a destructive resume.
    throw "Synthetic staging moderation review/delete step refused; keep the restricted directory quarantined for two-person recovery."
} finally {
    Restore-InheritedModerationNodeEnvironment -Saved $savedNodeEnvironment
}
