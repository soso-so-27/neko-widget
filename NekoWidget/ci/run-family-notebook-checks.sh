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

# Actual pre-change reader; keep the immutable baseline separate.
old_notebook_common=("${notebook_common[@]:0:${#notebook_common[@]}-2}" ci/fixtures/family-notebook-before-adoption/FamilyNotebookCore.swift ci/fixtures/family-notebook-before-adoption/FamilyNotebookStore.swift)
xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" "${old_notebook_common[@]}" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift \
  NekoWidget/Services/FamilyNotebookCrypto.swift NekoWidget/Services/FamilyNotebookTransport.swift \
  NekoWidget/Services/FamilyNotebookSync.swift ci/fixtures/family-notebook-before-adoption/FamilyNotebookBackup.swift ci/verify-family-notebook-sync.swift \
  -o "$RUNNER_TEMP/verify-family-notebook-sync-old"
"$RUNNER_TEMP/verify-family-notebook-sync-old"

export ADOPTION_ROOT="$RUNNER_TEMP/family-adoption-compat-$$"
ADOPTION_PHASE=new-receive "$RUNNER_TEMP/verify-family-notebook-sync"
ADOPTION_PHASE=old-edit "$RUNNER_TEMP/verify-family-notebook-sync-old"
ADOPTION_PHASE=new-verify "$RUNNER_TEMP/verify-family-notebook-sync"
unset ADOPTION_ROOT

# 11/15: the family order of cats with two frozen readers: before #985 (the
# one above) and main before the order. Neither baseline is updated.
before_order_common=("${notebook_common[@]:0:${#notebook_common[@]}-2}" ci/fixtures/family-notebook-before-order/FamilyNotebookCore.swift ci/fixtures/family-notebook-before-order/FamilyNotebookStore.swift)
xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" "${before_order_common[@]}" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift \
  NekoWidget/Services/FamilyNotebookCrypto.swift NekoWidget/Services/FamilyNotebookTransport.swift \
  NekoWidget/Services/FamilyNotebookSync.swift ci/fixtures/family-notebook-before-order/FamilyNotebookBackup.swift ci/verify-family-notebook-sync.swift \
  -o "$RUNNER_TEMP/verify-family-notebook-sync-before-order"
"$RUNNER_TEMP/verify-family-notebook-sync-before-order"
for reader in old before-order; do
  export POSITION_ROOT="$RUNNER_TEMP/family-position-compat-$reader-$$"
  POSITION_PHASE=new-write "$RUNNER_TEMP/verify-family-notebook-sync"
  POSITION_PHASE=old-edit "$RUNNER_TEMP/verify-family-notebook-sync-$reader"
  POSITION_PHASE=new-verify "$RUNNER_TEMP/verify-family-notebook-sync"
  unset POSITION_ROOT
  export PHOTO_COMPAT_ROOT="$RUNNER_TEMP/family-photo-compat-$reader-$$"
  PHOTO_COMPAT_PHASE=new-write "$RUNNER_TEMP/verify-family-notebook-sync"
  PHOTO_COMPAT_PHASE=old-edit "$RUNNER_TEMP/verify-family-notebook-sync-$reader"
  PHOTO_COMPAT_PHASE=new-verify "$RUNNER_TEMP/verify-family-notebook-sync"
  unset PHOTO_COMPAT_ROOT
done
xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" "${notebook_common[@]}" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift \
  NekoWidget/Services/FamilyNotebookTransport.swift NekoWidget/Services/FamilyNotebookSharingContract.swift \
  NekoWidget/Services/FamilyNotebookMembershipClient.swift ci/verify-family-notebook-membership.swift \
  -o "$RUNNER_TEMP/verify-family-notebook-membership"
"$RUNNER_TEMP/verify-family-notebook-membership"
xcrun --sdk macosx swiftc -parse-as-library "${notebook_common[@]}" \
  NekoWidget/Services/FamilyNotebookRecordOrigin.swift \
  NekoWidget/Services/CatCareCore.swift NekoWidget/Services/CareHandoffPlan.swift \
  NekoWidget/Services/PhotoMemoryNoteStore.swift NekoWidget/Services/VeterinaryVisitStore.swift \
  NekoWidget/Services/FamilyNotebookMigration.swift NekoWidget/Services/FamilyNotebookCatCareBridge.swift \
  NekoWidget/Services/FamilyNotebookToolBridge.swift ci/verify-family-notebook-tool-bridge.swift \
  NekoWidget/Services/FamilyNotebookCatLink.swift ci/verify-family-notebook-cat-link.swift \
  ci/verify-family-notebook-catcare-bridge.swift \
  ci/verify-family-notebook-migration.swift -o "$RUNNER_TEMP/verify-family-notebook-migration"
"$RUNNER_TEMP/verify-family-notebook-migration"


