#!/usr/bin/env bash
set -euo pipefail
umask 077

cd "$(dirname "$0")"
project_dir="$PWD"
[[ "${RUNNER_TEMP:?}" == /* && "$RUNNER_TEMP" != / ]]
runner_temp="$(cd "$RUNNER_TEMP" && pwd -P)"
release_dir="$runner_temp/pet-identity-testflight"
owner="${GITHUB_RUN_ID:?}:${GITHUB_RUN_ATTEMPT:?}:${GITHUB_SHA:?}"

cleanup() {
  python3 "$project_dir/verify-release.py" cleanup --work-dir "$release_dir"
}

if [[ "${1:-}" == cleanup ]]; then
  cleanup
  exit
fi

[[ "${GITHUB_REF:-}" == refs/heads/main ]]
[[ "${GITHUB_EVENT_NAME:-}" == workflow_dispatch ]]
[[ "${GITHUB_SHA:-}" =~ ^[a-f0-9]{40}$ ]]
[[ "$(git rev-parse HEAD)" == "$GITHUB_SHA" ]]
[[ "${RELEASE_BUILD_NUMBER:-}" =~ ^[1-9][0-9]{0,8}$ ]]
[[ "${DEVELOPER_DIR:-}" == /Applications/Xcode_26.3.app/Contents/Developer ]]
[[ -d "$DEVELOPER_DIR" ]]

private_stage() {
  local stage="$1"
  shift
  if "$@" > "$release_dir/$stage.log" 2>&1; then
    printf 'PetIdentityProbe: %s passed.\n' "$stage"
  else
    local result=$?
    printf 'PetIdentityProbe: %s failed (exit %s).\n' "$stage" "$result" >&2
    python3 "$project_dir/verify-release.py" diagnose --work-dir "$release_dir" \
      --diagnostic-stage "$stage" || true
    return "$result"
  fi
}

case "${1:-}" in
  prepare)
    # mkdir is exclusive: an unrelated existing directory is never reused.
    mkdir "$release_dir"
    printf '%s' "$owner" > "$release_dir/owner"
    private_stage xcode-version xcodebuild -version
    private_stage model-download python3 prepare.py
    private_stage python-dependencies python3 -m pip install \
      --disable-pip-version-check --no-cache-dir -r requirements.txt
    private_stage fixed-model python3 fix-model.py Resources/model.onnx Resources/model-fixed.onnx
    private_stage app-icon swift make-icon.swift
    private_stage notices python3 prepare-notices.py
    if ! command -v xcodegen >/dev/null; then
      private_stage xcodegen-install brew install xcodegen
    fi
    private_stage project-generation xcodegen generate
    printf '%s' "$GITHUB_SHA" > "$release_dir/prepared-source"
    ;;
  upload)
    [[ -d "$release_dir" && ! -L "$release_dir" ]]
    [[ "$(cat "$release_dir/owner")" == "$owner" ]]
    [[ "$(cat "$release_dir/prepared-source")" == "$GITHUB_SHA" ]]
    trap cleanup EXIT
    for variable in APPLE_TEAM_ID APPLE_DISTRIBUTION_CERTIFICATE_BASE64 \
      APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD KEYCHAIN_PASSWORD \
      PET_IDENTITY_PROVISIONING_PROFILE_BASE64 APP_STORE_CONNECT_KEY_ID \
      APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_PRIVATE_KEY_BASE64; do
      [[ -n "${!variable:-}" ]] || { printf 'Missing required signing configuration.\n' >&2; exit 1; }
    done
    [[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]
    [[ "$APP_STORE_CONNECT_KEY_ID" =~ ^[A-Z0-9]{10}$ ]]
    [[ "$APP_STORE_CONNECT_ISSUER_ID" =~ ^[a-fA-F0-9-]{36}$ ]]
    [[ "${PET_IDENTITY_APP_RECORD_ID:-}" =~ ^[0-9]{8,12}$ ]]
    keychain="$release_dir/probe-signing.keychain-db"
    mkdir "$release_dir/private_keys"
    api_key="$release_dir/private_keys/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
    printf '%s' "$APPLE_DISTRIBUTION_CERTIFICATE_BASE64" | base64 -D > "$release_dir/distribution.p12"
    printf '%s' "$PET_IDENTITY_PROVISIONING_PROFILE_BASE64" | base64 -D > "$release_dir/probe.mobileprovision"
    printf '%s' "$APP_STORE_CONNECT_PRIVATE_KEY_BASE64" | base64 -D > "$api_key"
    unset APPLE_DISTRIBUTION_CERTIFICATE_BASE64 PET_IDENTITY_PROVISIONING_PROFILE_BASE64 \
      APP_STORE_CONNECT_PRIVATE_KEY_BASE64
    private_stage api-key openssl pkey -in "$api_key" -noout
    private_stage app-record python3 verify-release.py app-record \
      --work-dir "$release_dir" --app-record-id "$PET_IDENTITY_APP_RECORD_ID"
    private_stage keychain-create security create-keychain -p "$KEYCHAIN_PASSWORD" "$keychain"
    private_stage keychain-settings security set-keychain-settings -lut 21600 "$keychain"
    private_stage keychain-unlock security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$keychain"
    private_stage certificate-import security import "$release_dir/distribution.p12" \
      -P "$APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD" -t cert -f pkcs12 -k "$keychain" \
      -T /usr/bin/codesign -T /usr/bin/security
    private_stage keychain-partition security set-key-partition-list \
      -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$keychain"
    unset APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD KEYCHAIN_PASSWORD
    private_stage signing-preflight python3 verify-release.py signing \
      --work-dir "$release_dir" --team "$APPLE_TEAM_ID"
    profile_uuid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["profile_uuid"])' "$release_dir/signing.json")"
    certificate_sha1="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["certificate_sha1"])' "$release_dir/signing.json")"
    private_stage archive xcodebuild -project PetIdentityProbe.xcodeproj \
      -scheme PetIdentityProbe -configuration Release -destination 'generic/platform=iOS' \
      -derivedDataPath "$release_dir/DerivedData" -archivePath "$release_dir/PetIdentityProbe.xcarchive" \
      PROBE_SIGNING_ALLOWED=YES PROBE_TEAM_ID="$APPLE_TEAM_ID" \
      PROBE_SIGN_IDENTITY="$certificate_sha1" PROBE_PROFILE_UUID="$profile_uuid" \
      PROBE_BUILD_NUMBER="$RELEASE_BUILD_NUMBER" \
      "PROBE_CODE_SIGN_FLAGS=--keychain $keychain" archive
    private_stage archive-verification python3 verify-release.py app \
      --work-dir "$release_dir" --team "$APPLE_TEAM_ID" --build "$RELEASE_BUILD_NUMBER" \
      --app "$release_dir/PetIdentityProbe.xcarchive/Products/Applications/PetIdentityProbe.app"
    private_stage export xcodebuild -exportArchive \
      -archivePath "$release_dir/PetIdentityProbe.xcarchive" -exportPath "$release_dir/Export" \
      -exportOptionsPlist "$release_dir/ExportOptions.plist"
    private_stage ipa-verification python3 verify-release.py ipa \
      --work-dir "$release_dir" --team "$APPLE_TEAM_ID" --build "$RELEASE_BUILD_NUMBER"
    ipa_path="$release_dir/Export/PetIdentityProbe.ipa"
    [[ -f "$ipa_path" ]]
    # altool searches ./private_keys, so the API key stays under RUNNER_TEMP.
    cd "$release_dir"
    for stage in validate upload; do
      python3 "$project_dir/verify-release.py" payload --work-dir "$release_dir"
      private_stage "altool-$stage" xcrun altool "--${stage}-app" \
        -f "$ipa_path" -t ios --apiKey "$APP_STORE_CONNECT_KEY_ID" \
        --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID"
      python3 "$project_dir/verify-release.py" altool \
        --work-dir "$release_dir" --stage "$stage"
    done
    python3 "$project_dir/verify-release.py" summary --work-dir "$release_dir" \
      --build "$RELEASE_BUILD_NUMBER"
    ;;
  *)
    printf 'Usage: release.sh prepare|upload|cleanup\n' >&2
    exit 2
    ;;
esac
