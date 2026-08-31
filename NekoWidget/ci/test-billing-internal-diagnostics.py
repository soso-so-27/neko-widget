from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class BillingInternalDiagnosticsContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.app = source("NekoWidget/App/NekoWidgetApp.swift")
        self.diagnostics = source(
            "NekoWidget/App/BillingInternalDiagnostics.swift"
        )
        self.app_delegate = source(
            "NekoWidget/Services/MomentBackgroundRefreshService.swift"
        )

    def test_debug_argument_bypasses_production_root(self) -> None:
        route = self.app[
            self.app.index("var body: some Scene"):
            self.app.index("@MainActor\nprivate struct ProductionAppRootView")
        ]
        self.assertIn("#if DEBUG", route)
        argument = "BillingInternalDiagnosticsLaunch.isActive"
        self.assertIn(argument, route)
        self.assertLess(route.index(argument), route.index("ProductionAppRootView()"))
        self.assertIn("BillingInternalDiagnosticsRootView()", route)
        self.assertNotIn("BillingAccountBootstrapCoordinator", route)
        self.assertNotIn("BillingWindowSponsorshipCoordinator", route)
        self.assertIn(
            'static let argument = "--billing-internal-diagnostics"',
            self.diagnostics,
        )
        app_init = self.app[
            self.app.index("init() {"):
            self.app.index("var body: some Scene")
        ]
        self.assertIn(
            "let shouldRunLaunchCleanup = "
            "!BillingInternalDiagnosticsLaunch.isActive",
            app_init,
        )
        self.assertIn("if shouldRunLaunchCleanup {", app_init)
        self.assertIn(
            "if !BillingInternalDiagnosticsLaunch.isActive,",
            app_init,
        )

    def test_app_delegate_suppresses_normal_services_for_diagnostics(self) -> None:
        self.assertIn(
            "BillingInternalDiagnosticsLaunch.isActive",
            self.app_delegate,
        )
        self.assertGreaterEqual(
            self.app_delegate.count(
                "guard !Self.suppressesNormalServicesForDebugLaunch"
            ),
            8,
        )
        self.assertIn("completionHandler(.noData)", self.app_delegate)
        self.assertIn("else { return [] }", self.app_delegate)

    def test_exactly_seven_explicit_operations_exist(self) -> None:
        enum_body = self.diagnostics[
            self.diagnostics.index("private enum BillingInternalOperation"):
            self.diagnostics.index("private enum BillingInternalAvailability")
        ]
        cases = re.findall(r"^    case ([A-Za-z]+)$", enum_body, re.MULTILINE)
        self.assertEqual(
            cases,
            [
                "configurationAndKeychain",
                "bootstrapOrResume",
                "entitlement",
                "sponsorshipGet",
                "sponsor",
                "payerUnsponsor",
                "ownerDetach",
            ],
        )
        self.assertIn("ForEach(BillingInternalOperation.allCases)", self.diagnostics)
        self.assertIn("Button {", self.diagnostics)

    def test_actions_are_tap_only_and_sanitized(self) -> None:
        for forbidden in (
            ".task {",
            ".onAppear",
            "onChange(of:",
            "print(",
            "Logger(",
            "os_log",
            "localizedDescription",
            "UserDefaults.standard",
            "@AppStorage",
            "Data.write",
            "AtomicJSON",
        ):
            self.assertNotIn(forbidden, self.diagnostics)
        self.assertIn("Task {\n                                await model.perform(operation)", self.diagnostics)
        self.assertIn(".disabled(!model.canPerform(operation))", self.diagnostics)
        self.assertIn('case .prerequisiteMissing: "前提未取得"', self.diagnostics)

    def test_storekit_is_scan_only_and_never_purchase_restore_or_recovery(self) -> None:
        for forbidden in (
            "PlusPurchaseStore",
            "Product.products",
            ".purchase(",
            "AppStore.sync",
            "recoverBillingAccount",
            "BillingAccountRecoveryCoordinator",
        ):
            self.assertNotIn(forbidden, self.diagnostics)
        self.assertIn("resumeExistingCredential()", self.diagnostics)
        self.assertIn("authorizeAfterCurrentEntitlementScan()", self.diagnostics)
        self.assertIn("createFreshCredential(", self.diagnostics)
        self.assertIn(
            'return "\\(gate) / 購入・復元なし / 現在の購入確認のみ"',
            self.diagnostics,
        )

    def test_secrets_and_identifiers_are_never_rendered_or_logged(self) -> None:
        rendered = re.findall(r"(?:Text|LabeledContent)\((.*?)\)", self.diagnostics)
        joined = "\n".join(rendered)
        for forbidden in (
            "billingAccountID",
            "windowLineageID",
            "memberID",
            "participantID",
            "deviceID",
            "credentialAccount",
            "signingPrivateKey",
            "roomKey",
            "JWS",
            "Photo",
        ):
            self.assertNotIn(forbidden, joined)
        self.assertNotIn("errorDescription", self.diagnostics)
        self.assertNotIn("String(describing:", self.diagnostics)

    def test_destructive_window_actions_fail_closed(self) -> None:
        self.assertIn("snapshot.hasOwnerConsentContext", self.diagnostics)
        self.assertIn("binding.matches(pairing)", self.diagnostics)
        self.assertIn(
            "registeredBillingAccountID != nil",
            self.diagnostics,
        )
        self.assertIn("expectedCurrentBillingAccountID: nil", self.diagnostics)
        self.assertNotIn("confirmedPayerBillingAccountID", self.diagnostics)
        self.assertNotIn("expectedCurrentBillingAccountID: payer.billingAccountID", self.diagnostics)
        self.assertIn("PairingInstallationGuard.bootstrapAsync()", self.diagnostics)
        self.assertGreaterEqual(
            self.diagnostics.count("SharingLifecycleGate.validate("),
            4,
        )
        self.assertIn("catalog.activeWindowID", self.diagnostics)
        self.assertIn("localWindowID: activeEntry.localWindowID", self.diagnostics)
        self.assertIn(
            "guard requestedBinding == currentAuthorization.binding",
            self.diagnostics,
        )
        self.assertIn(
            "targetWindowText = currentAuthorization.displayName",
            self.diagnostics,
        )

    def test_file_is_host_app_only_and_source_gates_stay_closed(self) -> None:
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        app_start = project.index("A00000000000000000000021 /* Sources */ = {")
        extension_start = project.index(
            "A00000000000000000000025 /* Sources */ = {",
            app_start,
        )
        app_sources = project[app_start:extension_start]
        extension_sources = project[extension_start:]
        self.assertIn("NekoWidgetApp.swift in Sources", app_sources)
        self.assertNotIn("NekoWidgetApp.swift in Sources", extension_sources)
        self.assertIn(
            "BillingInternalDiagnostics.swift in Sources",
            app_sources,
        )
        self.assertNotIn(
            "BillingInternalDiagnostics.swift in Sources",
            extension_sources,
        )
        self.assertTrue(self.diagnostics.lstrip().startswith("#if DEBUG"))
        self.assertTrue(self.diagnostics.rstrip().endswith("#endif"))

        config = source("Config.xcconfig")
        self.assertRegex(config, r"(?m)^PLUS_STOREFRONT_ENABLED = NO$")
        self.assertRegex(config, r"(?m)^PLUS_BILLING_CLIENT_ENABLED = NO$")
        self.assertRegex(
            config,
            r"(?m)^PLUS_WINDOW_SPONSORSHIP_CLIENT_ENABLED = NO$",
        )


if __name__ == "__main__":
    unittest.main()
