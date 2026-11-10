"""Usage endpoint and privacy boundary; no network access."""
PRODUCTION = 'https://usage.nekonomado.com/v1/usage'
STAGING = 'https://neko-usage-staging.nakanishisoya.workers.dev/v1/usage'
ANALYTICS = 'NSPrivacyCollectedDataTypePurposeAnalytics'
PRODUCT = 'NSPrivacyCollectedDataTypeProductInteraction'

def verify(info, *, mode, synthetic=False):
    expected = '' if synthetic else {'production': PRODUCTION, 'media-staging': STAGING}.get(mode, '')
    if info.get('UsageReportURL') != expected:
        raise ValueError('UsageReportURL differs from the reviewed environment endpoint')

def verify_privacy(privacy):
    entries = [x for x in privacy['NSPrivacyCollectedDataTypes'] if x['NSPrivacyCollectedDataType'] == PRODUCT]
    if len(entries) != 1 or entries[0]['NSPrivacyCollectedDataTypeLinked'] is not True or entries[0]['NSPrivacyCollectedDataTypeTracking'] is not False:
        raise ValueError('Keep the existing single linked, nontracking ProductInteraction declaration')
    if entries[0]['NSPrivacyCollectedDataTypePurposes'] != ['NSPrivacyCollectedDataTypePurposeAppFunctionality', ANALYTICS]:
        raise ValueError('ProductInteraction requires functionality plus analytics')

if __name__ == '__main__':
    import sys
    mode = sys.argv[1] if len(sys.argv) == 2 else None
    if mode not in ('production', 'media-staging', 'disabled', 'pairing-only', 'review-preview'):
        raise SystemExit('Explicit known release mode required')
    print({'production': PRODUCTION, 'media-staging': STAGING}.get(mode, ''))
