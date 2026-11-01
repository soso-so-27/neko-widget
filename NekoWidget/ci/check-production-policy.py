"""Read-only live public-page gate, bound to the reviewed candidate URLs/revision."""
import json
from pathlib import Path
import subprocess
import sys
from production_candidate import ROOT, require, settings

contract = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
values = settings(contract)  # Never accepts the CI-only synthetic contract.
privacy = values["APP_PRIVACY_URL"]
require(privacy.endswith("/privacy/"), "Reviewed policy site root is required")
base = privacy[:-len("privacy/")]
require(values["APP_SUPPORT_URL"] == base + "support/"
        and values["SHARING_COMMUNITY_STANDARDS_URL"] == base + "community/", "Public policy URLs differ from checked pages")
subprocess.run(["node", str(ROOT / "SharingService/scripts/check-public-policy-site.mjs"),
                "--profile", "public-1.0", "--site-base", base,
                "--expected-revision", contract["policyRevision"]], check=True)
