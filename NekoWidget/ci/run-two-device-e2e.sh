#!/usr/bin/env bash
# The Swift side of the two-device test. Only .github/workflows/two-device-e2e.yml
# runs it, after it has started the local SharingService Worker on 127.0.0.1
# with throwaway D1/R2 (not part of run-quick-ios-checks.sh). Needs
# NEKO_TWO_DEVICE_ORIGIN and NEKO_TWO_DEVICE_FIXTURES from that workflow.
# NEKO_TWO_DEVICE_ONLY=S4 runs one scenario.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${NEKO_TWO_DEVICE_ORIGIN:?Start the local Worker first (see two-device-e2e.yml)}"
: "${NEKO_TWO_DEVICE_FIXTURES:?Pass the fixtures.json written by e2e-seed.mjs}"
build="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/two-device-e2e"
mkdir -p "$build"

# The app's own sources: the family notebook's (run-family-notebook-network-checks.sh)
# with the usual client and the recovery builder (verify-group-adapter /
# run-group-recovery-client-checks.sh), the cat bridge (run-family-notebook-checks.sh)
# and the まど photo store (verify-group-window-choices-survive-reinstall.swift).
# No -D INTERNAL_PRESENTATION or DEBUG: the App Store build's branches. (The
# owner-trial narrowing of recovery candidates is in GroupRecoveryLiveModel.connected(),
# iOS only, and not compiled here either way.)
sources=(
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift
  NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift
  Shared/Models/AppSettings.swift Shared/Models/NekoCalendar.swift Shared/Models/NormalizedRect.swift
  Shared/Models/CatCandidateCuration.swift Shared/Models/CatHouseholdIdentity.swift
  Shared/Models/CatProfileTransfer.swift Shared/Models/NekoWidgetError.swift
  Shared/Models/WidgetRenderPlan.swift Shared/Models/WidgetManifest.swift
  Shared/Storage/AtomicJSON.swift Shared/AppGroup/SharedContainer.swift
  NekoWidget/Services/FamilyNotebookCore.swift NekoWidget/Services/FamilyNotebookStore.swift
  NekoWidget/Services/FamilyNotebookCrypto.swift NekoWidget/Services/FamilyNotebookTransport.swift
  NekoWidget/Services/FamilyNotebookInvitationCrypto.swift NekoWidget/Services/FamilyNotebookKeyCoordinator.swift
  NekoWidget/Services/FamilyNotebookSharingContract.swift NekoWidget/Services/FamilyNotebookMembershipClient.swift
  NekoWidget/Services/FamilyNotebookSync.swift NekoWidget/Services/FamilyNotebookAdmissionClient.swift
  NekoWidget/Services/FamilyNotebookRepresentativePhoto.swift Shared/Sharing/GroupReportCrypto.swift
  NekoWidget/Services/ProductionFamilyNotebookSharingService.swift
  NekoWidget/Services/GroupWindowAPIModels.swift NekoWidget/Services/GroupWindowPhotoValidation.swift
  NekoWidget/Services/ProductionGroupWindowClient.swift
  NekoWidget/Services/GroupRecoveryClient.swift NekoWidget/Views/GroupRecoveryPresentation.swift
  NekoWidget/Services/GroupRecoveryAdapter.swift NekoWidget/Services/GroupRecoveryLiveSession.swift
  NekoWidget/Services/RootSyncStore.swift
  NekoWidget/Services/FamilyNotebookRecordOrigin.swift NekoWidget/Services/CatCareCore.swift
  NekoWidget/Services/CareHandoffPlan.swift NekoWidget/Services/PhotoMemoryNoteStore.swift
  NekoWidget/Services/VeterinaryVisitStore.swift NekoWidget/Services/FamilyNotebookMigration.swift
  NekoWidget/Services/FamilyNotebookCatCareBridge.swift NekoWidget/Services/FamilyNotebookToolBridge.swift
  NekoWidget/Services/FamilyNotebookCatLink.swift NekoWidget/Services/SharingAutoCheckPolicy.swift
  NekoWidget/Services/GroupWindowLocalPhotoStore.swift
  ci/two-device/Harness.swift ci/two-device/Scenarios.swift
)
echo "Compiling the two-device driver (${#sources[@]} files)" >&2
xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  "${sources[@]}" -o "$build/two-device-e2e"
"$build/two-device-e2e"
