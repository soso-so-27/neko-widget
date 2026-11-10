#!/usr/bin/env bash
set -euo pipefail
python3 ci/prepare-family-seen-notification-probe.py "$RUNNER_TEMP/family-seen-probe.swift"
xcrun --sdk macosx swiftc -parse-as-library "$RUNNER_TEMP/family-seen-probe.swift" -o "$RUNNER_TEMP/family-seen-probe"
"$RUNNER_TEMP/family-seen-probe"
xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift \
  Shared/Models/AppSettings.swift Shared/Models/NormalizedRect.swift \
  Shared/Models/CatCandidateCuration.swift Shared/Models/CatHouseholdIdentity.swift \
  Shared/Models/CatProfileTransfer.swift Shared/Models/NekoWidgetError.swift \
  Shared/Models/WidgetRenderPlan.swift Shared/Models/WidgetManifest.swift \
  Shared/Storage/AtomicJSON.swift Shared/AppGroup/SharedContainer.swift \
  NekoWidget/Services/FamilyNotebookCore.swift NekoWidget/Services/FamilyNotebookStore.swift \
  NekoWidget/Services/FamilyNotebookCrypto.swift NekoWidget/Services/FamilyNotebookTransport.swift \
  NekoWidget/Services/FamilyNotebookInvitationCrypto.swift NekoWidget/Services/FamilyNotebookKeyCoordinator.swift \
  NekoWidget/Services/FamilyNotebookSharingContract.swift NekoWidget/Services/FamilyNotebookMembershipClient.swift \
  NekoWidget/Services/FamilyNotebookSync.swift NekoWidget/Services/FamilyNotebookAdmissionClient.swift \
  NekoWidget/Services/ProductionFamilyNotebookSharingService.swift ci/verify-family-notebook-service.swift \
  -o "$RUNNER_TEMP/family-notebook-service-tests"
"$RUNNER_TEMP/family-notebook-service-tests"

xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift \
  NekoWidget/Services/FamilyNotebookTransport.swift ci/verify-family-notebook-transport.swift \
  -o "$RUNNER_TEMP/family-notebook-transport-tests"
"$RUNNER_TEMP/family-notebook-transport-tests"
