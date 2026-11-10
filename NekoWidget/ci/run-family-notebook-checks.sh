#!/usr/bin/env bash
set -euo pipefail
# Family notebook stage 1: isolated stores and synthetic data only. The same
# source files are compiled into the app, with no UI or network connection.
notebook_common=(
  Shared/Models/AppSettings.swift Shared/Models/NekoCalendar.swift Shared/Models/NormalizedRect.swift
  Shared/Models/CatCandidateCuration.swift Shared/Models/CatHouseholdIdentity.swift
  Shared/Models/CatProfileTransfer.swift Shared/Models/NekoWidgetError.swift
  Shared/Models/WidgetRenderPlan.swift Shared/Models/WidgetManifest.swift
  Shared/Storage/AtomicJSON.swift Shared/AppGroup/SharedContainer.swift
  NekoWidget/Services/FamilyNotebookCore.swift NekoWidget/Services/FamilyNotebookStore.swift
)
xcrun --sdk macosx swiftc -parse-as-library "${notebook_common[@]}" \
  NekoWidget/Services/FamilyNotebookBackup.swift \
  ci/verify-family-notebook.swift -o "$RUNNER_TEMP/verify-family-notebook"
"$RUNNER_TEMP/verify-family-notebook"
xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" "${notebook_common[@]}" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift \
  NekoWidget/Services/FamilyNotebookCrypto.swift NekoWidget/Services/FamilyNotebookTransport.swift \
  NekoWidget/Services/FamilyNotebookSync.swift NekoWidget/Services/FamilyNotebookBackup.swift ci/verify-family-notebook-sync.swift \
  -o "$RUNNER_TEMP/verify-family-notebook-sync"
"$RUNNER_TEMP/verify-family-notebook-sync"
xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" "${notebook_common[@]}" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift \
  NekoWidget/Services/FamilyNotebookTransport.swift NekoWidget/Services/FamilyNotebookSharingContract.swift \
  NekoWidget/Services/FamilyNotebookMembershipClient.swift ci/verify-family-notebook-membership.swift \
  -o "$RUNNER_TEMP/verify-family-notebook-membership"
"$RUNNER_TEMP/verify-family-notebook-membership"
xcrun --sdk macosx swiftc -parse-as-library "${notebook_common[@]}" \
  NekoWidget/Services/CatCareCore.swift NekoWidget/Services/CareHandoffPlan.swift \
  NekoWidget/Services/PhotoMemoryNoteStore.swift NekoWidget/Services/VeterinaryVisitStore.swift \
  NekoWidget/Services/FamilyNotebookMigration.swift NekoWidget/Services/FamilyNotebookCatCareBridge.swift \
  NekoWidget/Services/FamilyNotebookToolBridge.swift ci/verify-family-notebook-tool-bridge.swift \
  ci/verify-family-notebook-catcare-bridge.swift \
  ci/verify-family-notebook-migration.swift -o "$RUNNER_TEMP/verify-family-notebook-migration"
"$RUNNER_TEMP/verify-family-notebook-migration"

