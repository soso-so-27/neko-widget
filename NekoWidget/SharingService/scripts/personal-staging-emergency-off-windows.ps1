[CmdletBinding()]
param(
    [string]$ConfigDirectory,

    [string]$ControlManifestPath,

    [switch]$ConfirmPersonalStagingEmergencyOff,

    [switch]$DryRun,

    [switch]$PolicySelfTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$policySentinel = "NEKO_PERSONAL_STAGING_EMERGENCY_OFF_POLICY_SELFTEST_V2"
function Assert-EmergencyOffRunMode {
    param(
        [bool]$IsDryRun,
        [bool]$HasConfirmation
    )

    if ($HasConfirmation) {
        throw "actual broad staging emergency OFF deployment is unavailable; only -DryRun is supported"
    }
    if (-not $IsDryRun) {
        throw "use exactly -DryRun; actual broad staging emergency OFF deployment is unavailable"
    }
}

if ($PolicySelfTest.IsPresent) {
    $missingConfirmationRejected = $false
    try {
        Assert-EmergencyOffRunMode $false $false
    } catch {
        $missingConfirmationRejected = $_.Exception.Message -eq
            "use exactly -DryRun; actual broad staging emergency OFF deployment is unavailable"
    }
    if (-not $missingConfirmationRejected) { throw "missing dry-run policy self-test failed" }

    $confirmationRejected = $false
    try {
        Assert-EmergencyOffRunMode $false $true
    } catch {
        $confirmationRejected = $_.Exception.Message -eq
            "actual broad staging emergency OFF deployment is unavailable; only -DryRun is supported"
    }
    if (-not $confirmationRejected) { throw "actual deployment policy self-test failed" }

    $combinedModeRejected = $false
    try {
        Assert-EmergencyOffRunMode $true $true
    } catch {
        $combinedModeRejected = $_.Exception.Message -eq
            "actual broad staging emergency OFF deployment is unavailable; only -DryRun is supported"
    }
    if (-not $combinedModeRejected) { throw "combined run-mode policy self-test failed" }

    Assert-EmergencyOffRunMode $true $false
    Write-Output $policySentinel
    return
}

# Reject every actual-deployment invocation before resolving configuration,
# inspecting repository state, starting Wrangler, or contacting any endpoint.
Assert-EmergencyOffRunMode `
    $DryRun.IsPresent `
    $ConfirmPersonalStagingEmergencyOff.IsPresent

$scriptServiceRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigDirectory)) {
    $ConfigDirectory = $scriptServiceRoot
}

$configRoot = (Resolve-Path -LiteralPath $ConfigDirectory -ErrorAction Stop).Path

$configPath = Join-Path $configRoot "wrangler.staging.jsonc"
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "reviewed ignored OFF config is missing"
}

if ([string]::IsNullOrWhiteSpace($ControlManifestPath)) {
    $ControlManifestPath = Join-Path $configRoot "emergency-off-control-manifest.json"
}
$controlManifestFullPath = (Resolve-Path -LiteralPath $ControlManifestPath -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $controlManifestFullPath -PathType Leaf)) {
    throw "reviewed emergency OFF control manifest is missing"
}

$git = Get-Command git.exe -CommandType Application -ErrorAction Stop |
    Select-Object -First 1 -ExpandProperty Source
$node = Get-Command node.exe -CommandType Application -ErrorAction Stop |
    Select-Object -First 1 -ExpandProperty Source
$npm = Get-Command npm.cmd -CommandType Application -ErrorAction Stop |
    Select-Object -First 1 -ExpandProperty Source
$wranglerEntryPoint = Join-Path $configRoot "node_modules\wrangler\bin\wrangler.js"
if (-not (Test-Path -LiteralPath $wranglerEntryPoint -PathType Leaf)) {
    throw "reviewed local Wrangler entry point is unavailable"
}
$selectiveOffLibrary = Join-Path $configRoot "scripts\selective-staging-off-lib.mjs"
if (-not (Test-Path -LiteralPath $selectiveOffLibrary -PathType Leaf)) {
    throw "reviewed emergency OFF manifest validator is unavailable"
}

& $git -C $configRoot check-ignore --quiet -- "wrangler.staging.jsonc"
if ($LASTEXITCODE -ne 0) { throw "OFF config must remain ignored by Git" }
& $git -C $configRoot check-ignore --quiet -- $controlManifestFullPath
if ($LASTEXITCODE -ne 0) { throw "emergency OFF control manifest must remain ignored by Git" }

$bundleName = "neko-personal-staging-emergency-off-" + [guid]::NewGuid().ToString("N")
$bundleDirectory = Join-Path ([IO.Path]::GetTempPath()) $bundleName
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$bundleFullPath = [IO.Path]::GetFullPath($bundleDirectory)
if (-not $bundleFullPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path -Leaf $bundleFullPath) -ne $bundleName) {
    throw "temporary bundle path validation failed"
}

Push-Location -LiteralPath $configRoot
$wranglerEnvironment = @{
    DO_NOT_TRACK = [Environment]::GetEnvironmentVariable("DO_NOT_TRACK", "Process")
    WRANGLER_HIDE_BANNER = [Environment]::GetEnvironmentVariable("WRANGLER_HIDE_BANNER", "Process")
    WRANGLER_SEND_ERROR_REPORTS = [Environment]::GetEnvironmentVariable("WRANGLER_SEND_ERROR_REPORTS", "Process")
    WRANGLER_SEND_METRICS = [Environment]::GetEnvironmentVariable("WRANGLER_SEND_METRICS", "Process")
}
try {
    # A local bundle check must not perform telemetry, error reporting, package
    # update checks, or other network-side diagnostics.
    $env:DO_NOT_TRACK = "1"
    $env:WRANGLER_HIDE_BANNER = "true"
    $env:WRANGLER_SEND_ERROR_REPORTS = "false"
    $env:WRANGLER_SEND_METRICS = "false"

    & $npm run staging:config:check
    if ($LASTEXITCODE -ne 0) { throw "staging OFF config policy check failed" }

    & $node $selectiveOffLibrary `
        --validate-emergency-off-manifest `
        $controlManifestFullPath
    if ($LASTEXITCODE -ne 0) { throw "emergency OFF control manifest validation failed" }

    $wranglerVersion = (& $node $wranglerEntryPoint --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $wranglerVersion -notmatch "(?m)\b4\.125\.0\b") {
        throw "reviewed Wrangler 4.125.0 is required"
    }

    New-Item -ItemType Directory -Path $bundleFullPath -ErrorAction Stop | Out-Null
    & $node $wranglerEntryPoint deploy `
        --dry-run `
        --config $configPath `
        --outdir $bundleFullPath `
        --autoconfig=false `
        --experimental-provision=false `
        --experimental-auto-create=false
    if ($LASTEXITCODE -ne 0) { throw "emergency OFF bundle dry-run failed" }
} finally {
    foreach ($entry in $wranglerEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
    }
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
Write-Output "PASS personal staging broad-OFF candidate local dry-run; no external query or deployment was performed."
