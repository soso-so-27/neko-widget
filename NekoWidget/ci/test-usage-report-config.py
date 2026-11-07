import importlib.util
import pathlib
import plistlib
import unittest
from usage_report_config import verify, verify_privacy, PRODUCTION, STAGING
ROOT=pathlib.Path(__file__).resolve().parents[1]
class UsageConfigTests(unittest.TestCase):
    def test_environment_boundary(self):
        for mode,endpoint in [('production',PRODUCTION),('media-staging',STAGING),('disabled',''),('pairing-only',''),('review-preview','')]:
            verify({'UsageReportURL':endpoint},mode=mode)
            for wrong in [None,endpoint+'x','https://other.example/v1/usage']:
                with self.assertRaises(ValueError): verify({'UsageReportURL':wrong},mode=mode)
        with self.assertRaises(ValueError): verify({'UsageReportURL':STAGING},mode='production')
        verify({'UsageReportURL':''},mode='production',synthetic=True)
    def test_manifest_and_source_bindings(self):
        for name in ['Production/PrivacyInfo.xcprivacy','ci/PrivacyInfo.MediaStaging.xcprivacy']:
            verify_privacy(plistlib.loads((ROOT/name).read_bytes()))
        info=plistlib.loads((ROOT/'NekoWidget/Info.plist').read_bytes())
        self.assertEqual(info['UsageReportURL'],'$(USAGE_REPORT_URL)')
        for name,url in [('Config.Production.xcconfig',PRODUCTION),('Config.MediaStaging.xcconfig',STAGING),('Config.Disabled.xcconfig',''),('Config.xcconfig','')]:
            lines=[x.split('=',1)[1].strip().replace('$()','') for x in (ROOT/name).read_text(encoding='utf-8').splitlines() if x.startswith('USAGE_REPORT_URL =')]
            self.assertEqual(lines,[url])
        for name in ['NekoWidgetWidget/Info.plist','NekoWidgetShareExtension/Info.plist']:
            self.assertNotIn('UsageReportURL',plistlib.loads((ROOT/name).read_bytes()))
if __name__=='__main__':unittest.main()
