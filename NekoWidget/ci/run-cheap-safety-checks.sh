#!/usr/bin/env bash
# Cheap privacy, saved-data, and sharing checks. No simulator or evidence ledger.
set -euo pipefail
cd "$(dirname "$0")/.."

# Public programme boundaries: local publisher/Worker and native metadata.
# No UI suite, remote calls or publication.
node --test ../OfficialWindowService/test/program.test.js
xcrun swiftc -parse-as-library -D OFFICIAL_WINDOW_CHECKS \
  Shared/Models/OfficialWindowCatalog.swift Shared/Storage/AtomicJSON.swift \
  Shared/Storage/OfficialWindowStore.swift ci/verify-official-window.swift \
  -o "$RUNNER_TEMP/verify-official-window"
"$RUNNER_TEMP/verify-official-window"

python3 ci/test-disabled-release-config.py
python3 ci/test-disabled-release-build-settings.py
python3 ci/test-group-window-release.py
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
xcrun swiftc -parse-as-library Shared/MembershipAccessPolicy.swift \
  Shared/PersonalWidgetMembershipStore.swift ci/verify-personal-widget-membership.swift \
  -o "$RUNNER_TEMP/verify-personal-widget-membership"
"$RUNNER_TEMP/verify-personal-widget-membership"

# The personal Widget keeps its last photo after the trial/membership stops;
# this state-machine check guards that journal, its protected cache files,
# and the daily-photo plan (also run by the opt-in extended workflow).
xcrun --sdk macosx swiftc \
  -parse-as-library -D PERSONAL_REDISCOVERY_CHECKS \
  Shared/Models/WidgetManifest.swift \
  Shared/Models/WidgetRenderPlan.swift \
  Shared/Storage/PersonalRediscoveryStore.swift \
  ci/verify-personal-rediscovery.swift \
  -o "$RUNNER_TEMP/verify-personal-rediscovery"
"$RUNNER_TEMP/verify-personal-rediscovery"

# ADR-027 5章: the one Plus screen opens only from its entry places. A new
# caller of the sheet (or of the prompt that opens it) must be added here on
# purpose; photo access, invitations, receiving, hearts, and favorites never are.
# PairingView and AppRootView are reserved for the window and Widget entries.
# GroupWindowSetupView opens it only for "このまどを続ける" (continueWindow).
# GroupWindowView opens it only for "まどを作る" (createWindow), in GroupWindowCreateScreen.
plus_offer_allowed="NekoWidget/App/AppRootView.swift
NekoWidget/Services/MembershipOfferModel.swift
NekoWidget/Views/GroupWindowSetupView.swift
NekoWidget/Views/GroupWindowView.swift
NekoWidget/Views/MainTabView.swift
NekoWidget/Views/ManagedPreservationView.swift
NekoWidget/Views/OnboardingView.swift
NekoWidget/Views/PairingView.swift
NekoWidget/Views/PhotoMemoryNoteView.swift
NekoWidget/Views/SettingsView.swift
NekoWidget/Views/WindowSupportResumeView.swift"
plus_offer_found=$(grep -rlE --include='*.swift' 'MembershipOfferSheet\(|PlusOfferPrompt\(' \
  NekoWidget Shared NekoWidgetWidget NekoWidgetShareExtension | sort)
printf '%s\n' "$plus_offer_found" | grep -qx 'NekoWidget/Views/SettingsView.swift' \
  || { echo "Plus offer check found no Settings entry; the search is broken" >&2; exit 1; }
for file in $plus_offer_found; do
  printf '%s\n' "$plus_offer_allowed" | grep -qx "$file" \
    || { echo "The Plus screen is opened outside its entry places: $file" >&2; exit 1; }
done

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
