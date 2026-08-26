[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "PrepareCaseDirectory",
        "DecryptForHumanReview",
        "DeletePlaintextAfterReview",
        "DeleteCiphertextAfterReview"
    )]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [ValidateSet("moderation-v1", "moderation-v2")]
    [string]$ModerationKeyId,

    [Parameter(Mandatory = $true)]
    [string]$KeyDirectory,

    [Parameter(Mandatory = $true)]
    [string]$CaseDirectory,

    [string]$ExpectedPublicKeySHA256,

    [Parameter(Mandatory = $true)]
    [switch]$ConfirmLocalEncryptedNoSync,

    [switch]$ConfirmHumanReviewCompleteAndDelete
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "moderation-windows-trusted-node.ps1")

$savedNodeEnvironment = $null

$WindowsPowerShell = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
$SecurityScript = Join-Path $PSScriptRoot "moderation-staging-keygen-windows-security.ps1"
$Tool = Join-Path $PSScriptRoot "moderation-report-tool.mjs"

function Invoke-SecurityProof(
    [string]$SecurityMode,
    [string]$Directory,
    [switch]$RequireDisjointKeyDirectory
) {
    $arguments = @(
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $SecurityScript,
        "-Mode",
        $SecurityMode,
        "-OutputDirectory",
        $Directory,
        "-ModerationKeyId",
        $ModerationKeyId,
        "-ConfirmLocalEncryptedNoSync"
    )
    if ($RequireDisjointKeyDirectory.IsPresent) {
        $arguments += @("-DisjointDirectory", $KeyDirectory)
    }
    $proof = & $WindowsPowerShell @arguments 2>$null
    $expected = "NEKO_MODERATION_KEYGEN_WINDOWS_$($SecurityMode.ToUpperInvariant())_V1"
    if ($LASTEXITCODE -ne 0 -or $proof -isnot [string] -or $proof -cne $expected) {
        throw "security proof missing"
    }
}

try {
    if (-not $ConfirmLocalEncryptedNoSync.IsPresent) { throw "confirmation missing" }
    $savedNodeEnvironment = Disable-InheritedModerationNodeEnvironment
    if ($Mode -ne "PrepareCaseDirectory" -and
        ([string]::IsNullOrWhiteSpace($ExpectedPublicKeySHA256) -or
         $ExpectedPublicKeySHA256 -cnotmatch '^[0-9a-f]{64}$')) {
        throw "reviewed fingerprint missing"
    }
    if (($Mode -eq "DeletePlaintextAfterReview" -or
         $Mode -eq "DeleteCiphertextAfterReview") -and
        -not $ConfirmHumanReviewCompleteAndDelete.IsPresent) {
        throw "human review deletion confirmation missing"
    }
    if (-not (Test-Path -LiteralPath $WindowsPowerShell -PathType Leaf)) {
        throw "fixed Windows PowerShell missing"
    }

    Invoke-SecurityProof -SecurityMode "ValidateKeyDirectory" -Directory $KeyDirectory
    if ($Mode -eq "PrepareCaseDirectory") {
        Invoke-SecurityProof `
            -SecurityMode "PrepareModerationCaseDirectory" `
            -Directory $CaseDirectory `
            -RequireDisjointKeyDirectory
        Write-Output "Restricted Windows moderation case directory prepared. Copy only the fixed export and ciphertext files, then continue with the decrypt mode."
        return
    }

    $node = Get-TrustedModerationNodeExecutable
    $privateKey = Join-Path $KeyDirectory "$ModerationKeyId.private.raw"
    $metadata = Join-Path $CaseDirectory "moderation-export.json"
    $ciphertext = Join-Path $CaseDirectory "moderation-report.ciphertext"
    $review = Join-Path $CaseDirectory "moderation-review.jpg"
    $receipt = Join-Path $CaseDirectory "moderation-review.jpg.receipt"
    $audit = Join-Path $CaseDirectory "moderation-audit.jsonl"

    if ($Mode -eq "DecryptForHumanReview") {
        Invoke-SecurityProof `
            -SecurityMode "HardenModerationDecryptInput" `
            -Directory $CaseDirectory `
            -RequireDisjointKeyDirectory
        $nodeOutput = & $node $Tool decrypt `
            --metadata $metadata `
            --ciphertext $ciphertext `
            --moderation-key-id $ModerationKeyId `
            --private-key $privateKey `
            --expected-public-key-sha256 $ExpectedPublicKeySHA256 `
            --output $review `
            --audit-log $audit 2>$null
        if ($LASTEXITCODE -ne 0 -or $nodeOutput -isnot [string] -or
            $nodeOutput -cne "Report decrypted and validated; restricted review output created.") {
            throw "offline decrypt failed"
        }
        Write-Output "Windows moderation review artifact created behind the fixed ACL and file-set boundary."
        return
    }

    if ($Mode -eq "DeletePlaintextAfterReview") {
        $nodeOutput = & $node $Tool delete `
            --metadata $metadata `
            --file $review `
            --kind plaintext `
            --receipt $receipt `
            --moderation-key-id $ModerationKeyId `
            --private-key $privateKey `
            --expected-public-key-sha256 $ExpectedPublicKeySHA256 `
            --audit-log $audit `
            --confirm-delete 2>$null
        if ($LASTEXITCODE -ne 0 -or $nodeOutput -isnot [string] -or
            $nodeOutput -cne "Confirmed local moderation artifact deleted; audit event appended.") {
            throw "plaintext deletion failed"
        }
        Write-Output "Windows moderation plaintext and receipt deletion completed behind the fixed ACL and file-set boundary."
        return
    }

    $nodeOutput = & $node $Tool delete `
        --metadata $metadata `
        --file $ciphertext `
        --kind ciphertext `
        --moderation-key-id $ModerationKeyId `
        --private-key $privateKey `
        --expected-public-key-sha256 $ExpectedPublicKeySHA256 `
        --audit-log $audit `
        --confirm-delete 2>$null
    if ($LASTEXITCODE -ne 0 -or $nodeOutput -isnot [string] -or
        $nodeOutput -cne "Confirmed local moderation artifact deleted; audit event appended.") {
        throw "ciphertext deletion failed"
    }
    Write-Output "Windows moderation ciphertext deletion completed behind the fixed ACL and file-set boundary."
} catch {
    # Do not echo paths, fingerprints, raw exceptions, or review content. A
    # partial case directory remains quarantined for two-person recovery.
    [Console]::Error.WriteLine(
        "Windows moderation operation refused; keep the restricted case directory quarantined for two-person recovery."
    )
    exit 1
} finally {
    Restore-InheritedModerationNodeEnvironment -Saved $savedNodeEnvironment
}
