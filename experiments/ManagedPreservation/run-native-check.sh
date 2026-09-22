#!/usr/bin/env bash
# Focused diagnostic evidence only; never release or full-app UI evidence.
set -euo pipefail
cd "$(dirname "$0")/../.."
sources=(
  NekoWidget/NekoWidget/Services/ManagedPreservationClient.swift
  NekoWidget/NekoWidget/Services/ManagedPreservationSessionStore.swift
  NekoWidget/NekoWidget/Services/ManagedPreservationCoordinator.swift
  NekoWidget/NekoWidget/Views/ManagedPreservationView.swift
)
scratch=$(mktemp -d)
# The temporary compiler outputs are intentionally retained for runner disposal.
xcrun swiftc -typecheck -swift-version 5 -strict-concurrency=complete \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios17.0-simulator -module-cache-path "$scratch/modules-ios" "${sources[@]}"
xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 -strict-concurrency=complete \
  -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$scratch/modules-mac" \
  "${sources[0]}" "${sources[1]}" experiments/ManagedPreservation/verify-native-contract.swift \
  -o "$scratch/verify-native-contract"
"$scratch/verify-native-contract"
