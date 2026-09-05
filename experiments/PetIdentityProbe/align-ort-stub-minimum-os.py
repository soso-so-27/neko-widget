"""Align ORT's copied framework metadata with Xcode's generated stub, before app signing."""
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import sys


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError("Invalid deployment version.")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def actual_minimum(output, deployment, expected_platform):
    versions = re.findall(r"^\s*minos\s+(\d+(?:\.\d+){0,2})\s*$", output, re.MULTILINE)
    platforms = re.findall(r"^\s*platform\s+(\S+)\s*$", output, re.MULTILINE)
    if (not versions or len(versions) != len(platforms)
            or expected_platform not in {"IOS", "IOSSIMULATOR"}
            or set(platforms) != {expected_platform}
            or any(version(value) != version(deployment) for value in versions)):
        raise ValueError("ORT stub platform/deployment does not match this iOS build.")
    return versions[0]


def main():
    if os.environ["PRODUCT_BUNDLE_IDENTIFIER"] != "jp.nekowidget.petidentityprobe":
        raise ValueError("Unexpected app target.")
    base = Path(os.environ["TARGET_BUILD_DIR"])
    if (not base.is_absolute() or base.resolve() == Path(base.anchor)
            or os.environ["FRAMEWORKS_FOLDER_PATH"] != "PetIdentityProbe.app/Frameworks"):
        raise ValueError("Unexpected build output.")
    app = base / "PetIdentityProbe.app"
    framework = app / "Frameworks/onnxruntime.framework"
    if any(path.is_symlink() for path in (base, app, app / "Frameworks", framework)):
        raise ValueError("Symlinked framework output is forbidden.")
    if not framework.exists():
        return
    if framework.resolve() != base.resolve() / "PetIdentityProbe.app/Frameworks/onnxruntime.framework":
        raise ValueError("Unexpected resolved framework path.")
    plist_path = framework / "Info.plist"
    binary = framework / "onnxruntime"
    if any(path.is_symlink() for path in framework.rglob("*")):
        raise ValueError("Symlinked framework content is forbidden.")
    with plist_path.open("rb") as stream:
        info = plistlib.load(stream)
    if (info.get("CFBundleIdentifier") != "com.microsoft.onnxruntime"
            or info.get("CFBundleExecutable") != binary.name
            or info.get("CFBundleShortVersionString") != "1.24.2"):
        raise ValueError("Unexpected ORT metadata.")
    result = subprocess.run(["xcrun", "vtool", "-show-build", str(binary)],
                            capture_output=True, text=True, check=True)
    platform = {"iphoneos": "IOS", "iphonesimulator": "IOSSIMULATOR"}[os.environ["PLATFORM_NAME"]]
    actual = actual_minimum(result.stdout, os.environ["IPHONEOS_DEPLOYMENT_TARGET"], platform)
    if (version(info.get("MinimumOSVersion")) not in {(15, 1, 0), version(actual)}
            or version(actual) < (15, 1, 0)):
        raise ValueError("Unexpected declared minimum OS; no metadata was changed.")
    info["MinimumOSVersion"] = actual
    plist_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
    if os.environ.get("CODE_SIGNING_ALLOWED") == "YES":
        identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY", "")
        if not re.fullmatch(r"[A-Fa-f0-9]{40}", identity):
            raise ValueError("The dedicated signing identity is unavailable.")
        command = ["codesign", "--force", "--sign", identity, "--timestamp=none"]
        flags = shlex.split(os.environ.get("OTHER_CODE_SIGN_FLAGS", ""))
        if flags and not (len(flags) == 2 and flags[0] == "--keychain"):
            raise ValueError("Unexpected framework signing flags.")
        command += flags
        subprocess.run([*command, str(framework)], capture_output=True, check=True)
    print("ORT copied framework minimum OS now matches its generated iOS stub.")


def self_test():
    assert actual_minimum("platform IOS\nminos 17.1\n", "17.1", "IOS") == "17.1"
    assert actual_minimum("platform IOSSIMULATOR\nminos 17.1.0\n", "17.1", "IOSSIMULATOR") == "17.1.0"
    for output in ("platform MACOS\nminos 17.1\n", "platform IOS\nminos 18.0\n",
                   "platform IOSSIMULATOR\nminos 17.1\n", ""):
        try:
            actual_minimum(output, "17.1", "IOS")
        except ValueError:
            continue
        raise AssertionError("Invalid platform/deployment passed")
    print("ORT stub deployment validation fixtures passed.")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        try:
            main()
        except (ValueError, OSError, KeyError, subprocess.SubprocessError):
            print("ORT stub metadata/signature alignment failed; no raw signing output was published.", file=sys.stderr)
            sys.exit(1)
