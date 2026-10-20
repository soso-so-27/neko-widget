#!/usr/bin/env bash
# Cheap privacy, saved-data, and sharing checks. No simulator or evidence ledger.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 ci/test-disabled-release-config.py
python3 ci/test-disabled-release-build-settings.py
python3 ci/test-pairing-only-release-config.py
python3 ci/test-media-staging-release-config.py
python3 ci/test-validate-sharing-release.py
python3 ci/test-signed-artifact-authentication.py
python3 ci/test-validate-sharing-runtime-self-test.py
python3 ci/test-public-policy-site.py
python3 ci/test-limited-external-beta-reporting.py
python3 ci/test-app-store-local-only-readiness.py
python3 ci/test-export-temp-file-lifecycle.py
python3 ci/test-photo-permission-bootstrap.py
python3 ci/test-simulator-smoke-personal-state.py
python3 ci/test-diagnostic-log-privacy.py
python3 ci/test-app-store-screenshot-workflow.py
python3 ci/test-runtime-preparation.py
python3 ci/test-background-moment-refresh.py

xcrun --sdk macosx swiftc \
  -parse-as-library \
  Shared/Models/AppSettings.swift \
  Shared/Models/NormalizedRect.swift \
  Shared/Models/CatCandidateCuration.swift \
  Shared/Models/CatHouseholdIdentity.swift \
  Shared/Models/CatProfileTransfer.swift \
  Shared/Models/NekoWidgetError.swift \
  Shared/Models/WidgetRenderPlan.swift \
  Shared/Models/WidgetManifest.swift \
  Shared/Storage/AtomicJSON.swift \
  Shared/AppGroup/SharedContainer.swift \
  NekoWidget/Services/CatHouseholdIdentityStore.swift \
  ci/verify-cat-household-identity.swift \
  -o "$RUNNER_TEMP/verify-cat-household-identity"
"$RUNNER_TEMP/verify-cat-household-identity"

xcrun swiftc -parse-as-library \
  NekoWidget/Services/PhotoMemoryNoteStore.swift \
  ci/verify-photo-memory-notes.swift \
  -o "$RUNNER_TEMP/verify-photo-memory-notes"
"$RUNNER_TEMP/verify-photo-memory-notes"
xcrun swiftc -parse-as-library \
  NekoWidget/Services/PhotoMemoryNoteStore.swift \
  NekoWidget/Services/VeterinaryVisitStore.swift \
  ci/verify-veterinary-visits.swift -o "$RUNNER_TEMP/verify-veterinary-visits"
"$RUNNER_TEMP/verify-veterinary-visits"

xcrun swiftc -parse-as-library Shared/MembershipAccessPolicy.swift \
  ci/verify-membership-access.swift -o "$RUNNER_TEMP/verify-membership-access"
"$RUNNER_TEMP/verify-membership-access"

xcrun swiftc \
  -parse-as-library \
  Shared/Sharing/PairingCore.swift \
  Shared/Models/WidgetManifest.swift \
  Shared/Models/WidgetRenderPlan.swift \
  Shared/Sharing/DailySharingCore.swift \
  ci/verify-sharing-protocol-vectors.swift \
  -o "$RUNNER_TEMP/verify-sharing-protocol-vectors"
"$RUNNER_TEMP/verify-sharing-protocol-vectors" \
  ci/fixtures/sharing-protocol-v1.json

xcrun swiftc \
  -parse-as-library \
  Shared/Sharing/PairingCore.swift \
  Shared/Models/WidgetManifest.swift \
  Shared/Models/WidgetRenderPlan.swift \
  Shared/Sharing/DailySharingCore.swift \
  Shared/AppGroup/SharedContainer.swift \
  Shared/Storage/AtomicJSON.swift \
  Shared/Sharing/SharingAPIConfiguration.swift \
  NekoWidget/Services/PairingAPIClient.swift \
  NekoWidget/Services/DailySharingStore.swift \
  NekoWidget/Services/DailySharingAPIClient.swift \
  ci/verify-sharing-api-responses.swift \
  -o "$RUNNER_TEMP/verify-sharing-api-responses"
"$RUNNER_TEMP/verify-sharing-api-responses" \
  ci/fixtures/sharing-api-v1-responses.json

xcrun swiftc \
  -parse-as-library \
  Shared/Sharing/PairingCore.swift \
  Shared/Models/WidgetRenderPlan.swift \
  Shared/Models/WidgetManifest.swift \
  Shared/Sharing/MomentSharingCore.swift \
  ci/verify-moment-sharing-core.swift \
  -o "$RUNNER_TEMP/verify-moment-sharing-core"
"$RUNNER_TEMP/verify-moment-sharing-core" \
  ci/fixtures/window-name-protocol-v1.json
