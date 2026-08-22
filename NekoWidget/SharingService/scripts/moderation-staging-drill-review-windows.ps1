[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("DecryptForHumanReview", "DeleteAfterHumanReview")]
    [string]$Mode,

    [string]$KeyDirectory,

    [Parameter(Mandatory = $true)]
    [string]$DrillDirectory,

    [Parameter(Mandatory = $true)]
    [switch]$ConfirmLocalEncryptedNoSync,

    [switch]$ConfirmSyntheticStagingOnly,

    [switch]$ConfirmHumanReviewCompleteAndDelete
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-SecurityProof([string]$SecurityMode, [string]$Directory) {
    $securityScript = Join-Path $PSScriptRoot "moderation-staging-keygen-windows-security.ps1"
    $windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $proof = & $windowsPowerShell `
        -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $securityScript `
        -Mode $SecurityMode `
        -OutputDirectory $Directory `
        -ConfirmLocalEncryptedNoSync
    $expected = "NEKO_MODERATION_KEYGEN_WINDOWS_$($SecurityMode.ToUpperInvariant())_V1"
    if ($LASTEXITCODE -ne 0 -or $proof -ne $expected) {
        throw "security proof missing"
    }
}

try {
    if (-not $ConfirmLocalEncryptedNoSync.IsPresent) { throw "confirmation missing" }
    $node = (Get-Command node -CommandType Application).Source
    $tool = Join-Path $PSScriptRoot "moderation-report-tool.mjs"
    $verifier = Join-Path $PSScriptRoot "verify-moderation-staging-drill-completion.mjs"
    $metadata = Join-Path $DrillDirectory "synthetic-export.json"
    $ciphertext = Join-Path $DrillDirectory "synthetic-report.ciphertext"
    $review = Join-Path $DrillDirectory "synthetic-review.jpg"
    $receipt = Join-Path $DrillDirectory "synthetic-review.jpg.receipt"
    $audit = Join-Path $DrillDirectory "synthetic-audit.jsonl"

    if ($Mode -eq "DecryptForHumanReview") {
        if (-not $ConfirmSyntheticStagingOnly.IsPresent -or
            [string]::IsNullOrWhiteSpace($KeyDirectory)) {
            throw "synthetic staging confirmation or key directory missing"
        }
        Invoke-SecurityProof -SecurityMode "ValidateKeyDirectory" -Directory $KeyDirectory
        Invoke-SecurityProof -SecurityMode "ValidateDrillForReview" -Directory $DrillDirectory
        & $node $verifier --phase bundle --drill-dir $DrillDirectory
        if ($LASTEXITCODE -ne 0) { throw "fixed synthetic bundle preflight failed" }
        $privateKey = Join-Path $KeyDirectory "moderation-v1.private.raw"
        & $node $tool decrypt `
            --metadata $metadata `
            --ciphertext $ciphertext `
            --private-key $privateKey `
            --output $review `
            --audit-log $audit
        if ($LASTEXITCODE -ne 0) { throw "offline decrypt failed" }
        Invoke-SecurityProof -SecurityMode "HardenDrillReviewFiles" -Directory $DrillDirectory
        & $node $verifier --phase review --drill-dir $DrillDirectory
        if ($LASTEXITCODE -ne 0) { throw "fixed synthetic review verification failed" }
        Write-Output "Synthetic staging report decrypted and ACL-hardened. Stop here: a human operator must inspect the fixed review JPEG locally; nothing was deleted."
        return
    }

    if (-not $ConfirmHumanReviewCompleteAndDelete.IsPresent) {
        throw "human review deletion confirmation missing"
    }
    Invoke-SecurityProof -SecurityMode "ValidateDrillForDelete" -Directory $DrillDirectory
    & $node $verifier --phase review --drill-dir $DrillDirectory
    if ($LASTEXITCODE -ne 0) { throw "fixed synthetic review revalidation failed" }
    & $node $tool delete `
        --metadata $metadata `
        --file $review `
        --kind plaintext `
        --receipt $receipt `
        --audit-log $audit `
        --confirm-delete
    if ($LASTEXITCODE -ne 0) { throw "plaintext deletion failed" }
    & $node $tool delete `
        --metadata $metadata `
        --file $ciphertext `
        --kind ciphertext `
        --audit-log $audit `
        --confirm-delete
    if ($LASTEXITCODE -ne 0) { throw "ciphertext deletion failed" }
    Invoke-SecurityProof -SecurityMode "ValidateDrillAfterDelete" -Directory $DrillDirectory
    & $node $verifier --phase deleted --drill-dir $DrillDirectory
    if ($LASTEXITCODE -ne 0) { throw "completion evidence verification failed" }
    Write-Output "Synthetic staging moderation decrypt/delete drill completed. Plaintext, receipt, and ciphertext absence plus exact audit transitions were verified. Runtime and upload remain off."
} catch {
    # Never print paths, private/public key values, decrypted bytes, or raw
    # exceptions. Any partial review directory stays restricted for incident
    # recovery; this wrapper never guesses at a destructive resume.
    throw "Synthetic staging moderation review/delete step refused; keep the restricted directory quarantined for two-person recovery."
}
