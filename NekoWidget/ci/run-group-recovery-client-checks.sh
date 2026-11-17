#!/bin/bash
set -euo pipefail
xcrun --sdk macosx swiftc -D INTERNAL_PRESENTATION -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Shared/Sharing/GroupWindowCore.swift NekoWidget/Services/GroupWindowContract.swift \
  NekoWidget/Services/GroupWindowWire.swift NekoWidget/Services/GroupInvitationLink.swift NekoWidget/Services/GroupWindowStorage.swift \
  NekoWidget/Services/GroupWindowOperationStore.swift Shared/Sharing/ClientUpgradeRequirement.swift NekoWidget/Services/GroupWindowTransport.swift \
  NekoWidget/Services/GroupRecoveryClient.swift NekoWidget/Views/GroupRecoveryPresentation.swift \
  NekoWidget/Services/GroupRecoveryAdapter.swift ci/verify-group-recovery-client.swift -o "$RUNNER_TEMP/recovery-client"
for attempt in {1..10}; do
  echo "Recovery fixture run $attempt/10" >&2
  "$RUNNER_TEMP/recovery-client" | node ci/verify-native-recovery.mjs
done
