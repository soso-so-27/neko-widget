#!/usr/bin/env python3
"""Validate the real icon assets; optionally inspect/install the built app once."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import time

from app_icon_ci import ICON_PATHS, validate_png

ROOT = Path(__file__).resolve().parents[2]


def command(*args, timeout=60):
    result = subprocess.run(args, check=True, capture_output=True, text=True, timeout=timeout)
    return result.stdout.strip()


def timed_launch(stage, device, bundle, timeout, artifacts):
    started = time.monotonic()
    record = {"stage": stage, "timeoutSeconds": timeout, "startedAtUnix": time.time()}
    print(json.dumps({**record, "state": "started"}), flush=True)
    outcome = "failure"
    try:
        result = command("xcrun", "simctl", "launch", device, bundle, timeout=timeout)
        outcome = "success"
        return result
    except subprocess.TimeoutExpired:
        outcome = "timeout"
        raise
    finally:
        record.update(state=outcome, elapsedSeconds=round(time.monotonic() - started, 3))
        print(json.dumps(record), flush=True)
        if artifacts is not None:
            with (artifacts / "launch-stages.jsonl").open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(record) + "\n")


def prepare_with_preferences(device, artifacts=None):
    # Prepare the fresh Simulator with one system-app launch before Neko's
    # first launch. A failed preparation must not fall through to the app test.
    bundle = "com.apple.Preferences"
    # OS readiness has its own bounded budget, equal to bootstatus. This does
    # not extend Neko's first-launch deadline or retry either app launch.
    launch = timed_launch("simulator-readiness", device, bundle, 180, artifacts)
    match = re.fullmatch(r"com\.apple\.Preferences: ([1-9][0-9]*)", launch)
    if match is None:
        raise ValueError("Preferences preparation did not return its PID")
    pid = match.group(1)
    processes = command("xcrun", "simctl", "spawn", device, "launchctl", "list", timeout=10)
    if not any(len(fields := line.split()) >= 3 and fields[0] == pid
               and fields[2].startswith(f"UIKitApplication:{bundle}[") for line in processes.splitlines()):
        raise ValueError("Preferences preparation did not remain alive")
    command("xcrun", "simctl", "terminate", device, bundle, timeout=10)


def source_assets():
    records = {}
    for relative in sorted(ICON_PATHS):
        path = ROOT / relative
        if path.is_symlink() or not path.is_file():
            raise ValueError("Icon must be a regular file")
        data = path.read_bytes()
        validate_png(data)
        catalog = json.loads(path.with_name("Contents.json").read_text())
        if not any(image.get("filename") == path.name for image in catalog["images"]):
            raise ValueError("Asset catalog does not reference the icon")
        records[relative] = {"sha256": hashlib.sha256(data).hexdigest(), "size": [1024, 1024], "alpha": False}
    return records


def inspect_app(app, artifacts, report):
    # Reuse the existing Release products; incrementally add Simulator ad-hoc
    # signing with Xcode's real entitlements, not a hand-crafted codesign mask.
    derived = app.parents[3]
    build = subprocess.run(["xcodebuild", "-project", str(ROOT / "NekoWidget/NekoWidget.xcodeproj"),
        "-scheme", "NekoWidget", "-configuration", "Release", "-sdk", "iphonesimulator",
        "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", str(derived),
        "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "AD_HOC_CODE_SIGNING_ALLOWED=YES", "build"],
        capture_output=True, text=True, timeout=300)
    (artifacts / "simulator-signing.log").write_text(build.stdout + build.stderr)
    build.check_returncode()
    command("codesign", "--verify", "--deep", "--strict", str(app))
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info["CFBundleIcons"]["CFBundlePrimaryIcon"]["CFBundleIconName"] != "AppIcon":
        raise ValueError("Built app does not select AppIcon")
    assets = json.loads(command("xcrun", "--sdk", "iphonesimulator", "assetutil", "--info", str(app / "Assets.car")))
    names = {entry.get("Name") for entry in assets}
    if "AppIcon" not in names or "OnboardingAppIcon" not in names:
        raise ValueError("Compiled icon renditions are missing")
    report["compiledAssetNames"] = sorted(names & {"AppIcon", "OnboardingAppIcon"})
    runtimes = json.loads(command("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
    runtime = next((r["identifier"] for r in runtimes if r.get("isAvailable") and r.get("version") == "26.2"), None)
    if runtime is None:
        raise ValueError("Expected iOS 26.2 Simulator runtime is unavailable")
    device = command("xcrun", "simctl", "create", "NekoIconCheck", "com.apple.CoreSimulator.SimDeviceType.iPhone-16", runtime)
    if not re.fullmatch(r"[0-9A-Fa-f-]{36}", device):
        raise ValueError("Invalid created Simulator identity")
    try:
        command("xcrun", "simctl", "boot", device)
        command("xcrun", "simctl", "bootstatus", device, "-b", timeout=180)
        command("xcrun", "simctl", "status_bar", device, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100")
        command("xcrun", "simctl", "install", device, str(app))
        prepare_with_preferences(device, artifacts)
        report["preferencesPreparationAlive"] = True
        bundle = info["CFBundleIdentifier"]
        launch = timed_launch("neko-first-launch", device, bundle, 60, artifacts)
        pid = int(launch.rsplit(":", 1)[1].strip())
        time.sleep(5)
        processes = command("xcrun", "simctl", "spawn", device, "launchctl", "list")
        if not any(line.split() and line.split()[0] == str(pid) and bundle in line for line in processes.splitlines()):
            raise ValueError("Installed app exited before first-launch capture")
        command("xcrun", "simctl", "io", device, "screenshot", str(artifacts / "onboarding.png"))
        command("xcrun", "simctl", "terminate", device, bundle)
        time.sleep(2)
        command("xcrun", "simctl", "io", device, "screenshot", str(artifacts / "home-screen.png"))
        report.update({"runtime": runtime, "bundleIdentifier": bundle, "firstLaunchAlive": True,
                       "screenshots": ["onboarding.png", "home-screen.png"], "visualReview": "screenshots-require-review"})
    finally:
        # Only the freshly created, exact Simulator is removed. Never erase all.
        subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True, timeout=30)
        subprocess.run(["xcrun", "simctl", "delete", device], capture_output=True, timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    report = {"schemaVersion": 1, "commit": os.environ.get("GITHUB_SHA"), "assets": source_assets()}
    if args.app:
        if not args.artifacts:
            parser.error("--app requires --artifacts")
        args.artifacts.mkdir(parents=True, exist_ok=True)
        try:
            inspect_app(args.app, args.artifacts, report)
        finally:
            (args.artifacts / "icon-check.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
