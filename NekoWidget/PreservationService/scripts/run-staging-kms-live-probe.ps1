# Short, synthetic-only test of the deployed private KMS service binding.
# The local probe must already be running on 127.0.0.1:8799. This script
# deactivates the IAM key and deploys the KMS gate OFF independently in finally.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$service = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$aws = Join-Path $env:LOCALAPPDATA 'Programs\Amazon\AWSCLIV2\aws.exe'
$wrangler = Join-Path $service 'node_modules\.bin\wrangler.cmd'
$kmsConfig = Join-Path $service 'wrangler.kms.staging.jsonc'
$publicConfig = Join-Path $service 'wrangler.jsonc'
$region = 'ap-northeast-1'
$account = '164892691568'
$user = 'neko-preservation-staging-kms-worker'
$keyArn = 'arn:aws:kms:ap-northeast-1:164892691568:key/339319dc-388b-4bd7-adb8-29d37d836d72'
$profile = 'neko-preservation-test'

function Require-Exit([string]$step) {
  if ($LASTEXITCODE -ne 0) { throw "$step failed (exit $LASTEXITCODE)" }
}
function Aws-Json([string[]]$arguments) {
  $response = & $aws @arguments --profile $profile --region $region --output json
  Require-Exit 'AWS read'
  return $response | ConvertFrom-Json
}
function Version-Bindings([string]$config, [string[]]$extra) {
  $deployments = & $wrangler deployments list --config $config @extra --json | ConvertFrom-Json
  Require-Exit 'Cloudflare deployment read'
  if (@($deployments).Count -lt 1) { throw 'Worker deployment missing' }
  $latest = @($deployments) | Sort-Object created_on | Select-Object -Last 1
  if (@($latest.versions).Count -ne 1 -or $latest.versions[0].percentage -ne 100) {
    throw 'Worker traffic split'
  }
  $version = & $wrangler versions view $latest.versions[0].version_id --config $config @extra --json | ConvertFrom-Json
  Require-Exit 'Cloudflare version read'
  return @($version.resources.bindings)
}
function Require-Gate([object[]]$bindings, [string]$name, [string]$expected) {
  $found = @($bindings | Where-Object {
    $_.name -eq $name -and $_.type -eq 'plain_text' -and $_.text -eq $expected
  })
  if ($found.Count -ne 1) { throw "Unexpected remote gate: $name" }
}

Set-Location -LiteralPath $service
$listeners = @(Get-NetTCPConnection -LocalPort 8799 -State Listen -ErrorAction Stop)
if ($listeners.Count -ne 1 -or $listeners[0].LocalAddress -ne '127.0.0.1') {
  throw 'Dedicated loopback probe listener missing'
}
$runtime = Get-CimInstance Win32_Process -Filter "ProcessId=$($listeners[0].OwningProcess)"
$launcher = Get-CimInstance Win32_Process -Filter "ProcessId=$($runtime.ParentProcessId)"
if ($runtime.Name -ne 'workerd.exe' -or !$runtime.ExecutablePath.StartsWith($service) `
  -or $launcher.Name -ne 'node.exe' `
  -or !$launcher.CommandLine.Contains((Join-Path $service 'node_modules\wrangler\wrangler-dist\cli.js')) `
  -or !$launcher.CommandLine.Contains('dev --config wrangler.kms.binding-probe.jsonc --ip 127.0.0.1 --port 8799')) {
  throw 'Port 8799 is not the dedicated local probe'
}
$caller = Aws-Json @('sts', 'get-caller-identity')
if ($caller.Account -ne $account) { throw 'Unexpected AWS account' }
$access = Aws-Json @('iam', 'list-access-keys', '--user-name', $user)
if (@($access.AccessKeyMetadata).Count -ne 1 -or $access.AccessKeyMetadata[0].Status -ne 'Inactive') {
  throw 'IAM key is not uniquely Inactive'
}
$accessId = $access.AccessKeyMetadata[0].AccessKeyId
$local = Get-Content -LiteralPath $kmsConfig -Raw
if ($local -notmatch '"workers_dev"\s*:\s*false' -or $local -match '"routes"\s*:' -or $local -notmatch '"PRESERVATION_KMS_ENABLED"\s*:\s*"NO"') {
  throw 'Unsafe local KMS config'
}
$kmsBindings = Version-Bindings $kmsConfig @()
Require-Gate $kmsBindings 'PRESERVATION_KMS_ENABLED' 'NO'
Require-Gate $kmsBindings 'KMS_KEY_ARN' $keyArn
$publicBindings = Version-Bindings $publicConfig @('--env', 'staging')
Require-Gate $publicBindings 'PRESERVATION_ENABLED' 'NO'
Require-Gate $publicBindings 'CLEANUP_ENABLED' 'NO'
& node (Join-Path $PSScriptRoot 'check-staging-kms-binding.mjs') --expect-off
Require-Exit 'OFF binding probe'

$probeError = $null
$cleanupErrors = @()
$freshProbe = $null
$freshLauncherCreated = $null
$freshRuntimePid = $null
$freshRuntimeCreated = $null
try {
  & $wrangler deploy --config $kmsConfig `
    --var 'PRESERVATION_KMS_ENABLED:YES' `
    --var "KMS_REGION:$region" --var "KMS_KEY_ARN:$keyArn" `
    --message 'Temporary private synthetic KMS probe; return OFF immediately'
  Require-Exit 'Temporary private KMS deploy'
  $kmsBindings = Version-Bindings $kmsConfig @()
  Require-Gate $kmsBindings 'PRESERVATION_KMS_ENABLED' 'YES'
  Require-Gate $kmsBindings 'KMS_KEY_ARN' $keyArn
  $secretNames = & $wrangler secret list --config $kmsConfig --format json | ConvertFrom-Json
  Require-Exit 'KMS secret list'
  foreach ($required in @('KEY_WRAPPER_CALLER_SECRET', 'KMS_ACCESS_KEY_ID', 'KMS_SECRET_ACCESS_KEY')) {
    if (@($secretNames | Where-Object name -eq $required).Count -ne 1) {
      throw "KMS secret missing: $required"
    }
  }
  & $aws iam update-access-key --user-name $user --access-key-id $accessId `
    --status Active --profile $profile --region $region
  Require-Exit 'Temporary IAM key activation'
  # Remote service bindings may hold a target snapshot from dev startup.
  # Start a fresh local-only probe after the YES deployment, on a second port.
  if (@(Get-NetTCPConnection -LocalPort 8800 -State Listen -ErrorAction SilentlyContinue).Count) {
    throw 'Fresh local probe port already occupied'
  }
  # Invoke the CLI directly: bin/wrangler.js launches another node process,
  # so Start-Process's PID would not own the workerd listener.
  $probeScript = Join-Path $service 'node_modules\wrangler\wrangler-dist\cli.js'
  $freshProbe = Start-Process -FilePath (Get-Command node).Source `
    -ArgumentList @($probeScript, 'dev', '--config', 'wrangler.kms.binding-probe.jsonc',
      '--ip', '127.0.0.1', '--port', '8800') -WorkingDirectory $service `
    -WindowStyle Hidden -PassThru
  $freshLauncherCreated = (Get-CimInstance Win32_Process -Filter "ProcessId=$($freshProbe.Id)").CreationDate
  $ready = $false
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    Start-Sleep -Milliseconds 500
    $newListener = @(Get-NetTCPConnection -LocalPort 8800 -State Listen -ErrorAction SilentlyContinue)
    if ($newListener.Count -eq 1 -and $newListener[0].LocalAddress -eq '127.0.0.1') {
      $newRuntime = Get-CimInstance Win32_Process -Filter "ProcessId=$($newListener[0].OwningProcess)"
      $newLauncher = Get-CimInstance Win32_Process -Filter "ProcessId=$($newRuntime.ParentProcessId)"
      if ($newRuntime.Name -eq 'workerd.exe' -and $newRuntime.ExecutablePath.StartsWith($service) `
        -and $newLauncher.ProcessId -eq $freshProbe.Id `
        -and $newLauncher.CreationDate -eq $freshLauncherCreated `
        -and $newLauncher.CommandLine.Contains('wrangler.kms.binding-probe.jsonc') `
        -and $newLauncher.CommandLine.Contains('--port 8800')) {
        $freshRuntimePid = $newRuntime.ProcessId
        $freshRuntimeCreated = $newRuntime.CreationDate
        $ready = $true
        break
      }
      throw 'Fresh probe port has unexpected owner'
    }
  }
  if (!$ready) { throw 'Fresh local probe did not start' }
  $env:NEKO_KMS_PROBE_PORT = '8800'
  & node (Join-Path $PSScriptRoot 'check-staging-kms-binding.mjs') --expect-on
  Require-Exit 'Synthetic KMS binding probe'
} catch { $probeError = $_ }
finally {
  Remove-Item Env:NEKO_KMS_PROBE_PORT -ErrorAction SilentlyContinue
  if ($null -ne $freshProbe) {
    try {
      $currentLauncher = Get-CimInstance Win32_Process -Filter "ProcessId=$($freshProbe.Id)"
      if ($null -ne $currentLauncher) {
        if ($currentLauncher.CreationDate -ne $freshLauncherCreated `
          -or !$currentLauncher.CommandLine.Contains('wrangler.kms.binding-probe.jsonc') `
          -or !$currentLauncher.CommandLine.Contains('--port 8800')) {
          throw 'Fresh probe launcher identity changed'
        }
        Stop-Process -Id $freshProbe.Id -Force
      }
      $newListener = @(Get-NetTCPConnection -LocalPort 8800 -State Listen -ErrorAction SilentlyContinue)
      if ($newListener.Count) {
        $newRuntime = Get-CimInstance Win32_Process -Filter "ProcessId=$($newListener[0].OwningProcess)"
        if ($newListener.Count -ne 1 -or $newRuntime.ProcessId -ne $freshRuntimePid `
          -or $newRuntime.CreationDate -ne $freshRuntimeCreated `
          -or $newRuntime.ParentProcessId -ne $freshProbe.Id `
          -or $newRuntime.Name -ne 'workerd.exe' `
          -or !$newRuntime.ExecutablePath.StartsWith($service)) {
          throw 'Fresh probe cannot be stopped safely'
        }
        Stop-Process -Id $newRuntime.ProcessId -Force
      }
    } catch { $cleanupErrors += "Fresh probe shutdown: $($_.Exception.Message)" }
  }
  try {
    & $aws iam update-access-key --user-name $user --access-key-id $accessId `
      --status Inactive --profile $profile --region $region
    Require-Exit 'IAM key deactivation'
  } catch { $cleanupErrors += "IAM key deactivation: $($_.Exception.Message)" }
  try {
    & $wrangler deploy --config $kmsConfig `
      --message 'Restore private KMS gate OFF after synthetic probe'
    Require-Exit 'KMS OFF deployment'
  } catch { $cleanupErrors += "KMS gate OFF deploy: $($_.Exception.Message)" }
  try {
    $after = Aws-Json @('iam', 'list-access-keys', '--user-name', $user)
    if (@($after.AccessKeyMetadata).Count -ne 1 -or $after.AccessKeyMetadata[0].Status -ne 'Inactive') {
      throw 'IAM key remains active'
    }
  } catch { $cleanupErrors += "IAM key read-back: $($_.Exception.Message)" }
  try {
    $afterBindings = Version-Bindings $kmsConfig @()
    Require-Gate $afterBindings 'PRESERVATION_KMS_ENABLED' 'NO'
    $publicBindings = Version-Bindings $publicConfig @('--env', 'staging')
    Require-Gate $publicBindings 'PRESERVATION_ENABLED' 'NO'
    Require-Gate $publicBindings 'CLEANUP_ENABLED' 'NO'
    & node (Join-Path $PSScriptRoot 'check-staging-kms-binding.mjs') --expect-off
    Require-Exit 'Post-probe OFF binding probe'
  } catch { $cleanupErrors += "Remote OFF read-back: $($_.Exception.Message)" }
}
if ($cleanupErrors.Count -gt 0) {
  throw "INCIDENT: probe cleanup unverified. $($cleanupErrors -join '; ')"
}
if ($null -ne $probeError) { throw "Synthetic probe failed; both gates verified OFF. $probeError" }
Write-Output 'Synthetic KMS binding probe passed; IAM key Inactive and private/public gates OFF.'
