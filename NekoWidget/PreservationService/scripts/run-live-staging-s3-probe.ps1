param([switch]$KmsOnly)
$ErrorActionPreference = 'Stop'
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
try {
  $null = & $aws iam create-user --user-name $userName --profile $profile --output json
  if ($LASTEXITCODE -ne 0) { throw 'IAM user creation failed' }
  $created = $true
  $null = & $aws iam put-user-policy --user-name $userName --policy-name SyntheticProbeOnly --policy-document file://scripts/aws-staging-probe-policy.json --profile $profile
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
  if (-not $KmsOnly) {
    & .\node_modules\.bin\vitest.cmd run --config vitest.live-staging.config.ts
    if ($LASTEXITCODE -ne 0) { throw 'Live staging app S3 test failed' }
    Write-Output 'APP_S3_LIVE_STAGING_PASS'
  }
  & .\node_modules\.bin\vitest.cmd run --config vitest.live-staging-kms.config.ts
  if ($LASTEXITCODE -ne 0) { throw 'Live staging app KMS test failed' }
  Write-Output 'APP_KMS_LIVE_STAGING_PASS'
} finally {
  foreach ($name in @('AWS_SECRET_ACCESS_KEY', 'AWS_ACCESS_KEY_ID',
      'NEKO_PROBE_AWS_SECRET_ACCESS_KEY', 'NEKO_PROBE_AWS_ACCESS_KEY_ID', 'NEKO_PROBE_AWS_REGION',
      'NEKO_PROBE_S3_BUCKET', 'NEKO_PROBE_AWS_ACCOUNT_ID', 'NEKO_PROBE_OWNER_ID', 'NEKO_PROBE_RECORD_ID')) {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
  }
  if ($accessKeyId) {
    $null = & $aws iam delete-access-key --user-name $userName --access-key-id $accessKeyId --profile $profile
    Write-Output "TEMP_ACCESS_KEY_DELETE_EXIT=$LASTEXITCODE"
  }
  if ($created) {
    $null = & $aws iam delete-user-policy --user-name $userName --policy-name SyntheticProbeOnly --profile $profile
    Write-Output "TEMP_POLICY_DELETE_EXIT=$LASTEXITCODE"
    $null = & $aws iam delete-user --user-name $userName --profile $profile
    Write-Output "TEMP_USER_DELETE_EXIT=$LASTEXITCODE"
  }
  $versionJson = & $aws s3api list-object-versions --bucket $bucket --prefix $objectKey --profile $profile --output json
  if ($LASTEXITCODE -eq 0) {
    $listing = $versionJson | ConvertFrom-Json
    foreach ($version in @($listing.Versions) + @($listing.DeleteMarkers)) {
      if ($null -ne $version -and $version.Key -eq $objectKey) {
        $null = & $aws s3api delete-object --bucket $bucket --key $objectKey --version-id $version.VersionId --profile $profile
        Write-Output "SYNTHETIC_VERSION_DELETE_EXIT=$LASTEXITCODE"
      }
    }
  }
  $env:AWS_DEFAULT_REGION = $priorRegion
}
