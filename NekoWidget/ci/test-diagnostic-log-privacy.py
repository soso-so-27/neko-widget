from pathlib import Path
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = ROOT.parent


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def section(value: str, start: str, end: str) -> str:
    start_index = value.index(start)
    end_index = value.index(end, start_index)
    return value[start_index:end_index]


def dictionary_argument_keys(value: str, label: str) -> list[str]:
    """Extract string keys from bracket literals passed to one named argument."""
    keys: list[str] = []
    position = 0
    while True:
        start = value.find(label, position)
        if start < 0:
            return keys
        cursor = start + len(label)
        while cursor < len(value) and value[cursor].isspace():
            cursor += 1
        if cursor >= len(value) or value[cursor] != "[":
            position = cursor
            continue

        depth = 0
        in_string = False
        escaped = False
        end = cursor
        while end < len(value):
            character = value[end]
            if in_string:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == '"':
                    in_string = False
            elif character == '"':
                in_string = True
            elif character == "[":
                depth += 1
            elif character == "]":
                depth -= 1
                if depth == 0:
                    block = value[cursor : end + 1]
                    keys.extend(
                        re.findall(r'"([A-Za-z][A-Za-z0-9_]*)"\s*:', block)
                    )
                    break
            end += 1
        position = max(end + 1, cursor + 1)


def sensitive_metadata_key(key: str) -> bool:
    lowered = key.lower()
    markers = (
        "error",
        "reason",
        "description",
        "token",
        "secret",
        "url",
        "query",
        "path",
    )
    return any(lowered.startswith(marker) or lowered.endswith(marker) for marker in markers)


def swift_set(value: str, declaration: str) -> set[str]:
    body = section(value, declaration, "]")
    return set(re.findall(r'"([A-Za-z][A-Za-z0-9_]*)"', body))


def balanced_block(value: str, opening_index: int, opening: str, closing: str) -> str:
    """Return one balanced Swift block while ignoring quoted delimiters."""
    depth = 0
    in_string = False
    escaped = False
    for index in range(opening_index, len(value)):
        character = value[index]
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == '"':
            in_string = True
        elif character == opening:
            depth += 1
        elif character == closing:
            depth -= 1
            if depth == 0:
                return value[opening_index : index + 1]
    raise AssertionError(f"unterminated {opening}{closing} block")


def shared_log_call_bodies(value: str) -> list[str]:
    calls: list[str] = []
    pattern = re.compile(
        r"SharedLog\.(?:app|widget)\.(?:debug|info|warning|error|log)\s*\("
    )
    for match in pattern.finditer(value):
        calls.append(balanced_block(value, match.end() - 1, "(", ")"))
    return calls


def dictionary_declaration_keys(value: str) -> set[str]:
    """Keys from indirect dictionaries that are passed to SharedLog."""
    keys: set[str] = set()
    declarations = (
        re.compile(
            r"\b(?:let|var)\s+(?:completionMetadata|metadata)\b[^=]*=\s*\["
        ),
        re.compile(r"\bvar\s+logMetadata\s*:\s*\[String\s*:\s*String\]\s*\{\s*\["),
    )
    for declaration in declarations:
        for match in declaration.finditer(value):
            block = balanced_block(value, match.end() - 1, "[", "]")
            keys.update(re.findall(r'"([A-Za-z][A-Za-z0-9_]*)"\s*:', block))
    keys.update(
        re.findall(
            r'\b(?:completionMetadata|metadata)\["([A-Za-z][A-Za-z0-9_]*)"\]\s*=',
            value,
        )
    )
    return keys


def finite_metadata_keys(value: str) -> set[str]:
    body = section(
        value,
        "private static let finiteMetadataValues",
        "private static let timestampMetadataKeys",
    )
    return set(re.findall(r'^\s*"([A-Za-z][A-Za-z0-9_]*)"\s*:', body, re.MULTILINE))


class DiagnosticLogPrivacyTests(unittest.TestCase):
    def test_production_swift_sanitizer_executes_synthetic_payloads(self) -> None:
        compiler: list[str] | None = None
        if shutil.which("xcrun"):
            compiler = ["xcrun", "swiftc"]
        elif shutil.which("swiftc"):
            compiler = ["swiftc"]
        if compiler is None:
            if sys.platform == "darwin":
                self.fail("macOS CI must provide xcrun swiftc for the privacy fixture")
            self.skipTest("Swift compiler is unavailable on this non-macOS host")

        production = ROOT / "Shared/Logging/DiagnosticLogPrivacy.swift"
        verifier = ROOT / "ci/verify-diagnostic-log-privacy.swift"
        with tempfile.TemporaryDirectory() as temporary_directory:
            executable = Path(temporary_directory) / "diagnostic-log-privacy-verifier"
            compile_result = subprocess.run(
                [*compiler, str(production), str(verifier), "-o", str(executable)],
                capture_output=True,
                check=False,
                text=True,
            )
            self.assertEqual(
                0,
                compile_result.returncode,
                f"Swift privacy fixture did not compile:\n{compile_result.stderr}",
            )
            run_result = subprocess.run(
                [str(executable)],
                capture_output=True,
                check=False,
                text=True,
            )
            self.assertEqual(
                0,
                run_result.returncode,
                f"Swift privacy fixture failed:\n{run_result.stderr}",
            )
            self.assertIn(
                "production DiagnosticLogPrivacy verifier passed",
                run_result.stdout,
            )

    def test_sanitizer_is_default_deny_and_in_both_product_targets(self) -> None:
        privacy = source("Shared/Logging/DiagnosticLogPrivacy.swift")
        verifier = source("ci/verify-diagnostic-log-privacy.swift")
        for compound_key in (
            "accessToken",
            "queryString",
            "relativePath",
            "callbackURL",
        ):
            self.assertIn(f'"{compound_key}"', verifier)
            self.assertNotIn(f'case "{compound_key}"', privacy)
        self.assertIn("default deny", privacy.lower())
        self.assertIn("private static let numericMetadataKeys", privacy)
        self.assertIn("private static let numericOrUnknownMetadataKeys", privacy)
        self.assertIn("private static let booleanMetadataKeys", privacy)
        self.assertIn("private static let shortHashMetadataKeys", privacy)
        self.assertIn("private static let dimensionMetadataKeys", privacy)
        self.assertIn("private static let simpleOrVariantDimensionMetadataKeys", privacy)
        self.assertIn("private static let variantNumberDescriptorMetadataKeys", privacy)
        self.assertIn("private static let pixelRangeMetadataKeys", privacy)
        self.assertIn("private static let widgetVariantSuffixes", privacy)
        self.assertIn("private static let widgetVariantNumberPrefixes", privacy)
        self.assertIn("private static let widgetVariantNumberRangePrefixes", privacy)
        self.assertIn("private static let intentionallyDroppedMetadataKeys", privacy)
        self.assertIn("private static let finiteMetadataValues", privacy)
        self.assertIn("private static let timestampMetadataKeys", privacy)
        self.assertIn("private static func validatedTimestamp", privacy)
        for fragment in (
            '"/private/var/"',
            '"\\\\"',
            '"/"',
            '"://"',
            '"?"',
            '"="',
            '"%2f"',
            '"token"',
            '"secret"',
            '".invalid"',
        ):
            self.assertIn(fragment, privacy)

        project = source("NekoWidget.xcodeproj/project.pbxproj")
        self.assertEqual(9, project.count("DiagnosticLogPrivacy.swift"))
        self.assertIn("100000000000000000000175", project)
        self.assertIn("20000000000000000000001C", project)

        verifier = source("ci/verify-diagnostic-log-privacy.swift")
        for required_typed_field in (
            "decodedBytesEstimate",
            "durationMs",
            "networkAllowed",
            "outputPixels",
            "requestedPixels",
            "priority",
            "pass",
            "status",
            "photoSource",
            "action",
            "source",
            "liked",
            "changedAt",
        ):
            self.assertIn(f'"{required_typed_field}"', verifier)

    def test_fixed_log_messages_do_not_trigger_payload_redaction(self) -> None:
        privacy = source("Shared/Logging/DiagnosticLogPrivacy.swift")
        markers: list[str] = []
        for array_name in (
            "pathOrQueryMarkers",
            "credentialMarkers",
            "hostMarkers",
        ):
            marker_section = section(
                privacy,
                f"let {array_name} = [",
                "]",
            )
            markers.extend(
                json.loads(f'"{encoded}"')
                for encoded in re.findall(r'"((?:\\.|[^"\\])*)"', marker_section)
            )

        call = re.compile(
            r"SharedLog\.(?:app|widget)\.(?:debug|info|warning|error|log)\("
            r'\s*(?:"(?:\\.|[^"\\])*"|[A-Za-z_][A-Za-z0-9_]*)\s*,\s*'
            r'"((?:\\.|[^"\\])*)"',
            re.DOTALL,
        )
        violations: list[str] = []
        for root_name in (
            "NekoWidget",
            "NekoWidgetWidget",
            "Shared",
        ):
            for path in (ROOT / root_name).rglob("*.swift"):
                value = path.read_text(encoding="utf-8")
                for match in call.finditer(value):
                    message = json.loads(f'"{match.group(1)}"').lower()
                    matched = sorted({marker for marker in markers if marker in message})
                    if matched:
                        violations.append(
                            f"{path.relative_to(ROOT)}: {message!r} matched {matched}"
                        )
        self.assertEqual([], violations)

    def test_typed_metadata_classifications_are_disjoint(self) -> None:
        privacy = source("Shared/Logging/DiagnosticLogPrivacy.swift")
        classifications = {
            "numeric": swift_set(privacy, "private static let numericMetadataKeys"),
            "numeric-or-unknown": swift_set(
                privacy,
                "private static let numericOrUnknownMetadataKeys",
            ),
            "boolean": swift_set(privacy, "private static let booleanMetadataKeys"),
            "hash": swift_set(privacy, "private static let shortHashMetadataKeys"),
            "dimensions": swift_set(privacy, "private static let dimensionMetadataKeys"),
            "simple-or-variant-dimensions": swift_set(
                privacy,
                "private static let simpleOrVariantDimensionMetadataKeys",
            ),
            "variant-number-descriptor": swift_set(
                privacy,
                "private static let variantNumberDescriptorMetadataKeys",
            ),
            "pixel-range": swift_set(
                privacy,
                "private static let pixelRangeMetadataKeys",
            ),
            "timestamp": swift_set(privacy, "private static let timestampMetadataKeys"),
        }
        names = list(classifications)
        for index, lhs in enumerate(names):
            for rhs in names[index + 1 :]:
                self.assertEqual(
                    set(),
                    classifications[lhs] & classifications[rhs],
                    f"metadata key is ambiguously classified as {lhs} and {rhs}",
                )

        for key in (
            "cancelled",
            "degraded",
            "detectionChanged",
            "liked",
            "linked",
            "priority",
        ):
            self.assertIn(key, classifications["boolean"])
        self.assertIn("handedOff", classifications["numeric"])
        self.assertNotIn("handedOff", classifications["boolean"])
        for count_key in ("sharedLiked", "visibleLiked"):
            self.assertIn(count_key, classifications["numeric"])
            self.assertNotIn(count_key, classifications["boolean"])
        self.assertIn("decodedBytesEstimate", classifications["numeric"])
        self.assertIn("durationMs", classifications["numeric"])
        self.assertIn("networkAllowed", classifications["boolean"])
        self.assertIn(
            "outputPixels",
            classifications["simple-or-variant-dimensions"],
        )
        self.assertIn("requestedPixels", classifications["dimensions"])
        self.assertIn("changedAt", classifications["timestamp"])
        self.assertEqual(
            {"build", "scanDurationMs"},
            classifications["numeric-or-unknown"],
        )

        self.assertIn("imageRequestPixels", classifications["dimensions"])
        self.assertIn(
            "targetBytesEach",
            classifications["variant-number-descriptor"],
        )
        self.assertIn("inputPixelsMax", classifications["pixel-range"])
        for widget_numeric_key in (
            "cacheBytesMax",
            "cacheBytesMin",
            "cacheBytesTotal",
            "cacheFileCap",
            "cacheGenerationCap",
            "compositionGeneratedBlurredFitFallback",
            "compositionGeneratedCatFullBleed",
            "compositionGeneratedMediumUpperFocus",
            "current8Fallback",
            "generatedFiles",
            "inputDecodedBytesMax",
            "legacy18Fallback",
            "marginFallbackDenominator",
            "renderScaleMax",
            "retainedCacheWorstCaseBytes",
            "reusedFiles",
        ):
            self.assertIn(widget_numeric_key, classifications["numeric"])

        finite = section(
            privacy,
            "private static let finiteMetadataValues",
            "private static let timestampMetadataKeys",
        )
        for key in (
            "action",
            "bboxScope",
            "marginComparisonScope",
            "pass",
            "photoSource",
            "sharingFailureReason",
            "source",
            "status",
        ):
            self.assertRegex(finite, rf'"{key}"\s*:\s*\[')
            for classification in classifications.values():
                self.assertNotIn(key, classification)

        suffixes = swift_set(privacy, "private static let widgetVariantSuffixes")
        self.assertEqual({"Large", "Medium", "Small"}, suffixes)
        self.assertEqual(
            {"renderUpscaled"},
            swift_set(privacy, "private static let widgetVariantNumberPrefixes"),
        )
        self.assertEqual(
            {"cacheBytes"},
            swift_set(privacy, "private static let widgetVariantNumberRangePrefixes"),
        )
        self.assertEqual(
            {"host", "scheme"},
            swift_set(privacy, "private static let intentionallyDroppedMetadataKeys"),
        )

    def test_every_shared_log_metadata_shape_has_an_explicit_contract(self) -> None:
        privacy = source("Shared/Logging/DiagnosticLogPrivacy.swift")
        product_roots = (
            ROOT / "NekoWidget",
            ROOT / "NekoWidgetShareExtension",
            ROOT / "NekoWidgetWidget",
            ROOT / "Shared",
        )

        discovered: dict[str, set[str]] = {}

        def record(key: str, location: str) -> None:
            discovered.setdefault(key, set()).add(location)

        call_count = 0
        for root in product_roots:
            for path in root.rglob("*.swift"):
                if path.name == "DiagnosticLogPrivacy.swift":
                    continue
                value = path.read_text(encoding="utf-8")
                relative = str(path.relative_to(ROOT))
                calls = shared_log_call_bodies(value)
                call_count += len(calls)
                for call in calls:
                    for key in re.findall(
                        r'"([A-Za-z][A-Za-z0-9_]*)"\s*:',
                        call,
                    ):
                        record(key, relative)
                for key in dictionary_declaration_keys(value):
                    record(key, f"{relative} (indirect metadata producer)")

        # The Widget completion dictionary has three deliberately dynamic key
        # families. Verify the producer syntax and expand only finite variants;
        # an added prefix, suffix, or merge source must update this contract.
        widget_builder = source("NekoWidget/Services/WidgetCacheBuilder.swift")
        dynamic_assignments = {
            re.sub(r"\s+", "", expression)
            for expression in re.findall(
                r'completionMetadata\[((?:[^\]"]|"(?:\\.|[^"\\])*")+)\]\s*=',
                widget_builder,
            )
        }
        self.assertEqual(
            {
                '"renderUpscaled\\(spec.variant.rawValue.capitalized)"',
                "mode.generatedMetadataKey",
            },
            dynamic_assignments,
        )
        self.assertEqual(
            {"bytesByVariant"},
            set(
                re.findall(
                    r"completionMetadata\.merge\(\s*([A-Za-z][A-Za-z0-9_]*)",
                    widget_builder,
                )
            ),
        )
        self.assertIn(
            '"cacheBytes\\(spec.variant.rawValue.capitalized)"',
            widget_builder,
        )

        suffixes = swift_set(privacy, "private static let widgetVariantSuffixes")
        for suffix in suffixes:
            record(f"cacheBytes{suffix}", "WidgetCacheBuilder dynamic byte range")
            record(f"renderUpscaled{suffix}", "WidgetCacheBuilder dynamic count")

        render_plan = source("Shared/Models/WidgetRenderPlan.swift")
        composition_keys = set(
            re.findall(r'case\s+\.[A-Za-z0-9_]+:\s*"(compositionGenerated[A-Za-z]+)"', render_plan)
        )
        self.assertEqual(
            {
                "compositionGeneratedBlurredFitFallback",
                "compositionGeneratedCatFullBleed",
                "compositionGeneratedMediumUpperFocus",
            },
            composition_keys,
        )
        for key in composition_keys:
            record(key, "WidgetCompositionMode.generatedMetadataKey")

        fixed_classifications = set().union(
            swift_set(privacy, "private static let numericMetadataKeys"),
            swift_set(privacy, "private static let numericOrUnknownMetadataKeys"),
            swift_set(privacy, "private static let booleanMetadataKeys"),
            swift_set(privacy, "private static let shortHashMetadataKeys"),
            swift_set(privacy, "private static let dimensionMetadataKeys"),
            swift_set(
                privacy,
                "private static let simpleOrVariantDimensionMetadataKeys",
            ),
            swift_set(
                privacy,
                "private static let variantNumberDescriptorMetadataKeys",
            ),
            swift_set(privacy, "private static let pixelRangeMetadataKeys"),
            swift_set(privacy, "private static let timestampMetadataKeys"),
            finite_metadata_keys(privacy),
            {"album", "group", "version"},
        )
        dynamic_classifications = {
            f"{prefix}{suffix}"
            for prefix in set().union(
                swift_set(privacy, "private static let widgetVariantNumberPrefixes"),
                swift_set(
                    privacy,
                    "private static let widgetVariantNumberRangePrefixes",
                ),
            )
            for suffix in suffixes
        }
        intentionally_dropped = swift_set(
            privacy,
            "private static let intentionallyDroppedMetadataKeys",
        )
        unclassified = {
            key: sorted(locations)
            for key, locations in discovered.items()
            if key
            not in fixed_classifications | dynamic_classifications | intentionally_dropped
        }
        self.assertGreater(call_count, 100, "SharedLog call discovery unexpectedly shrank")
        self.assertEqual({}, unclassified)
        self.assertEqual({"host", "scheme"}, intentionally_dropped & discovered.keys())

        required_diagnostic_contract = {
            "action",
            "album",
            "bboxScope",
            "cacheBytesLarge",
            "cacheBytesMedium",
            "cacheBytesSmall",
            "decodedBytesEstimate",
            "group",
            "imageRequestPixels",
            "inputPixelsMax",
            "liked",
            "marginComparisonScope",
            "outputPixels",
            "photoSource",
            "renderUpscaledLarge",
            "renderUpscaledMedium",
            "renderUpscaledSmall",
            "source",
            "status",
            "targetBytesEach",
        }
        self.assertEqual(set(), required_diagnostic_contract - discovered.keys())

    def test_persistence_readback_and_export_all_sanitize(self) -> None:
        shared_log = source("Shared/Logging/SharedLog.swift")
        self.assertIn(
            "message: SharedLog.sanitizedText(message, maximumLength: 600)",
            shared_log,
        )
        self.assertIn("metadata: SharedLog.sanitizedMetadata(metadata)", shared_log)
        self.assertIn("entries.append(sanitizedEntry(entry))", shared_log)
        self.assertIn("let urls = privacySafeLogURLs(in: directoryURL)", shared_log)
        self.assertIn('privacySafeSessionPrefix = "p2"', shared_log)
        read_all = section(shared_log, "static func readAll()", "static func formattedText")
        self.assertIn("purgeLegacyUnsafeLogs(in: directoryURL)", read_all)
        self.assertLess(
            read_all.index("purgeLegacyUnsafeLogs(in: directoryURL)"),
            read_all.index("let urls = privacySafeLogURLs(in: directoryURL)"),
        )
        purge = section(
            shared_log,
            "fileprivate static func purgeLegacyUnsafeLogs",
            "fileprivate static func sessionStemIsPrivacySafe",
        )
        self.assertIn("recognizedLogURLs(in: directoryURL)", purge)
        self.assertIn("!sessionStemIsPrivacySafe(stem)", purge)
        self.assertIn("removeItem(at: url)", purge)
        formatted = section(
            shared_log,
            "static func formattedText(for entries:",
            "static func clearAll()",
        )
        self.assertIn("let entry = sanitizedEntry(rawEntry)", formatted)
        self.assertIn(
            "DiagnosticLogPrivacy.sanitizeMetadata(metadata)",
            shared_log,
        )
        self.assertIn(
            "DiagnosticLogPrivacy.sanitizeText(value, maximumLength: maximumLength)",
            shared_log,
        )

    def test_legacy_persisted_error_fields_are_normalized_before_export(self) -> None:
        privacy = source("Shared/Logging/DiagnosticLogPrivacy.swift")
        verifier = source("ci/verify-diagnostic-log-privacy.swift")
        for helper in (
            "normalizedScanLastError",
            "normalizedPairingLastError",
            "normalizedMomentOutboxErrorCode",
        ):
            self.assertIn(f"static func {helper}", privacy)
            self.assertIn(f"DiagnosticLogPrivacy.{helper}", verifier)
        self.assertIn(
            'value == "http-503-moment_runtime_disabled"',
            privacy,
        )
        self.assertIn(
            '== "moment-runtime-disabled"',
            verifier,
        )
        for anchor in (
            "/private/var/",
            "example.invalid",
            "token=SUPERSECRET",
            "first line\\n/private/var/mobile/secret",
        ):
            self.assertIn(anchor, verifier)

        library_store = source("NekoWidget/Services/LibraryStore.swift")
        load_migration = section(
            library_store,
            "private static func migratedGroupedAlbumSnapshot",
            "return (value, didChange)",
        )
        self.assertIn("normalizedScanLastError", load_migration)
        self.assertIn("didChange = true", load_migration)
        save = section(library_store, "func save(", "func recoverAlbumLocalIdentifier")
        self.assertIn("normalizedScanLastError", save)

        exporter = source("NekoWidget/Services/JSONExporter.swift")
        encode = section(exporter, "func encode(to encoder:", "/// Rotation-proof")
        self.assertIn("var exportScanState = snapshot.scanState", encode)
        self.assertIn("normalizedScanLastError", encode)
        self.assertIn("container.encode(exportScanState, forKey: .scanState)", encode)
        self.assertNotIn("container.encode(snapshot.scanState", encode)

        runtime = source("NekoWidget/Services/SharingRuntimeSelfTest.swift")
        runtime_case = section(
            runtime,
            "private static func testDiagnosticPersistencePrivacy",
            "private static func writeProgress",
        )
        for anchor in (
            "SUPERSECRET",
            "example.invalid",
            "/private/var/",
            "second-line",
        ):
            self.assertIn(anchor, runtime_case)
        self.assertIn("JSONExporter().export(snapshot)", runtime_case)
        self.assertIn("persistedScanFailureCopy", runtime_case)
        self.assertIn('run("diagnostic-persistence-privacy")', runtime)

        moment_store = source("Shared/Sharing/MomentSharingStore.swift")
        outbox_validation = section(
            moment_store,
            "struct MomentOutboxItem:",
            "private static func hasValidCommitMetadata",
        )
        self.assertIn("normalizedMomentOutboxErrorCode", outbox_validation)
        load = section(
            moment_store,
            "private static func loadWhileLocked",
            "private static func pruneOutgoingOutcomes",
        )
        self.assertIn("let didNormalize = state.normalizePersistedDiagnosticErrors()", load)
        self.assertLess(load.index("normalizePersistedDiagnosticErrors"), load.index("validated()"))
        self.assertIn("if didNormalize { try writeWhileLocked(state) }", load)
        write = section(
            moment_store,
            "private static func writeWhileLocked",
            "private static func withLifecycleLock",
        )
        self.assertIn("state.normalizePersistedDiagnosticErrors()", write)
        self.assertIn("encoder.encode(try state.validated())", write)
        mark_failed = section(
            moment_store,
            "static func markOutboxFailed",
            "static func discardPendingOutbox",
        )
        self.assertIn("normalizedMomentOutboxErrorCode(code)", mark_failed)
        self.assertNotIn("code.prefix", mark_failed)

        coordinator = source("NekoWidget/Services/MomentSharingCoordinator.swift")
        safe_code = section(
            coordinator,
            "private nonisolated static func safeErrorCode",
            "private nonisolated static func synchronizationNotice",
        )
        self.assertIn('default: return "request-rejected"', safe_code)
        self.assertIn(
            'case "moment_runtime_disabled": return "moment-runtime-disabled"',
            safe_code,
        )
        self.assertIn('case "reservation_expired": return "reservation-expired"', safe_code)
        self.assertNotIn('"http-\\(', safe_code)
        self.assertNotIn("code.prefix", safe_code)

        presentation = source("NekoWidget/Views/MomentSharingPresentation.swift")
        self.assertIn('value.errorCodes.contains("moment-runtime-disabled")', presentation)
        self.assertNotIn('hasSuffix("moment_runtime_disabled")', presentation)
        presentation_fixture = source("ci/verify-moment-sharing-presentation.swift")
        self.assertIn('error: "moment-runtime-disabled"', presentation_fixture)

        pairing_store = source("Shared/Sharing/PairingKeychainStore.swift")
        pairing_load = section(
            pairing_store,
            "static func load() throws -> PairingState?",
            "private static func decodedStateWithNormalizedDiagnostics",
        )
        self.assertIn("decodedStateWithNormalizedDiagnostics().state", pairing_load)
        self.assertNotIn("saveWhileLifecycleLocked", pairing_load)
        pairing_decode = section(
            pairing_store,
            "private static func decodedStateWithNormalizedDiagnostics",
            "/// Physical cleanup is allowed only",
        )
        self.assertIn("normalizedPairingLastError", pairing_decode)
        pairing_locked_migration = section(
            pairing_store,
            "private static func loadWhileLifecycleLockedMigratingDiagnostics",
            "@discardableResult",
        )
        self.assertIn("decodedStateWithNormalizedDiagnostics(at: url)", pairing_locked_migration)
        self.assertIn(
            "try saveWhileLifecycleLocked(state, localWindowID: localWindowID)",
            pairing_locked_migration,
        )
        pairing_begin = section(
            pairing_store,
            "static func beginOperation()",
            "static func load() throws -> PairingState?",
        )
        self.assertIn("SharingLifecycleGate.withExclusive", pairing_begin)
        self.assertIn("loadWhileLifecycleLockedMigratingDiagnostics()", pairing_begin)
        pairing_cas = section(
            pairing_store,
            "private static func saveCASWhileLifecycleLocked",
            "/// Installation cleanup already owns",
        )
        self.assertIn("loadWhileLifecycleLockedMigratingDiagnostics(", pairing_cas)
        pairing_write = section(
            pairing_store,
            "static func saveWhileLifecycleLocked",
            "static func delete()",
        )
        self.assertIn("normalizedPairingLastError", pairing_write)
        self.assertLess(pairing_write.index("normalizedPairingLastError"), pairing_write.index("encoder.encode"))

        pairing_runtime = section(
            runtime,
            "let legacyPairingError =",
            "let pairingRevisionBeforeRename",
        )
        self.assertIn("PairingStateStore.load()", pairing_runtime)
        self.assertIn("Data(contentsOf: pairingStateURL) == legacyPairingData", pairing_runtime)
        self.assertIn("PairingStateStore.beginOperation()", pairing_runtime)
        self.assertIn("persistedPairingFailureCopy", pairing_runtime)

    def test_error_metadata_is_closed_and_drops_arbitrary_details(self) -> None:
        shared_log = source("Shared/Logging/SharedLog.swift")
        privacy = source("Shared/Logging/DiagnosticLogPrivacy.swift")
        metadata = section(
            shared_log,
            "static func errorMetadata(",
            "static func shortHash(",
        )
        for domain in (
            "NSCocoaErrorDomain",
            "NSPOSIXErrorDomain",
            "NSOSStatusErrorDomain",
            "NSURLErrorDomain",
        ):
            self.assertIn(domain, privacy)
        self.assertIn('return "other"', privacy)
        self.assertIn('metadata["failureCategory"] = category.rawValue', privacy)
        self.assertIn('metadata["failureCode"]', privacy)
        self.assertIn('metadata["failureDomain"] = stableErrorDomain(domain)', privacy)
        self.assertIn("DiagnosticLogPrivacy.errorMetadata(", metadata)
        self.assertNotIn("localizedDescription", metadata)
        self.assertNotIn("userInfo", metadata)

    def test_product_code_never_persists_raw_error_text(self) -> None:
        product_roots = (
            ROOT / "NekoWidget",
            ROOT / "NekoWidgetShareExtension",
            ROOT / "NekoWidgetWidget",
            ROOT / "Shared",
        )
        forbidden = (
            re.compile(r"\.localizedDescription"),
            re.compile(
                r"String\(describing:\s*[A-Za-z_]*error\s*\)",
                re.IGNORECASE,
            ),
            re.compile(r"\\\([A-Za-z_]*error\)", re.IGNORECASE),
        )
        violations: list[str] = []
        for root in product_roots:
            for path in root.rglob("*.swift"):
                value = path.read_text(encoding="utf-8")
                for pattern in forbidden:
                    if pattern.search(value):
                        violations.append(
                            f"{path.relative_to(ROOT)}: {pattern.pattern}"
                        )
        self.assertEqual([], violations)

        # A raw error can also be hidden behind an intermediate String. Keep
        # every persisted log message a source literal; variable details belong
        # only in the closed metadata helper above.
        call = re.compile(
            r"SharedLog\.(?:app|widget)\.(?:debug|info|warning|error|log)\("
        )
        literal_message_call = re.compile(
            r"SharedLog\.(?:app|widget)\.(?:debug|info|warning|error|log)\("
            r'\s*(?:"(?:\\.|[^"\\])*"|[A-Za-z_][A-Za-z0-9_]*)\s*,\s*"',
            re.DOTALL,
        )
        for root in product_roots:
            for path in root.rglob("*.swift"):
                value = path.read_text(encoding="utf-8")
                self.assertEqual(
                    len(call.findall(value)),
                    len(literal_message_call.findall(value)),
                    f"SharedLog message must be a source literal: {path.relative_to(ROOT)}",
                )

        self.assertIn(
            "fileprivate func log(",
            source("Shared/Logging/SharedLog.swift"),
        )

        violations = []
        for root in product_roots:
            for path in root.rglob("*.swift"):
                if path.name in {"SharedLog.swift", "DiagnosticLogPrivacy.swift"}:
                    continue
                value = path.read_text(encoding="utf-8")
                unsafe_keys = sorted({
                    key
                    for label in ("metadata:", "additional:")
                    for key in dictionary_argument_keys(value, label)
                    if key != "sharingFailureReason" and sensitive_metadata_key(key)
                })
                if unsafe_keys:
                    violations.append(
                        f"{path.relative_to(ROOT)}: {', '.join(unsafe_keys)}"
                    )
        self.assertEqual([], violations)

    def test_user_visible_unknown_errors_use_fixed_recovery_copy(self) -> None:
        targets = (
            "NekoWidget/ViewModels/AppViewModel.swift",
            "NekoWidget/ViewModels/PairingViewModel.swift",
            "NekoWidget/ViewModels/MomentSharingViewModel.swift",
            "NekoWidgetShareExtension/ShareViewController.swift",
            "NekoWidget/Views/LogView.swift",
        )
        for path in targets:
            value = source(path)
            self.assertNotIn("localizedDescription", value, path)
            self.assertNotRegex(value, r"String\(describing:\s*error\)", path)

        app = source(targets[0])
        self.assertIn('"Photo permission checked"', app)
        self.assertIn('"Photo permission request started"', app)
        self.assertIn('"Photo permission request finished"', app)
        self.assertNotIn('"Photo authorization checked"', app)
        self.assertIn("errorMessage = Self.userFacingMessage(for: error)", app)
        self.assertIn("failed.lastError = Self.userFacingMessage(for: error)", app)
        self.assertIn("if let value = error as? SharedLikeStoreError", app)
        self.assertIn("case .appGroupUnavailable:", app)
        self.assertIn(
            "albumStatus = .failed(message: Self.userFacingMessage(for: error))",
            app,
        )
        self.assertIn(
            "写真へのアクセスとiPhoneの空き容量を確認して、もう一度お試しください。",
            app,
        )

        pairing = source(targets[1])
        self.assertIn('"Could not remove consumed invitation material"', pairing)
        self.assertNotIn('"Could not scrub consumed invitation secret"', pairing)
        self.assertIn("operationErrorMessage = Self.userFacingMessage(for: error)", pairing)
        self.assertIn("updated.lastError = operationErrorMessage", pairing)
        self.assertIn("if state?.lastError != nil", pairing)

        moment = source(targets[2])
        self.assertIn("if let momentError = error as? MomentSharingError", moment)
        self.assertIn("if let pairingError = error as? PairingError", moment)
        self.assertIn(
            "写真共有の状態を確認できませんでした。時間をおいて、もう一度お試しください。",
            moment,
        )

        share = source(targets[3])
        self.assertIn("sharingError.errorDescription", share)
        self.assertIn(
            "この写真を一時保存できませんでした。iPhoneの空き容量を確認して、もう一度お試しください。",
            share,
        )

        log_view = source(targets[4])
        self.assertIn("SharedLog.errorMetadata(error, category: .diagnostics)", log_view)
        self.assertIn(
            "診断ログを書き出せませんでした。iPhoneの空き容量を確認して、もう一度お試しください。",
            log_view,
        )

    def test_known_server_errors_ignore_untrusted_message_text(self) -> None:
        pairing = source("Shared/Sharing/PairingCore.swift")
        pairing_error = section(
            pairing,
            "enum PairingError:",
            "enum PairingCrypto",
        )
        self.assertIn("case let .requestRejected(status, code, _):", pairing_error)

        moment = source("Shared/Sharing/MomentSharingCore.swift")
        moment_error = section(
            moment,
            "enum MomentSharingError:",
            "/// Values known to the Server",
        )
        self.assertIn("case let .requestRejected(status, code, _):", moment_error)

    def test_ios_build_runs_privacy_test_before_build(self) -> None:
        workflow = (REPOSITORY / ".github/workflows/ios-build.yml").read_text(
            encoding="utf-8"
        )
        test_call = "python3 ci/test-diagnostic-log-privacy.py"
        self.assertEqual(1, workflow.count(test_call))
        self.assertLess(
            workflow.index(test_call),
            workflow.index("- name: Build disabled app and extensions for iOS Simulator"),
        )


if __name__ == "__main__":
    unittest.main()
