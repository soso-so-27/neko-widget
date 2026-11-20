#!/usr/bin/env bash
set -euo pipefail
python3 ci/prepare-family-seen-notification-probe.py "$RUNNER_TEMP/family-seen-probe.swift"
xcrun --sdk macosx swiftc -parse-as-library "$RUNNER_TEMP/family-seen-probe.swift" -o "$RUNNER_TEMP/family-seen-probe"
"$RUNNER_TEMP/family-seen-probe"
xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift \
  Shared/Models/AppSettings.swift Shared/Models/NekoCalendar.swift Shared/Models/NormalizedRect.swift \
  Shared/Models/CatCandidateCuration.swift Shared/Models/CatHouseholdIdentity.swift \
  Shared/Models/CatProfileTransfer.swift Shared/Models/NekoWidgetError.swift \
  Shared/Models/WidgetRenderPlan.swift Shared/Models/WidgetManifest.swift \
  Shared/Storage/AtomicJSON.swift Shared/AppGroup/SharedContainer.swift \
  NekoWidget/Services/FamilyNotebookCore.swift NekoWidget/Services/FamilyNotebookStore.swift \
  NekoWidget/Services/FamilyNotebookCrypto.swift NekoWidget/Services/FamilyNotebookTransport.swift \
  NekoWidget/Services/FamilyNotebookInvitationCrypto.swift NekoWidget/Services/FamilyNotebookKeyCoordinator.swift \
  NekoWidget/Services/FamilyNotebookSharingContract.swift NekoWidget/Services/FamilyNotebookMembershipClient.swift \
  NekoWidget/Services/FamilyNotebookSync.swift NekoWidget/Services/FamilyNotebookAdmissionClient.swift \
  NekoWidget/Services/FamilyNotebookRepresentativePhoto.swift Shared/Sharing/GroupReportCrypto.swift \
  NekoWidget/Services/ProductionFamilyNotebookSharingService.swift ci/verify-family-notebook-service.swift \
  -o "$RUNNER_TEMP/family-notebook-service-tests"
"$RUNNER_TEMP/family-notebook-service-tests"

# 11/20: the name a member writes under after deleting the app (FamilyNotebookAuthorName).
xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0"   Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift   NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift   NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift   Shared/Models/AppSettings.swift Shared/Models/NekoCalendar.swift Shared/Models/NormalizedRect.swift   Shared/Models/CatCandidateCuration.swift Shared/Models/CatHouseholdIdentity.swift   Shared/Models/CatProfileTransfer.swift Shared/Models/NekoWidgetError.swift   Shared/Models/WidgetRenderPlan.swift Shared/Models/WidgetManifest.swift   Shared/Storage/AtomicJSON.swift Shared/AppGroup/SharedContainer.swift   NekoWidget/Services/FamilyNotebookCore.swift NekoWidget/Services/FamilyNotebookStore.swift   NekoWidget/Services/FamilyNotebookCrypto.swift NekoWidget/Services/FamilyNotebookTransport.swift   NekoWidget/Services/FamilyNotebookInvitationCrypto.swift NekoWidget/Services/FamilyNotebookKeyCoordinator.swift   NekoWidget/Services/FamilyNotebookSharingContract.swift NekoWidget/Services/FamilyNotebookMembershipClient.swift   NekoWidget/Services/FamilyNotebookSync.swift NekoWidget/Services/FamilyNotebookAdmissionClient.swift   NekoWidget/Services/FamilyNotebookRepresentativePhoto.swift Shared/Sharing/GroupReportCrypto.swift   NekoWidget/Services/ProductionFamilyNotebookSharingService.swift ci/verify-family-notebook-author-name.swift   -o "$RUNNER_TEMP/family-notebook-author-name-tests"
"$RUNNER_TEMP/family-notebook-author-name-tests"

# 11/20: the notebook's 「表示しない」 choices survive deleting the app (Keychain copy).
xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0"   Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift   NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift   NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift   Shared/Models/AppSettings.swift Shared/Models/NekoCalendar.swift Shared/Models/NormalizedRect.swift   Shared/Models/CatCandidateCuration.swift Shared/Models/CatHouseholdIdentity.swift   Shared/Models/CatProfileTransfer.swift Shared/Models/NekoWidgetError.swift   Shared/Models/WidgetRenderPlan.swift Shared/Models/WidgetManifest.swift   Shared/Storage/AtomicJSON.swift Shared/AppGroup/SharedContainer.swift   NekoWidget/Services/FamilyNotebookCore.swift NekoWidget/Services/FamilyNotebookStore.swift   NekoWidget/Services/FamilyNotebookCrypto.swift NekoWidget/Services/FamilyNotebookTransport.swift   NekoWidget/Services/FamilyNotebookInvitationCrypto.swift NekoWidget/Services/FamilyNotebookKeyCoordinator.swift   NekoWidget/Services/FamilyNotebookSharingContract.swift NekoWidget/Services/FamilyNotebookMembershipClient.swift   NekoWidget/Services/FamilyNotebookSync.swift NekoWidget/Services/FamilyNotebookAdmissionClient.swift   NekoWidget/Services/FamilyNotebookRepresentativePhoto.swift Shared/Sharing/GroupReportCrypto.swift   NekoWidget/Services/ProductionFamilyNotebookSharingService.swift ci/verify-family-notebook-hidden-choices.swift   -o "$RUNNER_TEMP/family-notebook-hidden-choices-tests"
"$RUNNER_TEMP/family-notebook-hidden-choices-tests"

# 11/20: the answers to 「同じ子ですか」 survive deleting the app (Keychain copy).
xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0"   Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift   NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift   NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift   Shared/Models/AppSettings.swift Shared/Models/NekoCalendar.swift Shared/Models/NormalizedRect.swift   Shared/Models/CatCandidateCuration.swift Shared/Models/CatHouseholdIdentity.swift   Shared/Models/CatProfileTransfer.swift Shared/Models/NekoWidgetError.swift   Shared/Models/WidgetRenderPlan.swift Shared/Models/WidgetManifest.swift   Shared/Storage/AtomicJSON.swift Shared/AppGroup/SharedContainer.swift   NekoWidget/Services/FamilyNotebookCore.swift NekoWidget/Services/FamilyNotebookStore.swift   NekoWidget/Services/FamilyNotebookCrypto.swift NekoWidget/Services/FamilyNotebookTransport.swift   NekoWidget/Services/FamilyNotebookInvitationCrypto.swift NekoWidget/Services/FamilyNotebookKeyCoordinator.swift   NekoWidget/Services/FamilyNotebookSharingContract.swift NekoWidget/Services/FamilyNotebookMembershipClient.swift   NekoWidget/Services/FamilyNotebookSync.swift NekoWidget/Services/FamilyNotebookAdmissionClient.swift   NekoWidget/Services/FamilyNotebookRepresentativePhoto.swift Shared/Sharing/GroupReportCrypto.swift   NekoWidget/Services/ProductionFamilyNotebookSharingService.swift ci/verify-family-notebook-link-answers.swift   -o "$RUNNER_TEMP/family-notebook-link-answers-tests"
"$RUNNER_TEMP/family-notebook-link-answers-tests"

xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift \
  NekoWidget/Services/FamilyNotebookTransport.swift ci/verify-family-notebook-transport.swift \
  -o "$RUNNER_TEMP/family-notebook-transport-tests"
"$RUNNER_TEMP/family-notebook-transport-tests"

# 11/20 (two-device S5): 「通報への返答」 is read with the notebook's identity
# (the recovered device after 機種変更, else the usual one).
xcrun --sdk macosx swiftc -D INTERNAL_PRESENTATION -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift \
  NekoWidget/Services/GroupWindowAPIModels.swift NekoWidget/Services/GroupWindowPhotoValidation.swift \
  NekoWidget/Services/ProductionGroupWindowClient.swift NekoWidget/Services/GroupRecoveryClient.swift NekoWidget/Views/GroupRecoveryPresentation.swift \
  NekoWidget/Services/FamilyNotebookCore.swift NekoWidget/Services/FamilyNotebookCrypto.swift \
  NekoWidget/Services/FamilyNotebookTransport.swift NekoWidget/Services/FamilyNotebookInvitationCrypto.swift \
  NekoWidget/Services/FamilyNotebookKeyCoordinator.swift NekoWidget/Services/SharingAutoCheckPolicy.swift \
  ci/verify-family-report-replies-identity.swift \
  -o "$RUNNER_TEMP/family-report-replies-identity-tests"
"$RUNNER_TEMP/family-report-replies-identity-tests"

# 11/20 (#1102): a device taken off by another iPhone of the same person
# (reason device_revoked): the mark first, the entrance, no automatic call,
# the person's own new device. The two-device test's app sources.
revocation_sources=(
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
  ci/verify-device-revocation.swift
)
xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0"   "${revocation_sources[@]}" -o "$RUNNER_TEMP/device-revocation-tests"
"$RUNNER_TEMP/device-revocation-tests"

# 11/20: 「まどと家族の手帳のデータを消す」 leaves no sharing state behind
# (the client's keys after acceptance, then FamilySharingLocalData).
xcrun --sdk macosx swiftc -D INTERNAL_PRESENTATION -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift \
  NekoWidget/Services/GroupWindowAPIModels.swift NekoWidget/Services/GroupWindowPhotoValidation.swift \
  NekoWidget/Services/ProductionGroupWindowClient.swift NekoWidget/Services/GroupRecoveryClient.swift NekoWidget/Views/GroupRecoveryPresentation.swift \
  NekoWidget/Services/FamilyNotebookCore.swift NekoWidget/Services/FamilyNotebookCrypto.swift \
  NekoWidget/Services/FamilyNotebookTransport.swift NekoWidget/Services/FamilyNotebookInvitationCrypto.swift \
  NekoWidget/Services/FamilyNotebookKeyCoordinator.swift NekoWidget/Services/SharingAutoCheckPolicy.swift \
  ci/verify-identity-deletion-cleanup.swift \
  -o "$RUNNER_TEMP/identity-deletion-cleanup-tests"
"$RUNNER_TEMP/identity-deletion-cleanup-tests"

bash ci/run-family-representative-photo-checks.sh
