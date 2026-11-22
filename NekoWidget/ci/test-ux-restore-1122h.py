#!/usr/bin/env python3
"""11/22 (A7): a new iPhone had no visible way to restore.

Page one of the first run has a quiet 「前のiPhoneから戻す」 under 「猫を探す」,
only where 自動保存 exists (the same condition as 設定's row). It opens the
very screen of 設定 → 自動保存 as a sheet; closing it returns to page one.
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def section(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


COPY = source("NekoWidget/Views/OnboardingPresentation.swift")
ONBOARDING = source("NekoWidget/Views/OnboardingView.swift")
APP_ROOT = source("NekoWidget/App/AppRootView.swift")
SETTINGS = source("NekoWidget/Views/SettingsView.swift")
VERIFY = source("ci/verify-onboarding-presentation.swift")


class RestoreEntryTests(unittest.TestCase):
    def test_copy_is_pinned(self):
        self.assertIn('static let purposeRestoreAction = "前のiPhoneから戻す"', COPY)
        self.assertIn('OnboardingPresentationCopy.purposeRestoreAction == "前のiPhoneから戻す"', VERIFY)

    def test_quiet_button_under_the_main_button_and_above_the_invitation_line(self):
        purpose = section(ONBOARDING, "private struct OnboardingPurposePage: View", "struct OnboardingWindowMosaic: View")
        self.assertIn("var restoreAction: (() -> Void)? = nil", purpose)
        button = section(purpose, "if let restoreAction {", '.accessibilityIdentifier("onboarding-purpose-restore")')
        self.assertIn("Button(OnboardingPresentationCopy.purposeRestoreAction, action: restoreAction)", button)
        # The same quiet grey text as 「あとで」, not a second bordered button.
        for style in (".buttonStyle(.plain)", ".font(.subheadline)", ".foregroundStyle(.secondary)",
                      ".frame(minHeight: 44)"):
            self.assertIn(style, button)
        self.assertNotIn("borderedProminent", button)
        self.assertLess(purpose.index('"onboarding-purpose-start"'), purpose.index('"onboarding-purpose-restore"'))
        # The invitation line stays, still a line, under the restore button.
        self.assertLess(purpose.index('"onboarding-purpose-restore"'),
                        purpose.index("Text(OnboardingPresentationCopy.purposeInvitationLine)"))
        self.assertIn("if SharingAPIConfiguration.current.isReviewVisible {", purpose)

    def test_onboarding_passes_the_action_to_page_one(self):
        self.assertIn("var openRestore: (() -> Void)? = nil", ONBOARDING)
        self.assertIn("OnboardingPurposePage(continueAction: { page = .photoPermission },\n"
                      "                                      restoreAction: openRestore)", ONBOARDING)

    def test_shown_only_where_auto_save_exists_like_settings(self):
        self.assertIn("if ManagedPreservationConfiguration.current.isEnabled {", SETTINGS)
        call = section(APP_ROOT, "    private var onboardingContent: some View {", ".environment(\\.plusOfferPhoto")
        self.assertIn("openRestore: ManagedPreservationConfiguration.current.isEnabled\n"
                      "                ? { showsOnboardingRestore = true } : nil", call)

    def test_sheet_is_the_same_auto_save_screen_as_settings(self):
        self.assertIn("@State private var showsOnboardingRestore = false", APP_ROOT)
        sheet = section(APP_ROOT, ".sheet(isPresented: $showsOnboardingRestore, onDismiss: {",
                        '.accessibilityIdentifier("onboarding-restore-close")')
        self.assertIn("NavigationStack {", sheet)
        self.assertIn("AppRecordSettingsView(profileTransfer: (actions: catProfilesActions,", sheet)
        self.assertIn("AppRecordSettingsView(profileTransfer: (actions: catProfilesActions,", SETTINGS)
        self.assertNotIn("startsOnOpen", sheet)
        self.assertIn('Button("閉じる") { showsOnboardingRestore = false }', sheet)
        # Closing it does not move the first run; a link that came meanwhile is offered.
        dismiss = section(sheet, "onDismiss: {", "NavigationStack {")
        self.assertNotIn("completeOnboarding", dismiss)
        self.assertNotIn("onboardingPage", dismiss)
        self.assertIn("let invitation = invitationInbox.pending", dismiss)
        self.assertIn("DispatchQueue.main.async { onboardingInvitation = invitation }", dismiss)


if __name__ == "__main__":
    unittest.main()
