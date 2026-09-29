# One synthetic object through the private staging Worker's S3 credentials.
# The normal disabled Worker is automatically restored. No public route or
# preservation gate is enabled, and the test object is intentionally retained.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$service = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$wrangler = Join-Path $service 'node_modules\.bin\wrangler.cmd'
$wranglerJs = Join-Path $service 'node_modules\wrangler\bin\wrangler.js'
$node = (Get-Command node.exe).Source
$config = Join-Path $service 'wrangler.jsonc'
$localConfig = Join-Path $service 'wrangler.s3.binding-probe.jsonc'
$probe = Join-Path $service 'scripts\staging-s3-remote-probe.ts'
$log = Join-Path $env:TEMP ('neko-s3-local-' + [guid]::NewGuid().ToString('N') + '.log')
$err = "$log.err"
$tokenBytes = [byte[]]::new(32)
[System.Security.Cryptography.RandomNumberGenerator]::Fill($tokenBytes)
$probeToken = [Convert]::ToBase64String($tokenBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
[Array]::Clear($tokenBytes)
$localProcess = $null
$before = $null
$deploymentAttempted = $false
$probeError = $null
$cleanupError = $null

function Require-Exit([string]$step) {
  if ($LASTEXITCODE -ne 0) { throw "$step failed (exit $LASTEXITCODE)" }
}
function Live-State {
  $deployments = & $wrangler deployments list --config $config --env staging --json | ConvertFrom-Json
  Require-Exit 'Deployment read'
  $latest = @($deployments) | Sort-Object created_on | Select-Object -Last 1
  if ($null -eq $latest -or @($latest.versions).Count -ne 1 -or $latest.versions[0].percentage -ne 100) {
    throw 'Deployment missing or split'
  }
  $id = [string]$latest.versions[0].version_id
  $version = & $wrangler versions view $id --config $config --env staging --json | ConvertFrom-Json
  Require-Exit 'Version read'
  return @{ Id = $id; Bindings = @($version.resources.bindings) }
}
function Require-Var([object[]]$bindings, [string]$name, [string]$value) {
  if (@($bindings | Where-Object { $_.name -eq $name -and $_.type -eq 'plain_text' -and $_.text -eq $value }).Count -ne 1) {
    throw "Unexpected gate or setting: $name"
  }
}
function Require-Off([object[]]$bindings) {
  Require-Var $bindings 'PRESERVATION_ENABLED' 'NO'
  Require-Var $bindings 'CLEANUP_ENABLED' 'NO'
  Require-Var $bindings 'RECOVERY_COPY_ENABLED' 'NO'
  Require-Var $bindings 'RECOVERY_S3_REGION' 'ap-northeast-1'
  Require-Var $bindings 'RECOVERY_S3_BUCKET' 'neko-preservation-staging-recovery-164892691568'
  Require-Var $bindings 'RECOVERY_S3_ACCOUNT_ID' '164892691568'
}

Set-Location -LiteralPath $service
$remoteConfigText = Get-Content -LiteralPath $config -Raw
$localConfigText = Get-Content -LiteralPath $localConfig -Raw
if ($remoteConfigText -notmatch '"workers_dev"\s*:\s*false' -or $remoteConfigText -notmatch '"preview_urls"\s*:\s*false' `
  -or $remoteConfigText -match '"routes"\s*:' -or $remoteConfigText -notmatch '"PRESERVATION_ENABLED"\s*:\s*"NO"' `
  -or $localConfigText -notmatch '"remote"\s*:\s*true') {
  throw 'Unsafe probe configuration'
}
$before = Live-State
Require-Off $before.Bindings
$names = & $wrangler secret list --config $config --env staging --format json | ConvertFrom-Json
Require-Exit 'Secret-name read'
foreach ($name in @('RECOVERY_S3_ACCESS_KEY_ID', 'RECOVERY_S3_SECRET_ACCESS_KEY')) {
  if (@($names | Where-Object name -eq $name).Count -ne 1) { throw "Missing private secret: $name" }
}

try {
  $localProcess = Start-Process -FilePath $node -ArgumentList @($wranglerJs, 'dev', '--config', $localConfig,
    '--ip', '127.0.0.1', '--port', '8798') -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $log -RedirectStandardError $err
  $ready = $false
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    try {
      $health = Invoke-WebRequest -Uri 'http://127.0.0.1:8798/' -TimeoutSec 2
      if ($health.StatusCode -eq 200) { $ready = $true; break }
    } catch { Start-Sleep -Seconds 1 }
  }
  if (-not $ready) { throw 'Local-only binding probe did not start' }

  $deploymentAttempted = $true
  $null = & $wrangler deploy $probe --config $config --env staging `
    --var "STAGING_S3_PROBE_TOKEN:$probeToken" `
    --message 'Temporary private synthetic S3 probe; auto restore'
  Require-Exit 'Temporary probe deployment'
  $during = Live-State
  Require-Off $during.Bindings
  Require-Var $during.Bindings 'STAGING_S3_PROBE_TOKEN' $probeToken
  if ($during.Id -eq $before.Id) { throw 'Probe version was not deployed' }

  $result = Invoke-WebRequest -Uri 'http://127.0.0.1:8798/run' -Method Post `
    -ContentType 'application/x-www-form-urlencoded' -Body @{ token = $probeToken } `
    -TimeoutSec 45 -SkipHttpErrorCheck
  if ($result.StatusCode -ne 200) { throw "Synthetic S3 round trip returned HTTP $($result.StatusCode): $($result.Content)" }
  $body = $result.Content | ConvertFrom-Json
  if ($body.result -ne 'S3_SYNTHETIC_ROUND_TRIP_PASS' -or -not $body.key -or -not $body.versionId) {
    throw 'Unexpected synthetic S3 result'
  }
  Write-Output "S3_SYNTHETIC_ROUND_TRIP_PASS key=$($body.key) version=$($body.versionId)"
} catch { $probeError = $_ }
finally {
  try {
    if ($deploymentAttempted) {
      $current = Live-State
      if ($current.Id -ne $before.Id) {
        Require-Off $current.Bindings
        Require-Var $current.Bindings 'STAGING_S3_PROBE_TOKEN' $probeToken
        $null = & $wrangler deploy --config $config --env staging `
          --message 'Restore disabled preservation Worker after synthetic S3 probe'
        Require-Exit 'Normal Worker restore'
      }
      $restored = Live-State
      Require-Off $restored.Bindings
      if (@($restored.Bindings | Where-Object name -eq 'STAGING_S3_PROBE_TOKEN').Count -ne 0) {
        throw 'Temporary probe token still deployed'
      }
    }
  } catch { $cleanupError = $_ }
  if ($null -ne $localProcess -and -not $localProcess.HasExited) { Stop-Process -Id $localProcess.Id -Force }
  foreach ($path in @($log, $err)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
  $probeToken = $null
}
if ($null -ne $cleanupError) { throw "INCIDENT: staging Worker restore unverified. $cleanupError" }
if ($null -ne $probeError) { throw "S3 private probe failed; normal entrypoint restored. $probeError" }
Write-Output 'Normal disabled Worker restored; temporary token absent; all preservation gates OFF.'
