param([switch]$KmsOnly, [switch]$FlowOnly, [switch]$PurgeOnly, [switch]$PlanOnly)
$ErrorActionPreference = 'Stop'
$chosenModes = @($KmsOnly, $FlowOnly, $PurgeOnly, $PlanOnly) | Where-Object { $_ }
if (@($chosenModes).Count -gt 1) {
  throw 'Choose only one probe mode'
}
$aws = "$env:LOCALAPPDATA\Programs\Amazon\AWSCLIV2\aws.exe"
$profile = 'neko-preservation-test'
$bucket = 'neko-preservation-staging-recovery-164892691568'
$userName = 'neko-preservation-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 10)
$ownerId = [guid]::NewGuid().ToString()
$recordId = [guid]::NewGuid().ToString()
$objectKey = "recovery/v1/$ownerId/photo/$recordId"
$created = $false
$accessKeyId = $null
$priorRegion = $env:AWS_DEFAULT_REGION
$env:AWS_DEFAULT_REGION = 'ap-northeast-1'
function Invoke-AwsCleanup([string[]]$Arguments) {
  try {
    $response = & $aws @Arguments 2>$null
    return @{ Succeeded = ($LASTEXITCODE -eq 0); Text = ($response -join "`n") }
  } catch {
    return @{ Succeeded = $false; Text = '' }
  }
}
try {
  $null = & $aws iam create-user --user-name $userName --profile $profile --output json
  if ($LASTEXITCODE -ne 0) { throw 'IAM user creation failed' }
  $created = $true
  if ($PlanOnly) {
    $planPrefix = "purge-plan/v1/$ownerId/$recordId/"
    $policyDocument = @{
      Version = '2012-10-17'
      Statement = @(
        @{
          Sid = 'OnlySyntheticPlanObjects'
          Effect = 'Allow'
          Action = @('s3:PutObject', 's3:GetObject', 's3:GetObjectVersion')
          Resource = "arn:aws:s3:::$bucket/$planPrefix*"
        },
        @{
          Sid = 'OnlySyntheticPlanInventory'
          Effect = 'Allow'
          Action = 's3:ListBucketVersions'
          Resource = "arn:aws:s3:::$bucket"
          Condition = @{ StringLike = @{ 's3:prefix' = "$planPrefix*" } }
        }
      )
    } | ConvertTo-Json -Depth 8 -Compress
    $null = & $aws iam put-user-policy --user-name $userName --policy-name SyntheticProbeOnly --policy-document $policyDocument --profile $profile
  } elseif ($PurgeOnly) {
    # The destructive probe can touch only this invocation's random object.
    $policyDocument = @{
      Version = '2012-10-17'
      Statement = @(
        @{
          Sid = 'OnlyThisSyntheticVersion'
          Effect = 'Allow'
          Action = @('s3:PutObject', 's3:GetObject', 's3:GetObjectVersion',
            's3:DeleteObject', 's3:DeleteObjectVersion')
          Resource = "arn:aws:s3:::$bucket/$objectKey"
        },
        @{
          Sid = 'OnlyThisSyntheticOwnerInventory'
          Effect = 'Allow'
          Action = 's3:ListBucketVersions'
          Resource = "arn:aws:s3:::$bucket"
          Condition = @{ StringLike = @{ 's3:prefix' = "recovery/v1/$ownerId/*" } }
        }
      )
    } | ConvertTo-Json -Depth 8 -Compress
    $null = & $aws iam put-user-policy --user-name $userName --policy-name SyntheticProbeOnly --policy-document $policyDocument --profile $profile
  } else {
    $null = & $aws iam put-user-policy --user-name $userName --policy-name SyntheticProbeOnly --policy-document file://scripts/aws-staging-probe-policy.json --profile $profile
  }
  if ($LASTEXITCODE -ne 0) { throw 'IAM policy creation failed' }
  $credentialJson = & $aws iam create-access-key --user-name $userName --profile $profile --output json
  if ($LASTEXITCODE -ne 0) { throw 'IAM access key creation failed' }
  $credential = $credentialJson | ConvertFrom-Json
  $accessKeyId = $credential.AccessKey.AccessKeyId
  $env:NEKO_PROBE_AWS_REGION = 'ap-northeast-1'
  $env:NEKO_PROBE_S3_BUCKET = $bucket
  $env:NEKO_PROBE_AWS_ACCOUNT_ID = '164892691568'
  $env:NEKO_PROBE_OWNER_ID = $ownerId
  $env:NEKO_PROBE_RECORD_ID = $recordId
  $env:NEKO_PROBE_AWS_ACCESS_KEY_ID = $accessKeyId
  $env:NEKO_PROBE_AWS_SECRET_ACCESS_KEY = $credential.AccessKey.SecretAccessKey
  $env:AWS_ACCESS_KEY_ID = $accessKeyId
  $env:AWS_SECRET_ACCESS_KEY = $credential.AccessKey.SecretAccessKey
  $credential = $null
  $propagated = $false
  for ($attempt = 0; $attempt -lt 8; $attempt++) {
    if ($attempt -gt 0) { Start-Sleep -Seconds 3 }
    $identityJson = & $aws sts get-caller-identity --output json 2>$null
    if ($LASTEXITCODE -eq 0) {
      $identity = $identityJson | ConvertFrom-Json
      if ($identity.Arn -eq "arn:aws:iam::164892691568:user/$userName") {
        $propagated = $true
        break
      }
    }
  }
  if (-not $propagated) { throw 'Temporary IAM key did not propagate' }
  Write-Output 'TEMP_IAM_KEY_READY'
  if ($PlanOnly) {
    & .\node_modules\.bin\vitest.cmd run --config vitest.live-staging-plan.config.ts
    if ($LASTEXITCODE -ne 0) { throw 'Live staging S3 purge plan test failed' }
    Write-Output 'APP_S3_PURGE_PLAN_LIVE_STAGING_PASS'
  } elseif ($PurgeOnly) {
    & .\node_modules\.bin\vitest.cmd run --config vitest.live-staging-purge.config.ts
    if ($LASTEXITCODE -ne 0) { throw 'Live staging exact-version purge test failed' }
    Write-Output 'APP_S3_VERSION_PURGE_LIVE_STAGING_PASS'
  } elseif (-not $KmsOnly -and -not $FlowOnly) {
    & .\node_modules\.bin\vitest.cmd run --config vitest.live-staging.config.ts
    if ($LASTEXITCODE -ne 0) { throw 'Live staging app S3 test failed' }
    Write-Output 'APP_S3_LIVE_STAGING_PASS'
  }
  if ($PlanOnly -or $PurgeOnly) {
    # The exact-version probe has no KMS or full-flow dependency.
  } elseif (-not $FlowOnly) {
    & .\node_modules\.bin\vitest.cmd run --config vitest.live-staging-kms.config.ts
    if ($LASTEXITCODE -ne 0) { throw 'Live staging app KMS test failed' }
    Write-Output 'APP_KMS_LIVE_STAGING_PASS'
  } else {
    & .\node_modules\.bin\vitest.cmd run --config vitest.live-staging-flow.config.ts
    if ($LASTEXITCODE -ne 0) { throw 'Live staging flow test failed' }
    Write-Output 'APP_FLOW_LIVE_STAGING_PASS'
  }
} finally {
  $cleanupFailures = @()
  foreach ($name in @('AWS_SECRET_ACCESS_KEY', 'AWS_ACCESS_KEY_ID',
      'NEKO_PROBE_AWS_SECRET_ACCESS_KEY', 'NEKO_PROBE_AWS_ACCESS_KEY_ID', 'NEKO_PROBE_AWS_REGION',
      'NEKO_PROBE_S3_BUCKET', 'NEKO_PROBE_AWS_ACCOUNT_ID', 'NEKO_PROBE_OWNER_ID', 'NEKO_PROBE_RECORD_ID')) {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
  }
  if ($accessKeyId) {
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
      $deleted = Invoke-AwsCleanup -Arguments @('iam', 'delete-access-key', '--user-name',
        $userName, '--access-key-id', $accessKeyId, '--profile', $profile)
      if ($deleted.Succeeded) { break }
      Start-Sleep -Seconds 2
    }
    $keys = Invoke-AwsCleanup -Arguments @('iam', 'list-access-keys', '--user-name',
      $userName, '--profile', $profile, '--output', 'json')
    $keyAbsent = $false
    if ($keys.Succeeded) {
      try {
        $metadata = (ConvertFrom-Json -InputObject $keys.Text).AccessKeyMetadata
        $keyAbsent = @($metadata | Where-Object { $_.AccessKeyId -eq $accessKeyId }).Count -eq 0
      } catch { $keyAbsent = $false }
    }
    if (-not $keyAbsent) {
      $cleanupFailures += "temporary IAM access key remains for $userName"
    } else {
      Write-Output 'TEMP_ACCESS_KEY_REMOVED'
    }
  }
  if ($created) {
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
      $deleted = Invoke-AwsCleanup -Arguments @('iam', 'delete-user-policy', '--user-name',
        $userName, '--policy-name', 'SyntheticProbeOnly', '--profile', $profile)
      if ($deleted.Succeeded) { break }
      Start-Sleep -Seconds 2
    }
    $policies = Invoke-AwsCleanup -Arguments @('iam', 'list-user-policies', '--user-name',
      $userName, '--profile', $profile, '--output', 'json')
    $policyAbsent = $false
    if ($policies.Succeeded) {
      try {
        $names = (ConvertFrom-Json -InputObject $policies.Text).PolicyNames
        $policyAbsent = @($names | Where-Object { $_ -eq 'SyntheticProbeOnly' }).Count -eq 0
      } catch { $policyAbsent = $false }
    }
    if (-not $policyAbsent) {
      $cleanupFailures += "temporary IAM policy remains for $userName"
    } else {
      Write-Output 'TEMP_POLICY_REMOVED'
    }
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
      $deleted = Invoke-AwsCleanup -Arguments @('iam', 'delete-user', '--user-name',
        $userName, '--profile', $profile)
      if ($deleted.Succeeded) { break }
      Start-Sleep -Seconds 2
    }
    $users = Invoke-AwsCleanup -Arguments @('iam', 'list-users', '--profile', $profile,
      '--output', 'json')
    $userAbsent = $false
    if ($users.Succeeded) {
      try {
        $listed = (ConvertFrom-Json -InputObject $users.Text).Users
        $userAbsent = @($listed | Where-Object { $_.UserName -eq $userName }).Count -eq 0
      } catch { $userAbsent = $false }
    }
    if (-not $userAbsent) {
      $cleanupFailures += "temporary IAM user remains: $userName"
    } else {
      Write-Output 'TEMP_USER_REMOVED'
    }
  }
  $cleanupPrefix = if ($PlanOnly) { "purge-plan/v1/$ownerId/$recordId/" }
    elseif ($FlowOnly) { "recovery/v1/$ownerId/" } else { $objectKey }
  $listingResult = Invoke-AwsCleanup -Arguments @('s3api', 'list-object-versions', '--bucket',
    $bucket, '--prefix', $cleanupPrefix, '--profile', $profile, '--output', 'json')
  if ($listingResult.Succeeded) {
    try {
      $listing = ConvertFrom-Json -InputObject $listingResult.Text
      foreach ($version in @($listing.Versions) + @($listing.DeleteMarkers)) {
        if ($null -ne $version -and $version.Key.StartsWith($cleanupPrefix, [System.StringComparison]::Ordinal)) {
          $deleted = Invoke-AwsCleanup -Arguments @('s3api', 'delete-object', '--bucket',
            $bucket, '--key', $version.Key, '--version-id', $version.VersionId, '--profile', $profile)
          if (-not $deleted.Succeeded) { $cleanupFailures += "synthetic version remains under $cleanupPrefix" }
        }
      }
    } catch { $cleanupFailures += "synthetic version listing unreadable under $cleanupPrefix" }
  } else {
    $cleanupFailures += "synthetic version listing failed under $cleanupPrefix"
  }
  if ($PurgeOnly -or $PlanOnly) {
    $remainingResult = Invoke-AwsCleanup -Arguments @('s3api', 'list-object-versions',
      '--bucket', $bucket, '--prefix', $cleanupPrefix, '--profile', $profile, '--output', 'json')
    if (-not $remainingResult.Succeeded) {
      $cleanupFailures += "synthetic purge cleanup verification failed for $cleanupPrefix"
    } else {
      try {
        $remaining = ConvertFrom-Json -InputObject $remainingResult.Text
        $versions = @($remaining.Versions | Where-Object { $null -ne $_ })
        $markers = @($remaining.DeleteMarkers | Where-Object { $null -ne $_ })
        if ($versions.Count -gt 0 -or $markers.Count -gt 0) {
          $cleanupFailures += "synthetic purge versions remain under $cleanupPrefix"
        }
      } catch { $cleanupFailures += "synthetic purge listing unreadable under $cleanupPrefix" }
    }
    if ($cleanupFailures.Count -eq 0) { Write-Output 'SYNTHETIC_PURGE_PREFIX_EMPTY' }
  }
  $env:AWS_DEFAULT_REGION = $priorRegion
  if ($cleanupFailures.Count -gt 0) { throw ($cleanupFailures -join '; ') }
}
