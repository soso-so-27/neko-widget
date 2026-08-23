[CmdletBinding()]
param(
    [string]$ConfigDirectory,

    [switch]$ConfirmPersonalStagingEmergencyOff,

    [switch]$DryRun,

    [switch]$PolicySelfTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$policySentinel = "NEKO_PERSONAL_STAGING_EMERGENCY_OFF_POLICY_SELFTEST_V1"
$expectedOrigin = "https://neko-window-sharing-staging.nakanishisoya.workers.dev"
function Assert-EmergencyOffRunMode {
    param(
        [bool]$IsDryRun,
        [bool]$HasConfirmation,
        [string]$ResolvedConfigRoot,
        [string]$ResolvedScriptRoot
    )

    if (-not $IsDryRun -and -not $HasConfirmation) {
        throw "actual emergency OFF requires -ConfirmPersonalStagingEmergencyOff"
    }
    if (-not $IsDryRun -and
        -not [StringComparer]::OrdinalIgnoreCase.Equals($ResolvedConfigRoot, $ResolvedScriptRoot)) {
        throw "an actual emergency OFF must run from the same reviewed SharingService worktree as this script"
    }
}

function Assert-ApprovedSourceState {
    param(
        [bool]$IsDetachedHead,
        [bool]$IsAncestorOfOriginMain
    )

    if (-not $IsDetachedHead) {
        throw "actual emergency OFF requires the prepared detached runtime worktree"
    }
    if (-not $IsAncestorOfOriginMain) {
        throw "actual emergency OFF requires a commit already present in origin/main"
    }
}

if ($PolicySelfTest.IsPresent) {
    $missingConfirmationRejected = $false
    try {
        Assert-EmergencyOffRunMode $false $false "C:\reviewed" "C:\reviewed"
    } catch {
        $missingConfirmationRejected = $_.Exception.Message -eq
            "actual emergency OFF requires -ConfirmPersonalStagingEmergencyOff"
    }
    if (-not $missingConfirmationRejected) { throw "missing confirmation policy self-test failed" }

    $differentWorktreeRejected = $false
    try {
        Assert-EmergencyOffRunMode $false $true "C:\other" "C:\reviewed"
    } catch {
        $differentWorktreeRejected = $_.Exception.Message -eq
            "an actual emergency OFF must run from the same reviewed SharingService worktree as this script"
    }
    if (-not $differentWorktreeRejected) { throw "same-worktree policy self-test failed" }

    Assert-EmergencyOffRunMode $true $false "C:\other" "C:\reviewed"

    $attachedHeadRejected = $false
    try {
        Assert-ApprovedSourceState $false $true
    } catch {
        $attachedHeadRejected = $_.Exception.Message -eq
            "actual emergency OFF requires the prepared detached runtime worktree"
    }
    if (-not $attachedHeadRejected) { throw "detached HEAD policy self-test failed" }

    $unmergedCommitRejected = $false
    try {
        Assert-ApprovedSourceState $true $false
    } catch {
        $unmergedCommitRejected = $_.Exception.Message -eq
            "actual emergency OFF requires a commit already present in origin/main"
    }
    if (-not $unmergedCommitRejected) { throw "origin/main ancestry policy self-test failed" }

    Assert-ApprovedSourceState $true $true
    Write-Output $policySentinel
    return
}

$scriptServiceRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigDirectory)) {
    $ConfigDirectory = $scriptServiceRoot
}

$configRoot = (Resolve-Path -LiteralPath $ConfigDirectory -ErrorAction Stop).Path
$reviewedScriptRoot = (Resolve-Path -LiteralPath $scriptServiceRoot -ErrorAction Stop).Path
Assert-EmergencyOffRunMode `
    $DryRun.IsPresent `
    $ConfirmPersonalStagingEmergencyOff.IsPresent `
    $configRoot `
    $reviewedScriptRoot

$configPath = Join-Path $configRoot "wrangler.staging.jsonc"
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "reviewed ignored OFF config is missing"
}

$git = Get-Command git.exe -CommandType Application -ErrorAction Stop |
    Select-Object -First 1 -ExpandProperty Source
$node = Get-Command node.exe -CommandType Application -ErrorAction Stop |
    Select-Object -First 1 -ExpandProperty Source
$npm = Get-Command npm.cmd -CommandType Application -ErrorAction Stop |
    Select-Object -First 1 -ExpandProperty Source
$npx = Get-Command npx.cmd -CommandType Application -ErrorAction Stop |
    Select-Object -First 1 -ExpandProperty Source

& $git -C $configRoot check-ignore --quiet -- "wrangler.staging.jsonc"
if ($LASTEXITCODE -ne 0) { throw "OFF config must remain ignored by Git" }
if (-not $DryRun.IsPresent) {
    & $git -C $configRoot ls-files --error-unmatch -- "scripts/personal-staging-emergency-off-windows.ps1" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "emergency OFF script must be tracked in the reviewed worktree" }
    $worktreeStatus = (& $git -C $configRoot status --porcelain --untracked-files=all -- . | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $worktreeStatus.Length -ne 0) {
        throw "actual emergency OFF requires a clean reviewed SharingService worktree"
    }

    $branchName = (& $git -C $configRoot symbolic-ref --quiet --short HEAD 2>$null | Out-String).Trim()
    $symbolicRefExit = $LASTEXITCODE
    if ($symbolicRefExit -ne 0 -and $symbolicRefExit -ne 1) {
        throw "could not verify detached HEAD state"
    }
    $isDetachedHead = $symbolicRefExit -eq 1 -and $branchName.Length -eq 0

    & $git -C $configRoot rev-parse --verify "refs/remotes/origin/main^{commit}" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "origin/main is unavailable; fetch the reviewed remote state first" }
    & $git -C $configRoot merge-base --is-ancestor HEAD refs/remotes/origin/main
    $ancestryExit = $LASTEXITCODE
    if ($ancestryExit -ne 0 -and $ancestryExit -ne 1) {
        throw "could not verify origin/main ancestry"
    }
    Assert-ApprovedSourceState $isDetachedHead ($ancestryExit -eq 0)
}

$bundleName = "neko-personal-staging-emergency-off-" + [guid]::NewGuid().ToString("N")
$bundleDirectory = Join-Path ([IO.Path]::GetTempPath()) $bundleName
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$bundleFullPath = [IO.Path]::GetFullPath($bundleDirectory)
if (-not $bundleFullPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path -Leaf $bundleFullPath) -ne $bundleName) {
    throw "temporary bundle path validation failed"
}

Push-Location -LiteralPath $configRoot
try {
    & $npm run staging:config:check
    if ($LASTEXITCODE -ne 0) { throw "staging OFF config policy check failed" }

    $wranglerVersion = (& $npx --no-install wrangler --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $wranglerVersion -notmatch "(?m)\b4\.125\.0\b") {
        throw "reviewed Wrangler 4.125.0 is required"
    }

    $commit = (& $git rev-parse --short=12 HEAD | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -notmatch "\A[0-9a-f]{12}\z") {
        throw "could not resolve the reviewed commit"
    }

    New-Item -ItemType Directory -Path $bundleFullPath -ErrorAction Stop | Out-Null
    & $npx --no-install wrangler deploy `
        --dry-run `
        --config $configPath `
        --outdir $bundleFullPath `
        --autoconfig=false `
        --experimental-provision=false `
        --experimental-auto-create=false
    if ($LASTEXITCODE -ne 0) { throw "emergency OFF bundle dry-run failed" }

    if ($DryRun.IsPresent) {
        Write-Output "PASS personal staging emergency OFF dry-run; no deployment was performed."
        return
    }

    & $npx --no-install wrangler deploy `
        --strict `
        --config $configPath `
        --autoconfig=false `
        --keep-vars=false `
        --message "personal staging emergency OFF; moment+window-name+legacy OFF; $commit" `
        --experimental-provision=false `
        --experimental-auto-create=false
    if ($LASTEXITCODE -ne 0) { throw "emergency OFF deployment failed" }
} finally {
    Pop-Location
    if (Test-Path -LiteralPath $bundleFullPath -PathType Container) {
        $verifiedBundle = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $bundleFullPath).Path)
        if (-not $verifiedBundle.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Leaf $verifiedBundle) -ne $bundleName) {
            throw "temporary bundle cleanup path validation failed"
        }
        Remove-Item -LiteralPath $verifiedBundle -Recurse -Force
    }
}

$runtimeCheck = Join-Path $PSScriptRoot "check-staging-runtime.mjs"
$verifiedOff = $false
for ($attempt = 1; $attempt -le 6; $attempt += 1) {
    & $node $runtimeCheck --origin $expectedOrigin --expected off
    if ($LASTEXITCODE -eq 0) {
        $verifiedOff = $true
        break
    }
    if ($attempt -lt 6) { Start-Sleep -Seconds 5 }
}
if (-not $verifiedOff) {
    throw "deployment returned, but the public runtime did not reach the expected OFF boundary"
}

Write-Output "PASS personal staging emergency OFF deployed and publicly verified."
