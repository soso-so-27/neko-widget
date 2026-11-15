#!/usr/bin/env bash
set -euo pipefail
notebook_photo_common=(
  Shared/Models/AppSettings.swift Shared/Models/NekoCalendar.swift Shared/Models/NormalizedRect.swift
  Shared/Models/CatCandidateCuration.swift Shared/Models/CatHouseholdIdentity.swift
  Shared/Models/CatProfileTransfer.swift Shared/Models/NekoWidgetError.swift
  Shared/Models/WidgetRenderPlan.swift Shared/Models/WidgetManifest.swift
  Shared/Storage/AtomicJSON.swift Shared/AppGroup/SharedContainer.swift
  NekoWidget/Services/FamilyNotebookCore.swift NekoWidget/Services/FamilyNotebookStore.swift
)
# Representative image preparation and cryptographic binding: no network or Simulator.
xcrun --sdk macosx swiftc -D FAMILY_REPRESENTATIVE_IMAGE_CHECKS -parse-as-library -target "$(uname -m)-apple-macos14.0" "${notebook_photo_common[@]}" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift \
  NekoWidget/Services/FamilyNotebookCrypto.swift NekoWidget/Services/FamilyNotebookTransport.swift \
  NekoWidget/Services/FamilyNotebookRepresentativePhoto.swift ci/verify-family-representative-image.swift ci/verify-family-notebook-crypto.swift \
  -o "$RUNNER_TEMP/verify-family-photo-crypto"
"$RUNNER_TEMP/verify-family-photo-crypto" > "$RUNNER_TEMP/family-photo-vector.json"

xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" "${notebook_photo_common[@]}" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift \
  NekoWidget/Services/FamilyNotebookCrypto.swift NekoWidget/Services/FamilyNotebookTransport.swift \
  NekoWidget/Services/FamilyNotebookRepresentativePhoto.swift ci/verify-family-representative-client.swift \
  -o "$RUNNER_TEMP/verify-family-photo-client"
"$RUNNER_TEMP/verify-family-photo-client"
