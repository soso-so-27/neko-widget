# Temporarily enables only the private staging KMS binding for a browser-driven
# synthetic round trip. The public preservation Worker remains disabled. The
# gate returns OFF after the signal file appears or after 90 seconds.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$service = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$wrangler = Join-Path $service 'node_modules\.bin\wrangler.cmd'
$kmsConfig = Join-Path $service 'wrangler.kms.staging.jsonc'
$publicConfig = Join-Path $service 'wrangler.jsonc'
$keyArn = 'arn:aws:kms:ap-northeast-1:164892691568:key/339319dc-388b-4bd7-adb8-29d37d836d72'
$signal = Join-Path $env:TEMP ('neko-kms-probe-' + [guid]::NewGuid().ToString('N') + '.signal')

function Require-Exit([string]$step) {
  if ($LASTEXITCODE -ne 0) { throw "$step failed (exit $LASTEXITCODE)" }
}
function Get-LiveBindings([string]$config, [string[]]$extra) {
  $deployments = & $wrangler deployments list --config $config @extra --json | ConvertFrom-Json
  Require-Exit 'Deployment read'
  $latest = @($deployments) | Sort-Object created_on | Select-Object -Last 1
  if ($null -eq $latest -or @($latest.versions).Count -ne 1 -or $latest.versions[0].percentage -ne 100) {
    throw 'Deployment missing or split'
  }
  $version = & $wrangler versions view $latest.versions[0].version_id --config $config @extra --json | ConvertFrom-Json
  Require-Exit 'Version read'
  return @($version.resources.bindings)
}
function Require-Var([object[]]$bindings, [string]$name, [string]$value) {
  if (@($bindings | Where-Object { $_.name -eq $name -and $_.type -eq 'plain_text' -and $_.text -eq $value }).Count -ne 1) {
    throw "Unexpected gate or setting: $name"
  }
}

Set-Location -LiteralPath $service
$local = Get-Content -LiteralPath $kmsConfig -Raw
if ($local -notmatch '"workers_dev"\s*:\s*false' -or $local -notmatch '"preview_urls"\s*:\s*false' -or $local -match '"routes"\s*:' -or $local -notmatch '"PRESERVATION_KMS_ENABLED"\s*:\s*"NO"') {
  throw 'Unsafe local KMS config'
}
$kms = Get-LiveBindings $kmsConfig @()
Require-Var $kms 'PRESERVATION_KMS_ENABLED' 'NO'
Require-Var $kms 'KMS_KEY_ARN' $keyArn
$public = Get-LiveBindings $publicConfig @('--env', 'staging')
Require-Var $public 'PRESERVATION_ENABLED' 'NO'
Require-Var $public 'CLEANUP_ENABLED' 'NO'
Require-Var $public 'RECOVERY_COPY_ENABLED' 'NO'
$names = & $wrangler secret list --config $kmsConfig --format json | ConvertFrom-Json
Require-Exit 'Secret-name read'
foreach ($name in @('KEY_WRAPPER_CALLER_SECRET', 'KMS_ACCESS_KEY_ID', 'KMS_SECRET_ACCESS_KEY')) {
  if (@($names | Where-Object name -eq $name).Count -ne 1) { throw "Missing private secret: $name" }
}

$probeError = $null
$cleanupError = $null
try {
  & $wrangler deploy --config $kmsConfig `
    --var 'PRESERVATION_KMS_ENABLED:YES' `
    --var 'KMS_REGION:ap-northeast-1' --var "KMS_KEY_ARN:$keyArn" `
    --message 'Temporary private KMS synthetic probe; automatic OFF rollback'
  Require-Exit 'Temporary KMS deploy'
  $kms = Get-LiveBindings $kmsConfig @()
  Require-Var $kms 'PRESERVATION_KMS_ENABLED' 'YES'
  Require-Var $kms 'KMS_KEY_ARN' $keyArn
  Write-Output "READY signal=$signal"
  for ($attempt = 0; $attempt -lt 90; $attempt++) {
    if (Test-Path -LiteralPath $signal) { break }
    Start-Sleep -Seconds 1
  }
} catch { $probeError = $_ }
finally {
  try {
    & $wrangler deploy --config $kmsConfig --message 'Restore private KMS gate OFF after synthetic probe'
    Require-Exit 'KMS OFF deployment'
    $kms = Get-LiveBindings $kmsConfig @()
    Require-Var $kms 'PRESERVATION_KMS_ENABLED' 'NO'
    $public = Get-LiveBindings $publicConfig @('--env', 'staging')
    Require-Var $public 'PRESERVATION_ENABLED' 'NO'
    Require-Var $public 'CLEANUP_ENABLED' 'NO'
    Require-Var $public 'RECOVERY_COPY_ENABLED' 'NO'
  } catch { $cleanupError = $_ }
  if (Test-Path -LiteralPath $signal) { Remove-Item -LiteralPath $signal }
}
if ($null -ne $cleanupError) { throw "INCIDENT: KMS OFF rollback unverified. $cleanupError" }
if ($null -ne $probeError) { throw "KMS probe window failed; gates verified OFF. $probeError" }
Write-Output 'Private KMS gate OFF verified; IAM keys were not changed.'
