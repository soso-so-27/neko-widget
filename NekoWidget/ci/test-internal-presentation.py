"""Source boundary checks for public Release, internal Release and DEBUG.

This evaluates compilation clauses, not Swift semantics or rendered UI. Native
CI separately parses all three variants and builds the public Release app.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def selected_source(source, defines=()):
    def condition(expression):
        expression = expression.split('//', 1)[0]
        expression = re.sub(r'os\(([^)]+)\)', lambda m: 'true' if m[1] == 'iOS' else 'false', expression)
        expression = re.sub(r'(?:canImport|targetEnvironment|swift|compiler)\([^)]*\)', 'true', expression)
        expression = re.sub(r'\b[A-Za-z_]\w*\b', lambda m: str(m[0] == 'true' or m[0] in defines), expression)
        expression = expression.replace('&&', ' and ').replace('||', ' or ').replace('!', ' not ')
        if re.sub(r'True|False|and|or|not|[()\s]', '', expression):
            raise ValueError('Unsupported Swift condition: ' + expression)
        return eval(expression, {'__builtins__': {}}, {})

    active, stack, output = True, [], []
    for line in source.splitlines():
        directive = re.match(r'\s*#(if|elseif|else|endif)\b(.*)', line)
        if not directive:
            if active:
                output.append(line)
            continue
        kind, expression = directive.groups()
        if kind == 'if':
            matches = condition(expression)
            stack.append([active, matches])
            active = active and matches
        elif kind == 'elseif':
            parent, taken = stack[-1]
            matches = condition(expression)
            active = parent and not taken and matches
            stack[-1][1] = taken or matches
        elif kind == 'else':
            parent, taken = stack[-1]
            active = parent and not taken
            stack[-1][1] = True
        else:
            active = stack.pop()[0]
    if stack:
        raise ValueError('Unterminated Swift compilation clause')
    return '\n'.join(output)


class InternalPresentationBoundaryTests(unittest.TestCase):
    def sources(self, defines=()):
        return {str(path.relative_to(ROOT)): selected_source(path.read_text(encoding='utf-8'), defines)
                for folder in ('NekoWidget', 'Shared', 'NekoWidgetWidget', 'NekoWidgetShareExtension')
                for path in (ROOT / folder).rglob('*.swift')}

    def test_public_release_has_no_internal_implementations_or_references(self):
        forbidden = ('MembershipOfferPreviewView', 'MembershipOfferPreviewAvailability',
                     'BillingSandboxOwnerEnrollmentView', 'BillingSandboxOwnerEnrollmentAvailability',
                     'authorizeForSandboxOwnerPreparation', 'prepareSandboxOwnerPending',
                     'MembershipOfferFixtureStatus', 'fixtureStatus', 'showsManagementPreview',
                     'QuotaTrial', 'quotaTrial', 'BookDemandPreview', 'BookDemandValidationPolicy',
                     'bookDemandPreview', 'bookDemandSelectionGuide', 'bookPreview',
                     'GroupReportingPrototype', 'GroupListTrace', 'GroupListMeasurement', 'lastLoadTiming',
                     'advancedDiagnosticsView', 'DetectionAccuracySampleView', 'showsMembershipPreview',
                     'SharingReviewPreviewView', 'settings-cloudy-again', 'preservation-quota-trial',
                     '--membership-offer-no-trial', 'opensAsSlideshow', 'YearStoryContentView',
                     'storyBody', 'struct LogView', 'LogViewModel', 'album-arrival.try',
                     'debug.albumPrototype.yearNow', 'debug.albumPrototype.slideshow')
        for path, source in self.sources().items():
            for token in forbidden:
                with self.subTest(path=path, token=token):
                    self.assertNotIn(token, source)

    def test_internal_and_debug_retain_the_reviewed_tools(self):
        for defines in ({'INTERNAL_PRESENTATION'}, {'DEBUG'}):
            combined = '\n'.join(self.sources(defines).values())
            for token in ('MembershipOfferPreviewView', 'BillingSandboxOwnerEnrollmentView', 'QuotaTrial',
                          'BookDemandPreviewView', 'GroupReportingPrototype', 'GroupListTrace',
                          'settings-cloudy-again', '--membership-offer-no-trial'):
                with self.subTest(defines=defines, token=token):
                    self.assertIn(token, combined)

    def test_owner_decisions_1108_keep_internal_only_screens_and_words_out_of_public(self):
        # B: 「保存したコピー」, its copies and saving/restoring by hand; A: 「復元したツール」.
        # 37/38: the internal pilot's storage words and the internal report notice.
        internal_only = ('recordsSection', 'detailSection', 'toolBackupSection', 'pendingMemoSection',
                         'RestoredToolsView', 'RestoredToolWorkspace', '"preservation-restore-tools"',
                         '"preservation-export-all"', '"内部テスト', '"保管枠を確認"',
                         '"この内部版では通報の受付を停止しています。"', '"利用期間内は購入なしで保管できます。')
        public = self.sources()
        for path, source in public.items():
            for token in internal_only:
                with self.subTest(path=path, token=token):
                    self.assertNotIn(token, source)
        for defines in ({'INTERNAL_PRESENTATION'}, {'DEBUG'}):
            combined = chr(10).join(self.sources(defines).values())
            for token in internal_only:
                with self.subTest(defines=defines, token=token):
                    self.assertIn(token, combined)
        # The code stays, and App Store builds still restore through 自動保存.
        view = public[str(Path('NekoWidget/Views/ManagedPreservationView.swift'))]
        self.assertIn('if allowsRecordBrowsing { savedCopiesSections }', view)
        self.assertIn('else if coordinator.selected != nil { selectedCopySection }', view)
        saving = public[str(Path('NekoWidget/Services/AppRecordPersistence.swift'))]
        self.assertIn('Text("前のiPhoneから戻す")', saving)
        self.assertIn('NavigationLink("自動保存のアカウント") { ManagedPreservationView() }', saving)
        report = public[str(Path('NekoWidget/Views/GroupWindowView.swift'))]
        self.assertIn('Text(GroupReportUnavailableText.message)', report)
        client = public[str(Path('NekoWidget/Services/ManagedPreservationClient.swift'))]
        self.assertIn('case .pilotRegistrationPending(let reference): Self.pilotRegistrationText(reference)', client)

    def test_public_availability_cannot_read_runtime_internal_mode(self):
        source = selected_source((ROOT / 'Shared/Models/OfficialWindowCatalog.swift').read_text(encoding='utf-8'))
        availability = source.split('enum InternalBuildPresentationAvailability {', 1)[1].split('enum Version1', 1)[0]
        self.assertIn('false', availability)
        self.assertNotIn('Bundle.main', availability)
        self.assertIn('== "production"', source)

    def test_public_report_fallback_is_unavailable_and_quota_is_real(self):
        source = selected_source((ROOT / 'NekoWidget/Services/GroupReportingProvider.swift').read_text(encoding='utf-8'))
        self.assertIn('return UnavailableGroupReporting()', source.split('private static func internalFallback()', 1)[1])
        self.assertIn('config.isOwnerInternalReportsDisabled', source)
        quota = selected_source((ROOT / 'NekoWidget/Views/ManagedPreservationView.swift').read_text(encoding='utf-8'))
        self.assertIn('guard let real, real.configurationStatus == "valid" else { return nil }', quota)
        self.assertIn('return real', quota)

    def test_owner_selection_preserves_target_conditions(self):
        project = (ROOT / 'NekoWidget.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
        self.assertIn('$(inherited) $(INTERNAL_PRESENTATION_CONDITION)', project)
        for token in ('$(inherited) NEKO_HOST_APP', '$(inherited) NEKO_SHARE_EXTENSION'):
            self.assertIn(token, project)
        media = (ROOT / 'Config.MediaStaging.xcconfig').read_text(encoding='utf-8')
        self.assertIn('INTERNAL_PRESENTATION_CONDITION = INTERNAL_PRESENTATION', media)
        release = (ROOT.parent / '.github/workflows/testflight.yml').read_text(encoding='utf-8')
        self.assertIn('"$DISTRIBUTION_PROFILE" == "owner-internal" || "$RELEASE_SHARING_RELEASE_MODE" == "media-staging"', release)
        self.assertIn('owner_build_args+=(INTERNAL_PRESENTATION_CONDITION=INTERNAL_PRESENTATION)', release)


if __name__ == '__main__':
    unittest.main()
