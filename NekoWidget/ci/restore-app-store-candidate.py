"""Extract only the three files needed from a verified release artifact."""

import argparse
import plistlib
import shutil
import tarfile
import zipfile
from pathlib import Path

from production_candidate import require, verify_export


def extract_candidate(bundle, output, build):
    with tarfile.open(bundle, "r:gz") as archive:
        members = archive.getmembers()
        names = [member.name for member in members]
        require(len(names) == len(set(names)), "Duplicate release archive member")
        payloads = [
            member for member in members
            if Path(member.name).parts[:1] == ("Export",)
            and len(Path(member.name).parts) == 2
            and member.name.endswith(".ipa")
        ]
        require(len(payloads) == 1, "Expected one exported IPA")
        output.mkdir(mode=0o700)
        files = (
            (payloads[0], "NekoWidget.ipa", 1024**3),
            (archive.getmember("production-candidate.json"), "production-candidate.json", 32_768),
            (archive.getmember("ExportOptions.plist"), "ExportOptions.plist", 32_768),
        )
        for member, name, limit in files:
            require(member.isfile() and 0 < member.size <= limit, "Invalid release archive member")
            with archive.extractfile(member) as source, (output / name).open("xb") as target:
                shutil.copyfileobj(source, target)

    verify_export(plistlib.loads((output / "ExportOptions.plist").read_bytes()))
    with zipfile.ZipFile(output / "NekoWidget.ipa") as ipa:
        product = "Payload/NekoWidget.app/Info.plist"
        require(ipa.namelist().count(product) == 1 and ipa.getinfo(product).file_size <= 1_000_000,
                "Unexpected candidate Info.plist")
        info = plistlib.loads(ipa.read(product))
    require(info.get("CFBundleIdentifier") == "jp.nekowidget.app"
            and info.get("CFBundleShortVersionString") == "1.0"
            and info.get("CFBundleVersion") == build, "Unexpected App Store candidate identity")
    require(info.get("AppStorePagePublished") == "YES"
            and info.get("ITSAppUsesNonExemptEncryption") is False, "App Store or export compliance setting differs")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("build")
    args = parser.parse_args()
    extract_candidate(args.bundle, args.output, args.build)
