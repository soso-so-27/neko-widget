#!/usr/bin/env python3
"""Validate the real icon assets; optionally inspect/install the built app once."""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import subprocess
import time
import zipfile

from app_icon_ci import ICON_PATHS, validate_png

ROOT = Path(__file__).resolve().parents[2]
REUSE_SOURCE = "94eacc38f5f50376af3d9a1a540d341777439f21"
REUSE_SHA256 = "f10616197ce24e995656da4a142f866619cb82b9f004f39b406e1c97fc13026e"
REUSE_BYTES = 30475789
REUSE_PATHS = {".github/workflows/ios-ui-diagnostic.yml", "NekoWidget/ci/verify-app-icon.py"}


def command(*args, timeout=60, artifacts=None, stage=None, check=True):
    if artifacts is None:
        result = subprocess.run(args, check=check, capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip()
    started = time.monotonic()
    def event(state, **extra):
        record = {"stage": stage, "state": state, "at": dt.datetime.now(dt.timezone.utc).isoformat(), **extra}
        with (artifacts / "stages.jsonl").open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(record) + "\n")
        print(json.dumps(record), flush=True)
    event("started", timeoutSeconds=timeout)
    stdout_path = artifacts / f"{stage}.stdout.log"
    stderr_path = artifacts / f"{stage}.stderr.log"
    try:
        # Write directly to files so timeout cannot discard partial output.
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            result = subprocess.run(args, check=check, stdout=stdout, stderr=stderr, text=True, timeout=timeout)
    except Exception as error:
        event("failed", errorType=type(error).__name__, elapsedSeconds=round(time.monotonic() - started, 3))
        raise
    event("completed", returncode=result.returncode, elapsedSeconds=round(time.monotonic() - started, 3))
    return stdout_path.read_text(encoding="utf-8", errors="replace").strip()


def collect_launch_failure(device, bundle, artifacts, run, include_control=False):
    # Collect only this fresh, empty Simulator. Every probe is bounded and no
    # probe failure may replace the original launch/assertion failure.
    def probe(stage, *args, timeout=10):
        try:
            return run(stage, *args, timeout=timeout)
        except Exception:
            return ""
    processes = probe("failure-processes", "xcrun", "simctl", "spawn", device, "launchctl", "list")
    predicate = 'process == "SpringBoard" OR process == "runningboardd" OR process == "NekoWidget"'
    probe("failure-system-log", "xcrun", "simctl", "spawn", device, "log", "show",
          "--last", "3m", "--style", "compact", "--predicate", predicate, timeout=15)
    probe("failure-screen", "xcrun", "simctl", "io", device, "screenshot", str(artifacts / "failure-screen.png"))
    probe("failure-host-log", "log", "show", "--last", "3m", "--style", "compact", "--predicate",
          'process == "simctl" OR process == "com.apple.CoreSimulator.CoreSimulatorService" OR subsystem BEGINSWITH "com.apple.CoreSimulator"', timeout=15)
    for line in processes.splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[0].isdigit() and fields[2].startswith(f"UIKitApplication:{bundle}["):
            probe("failure-app-sample", "sample", fields[0], "1", "1", "-file",
                  str(artifacts / "failure-app-sample.txt"), timeout=8)
            break
    if include_control:
        # One post-failure comparison, never a retry of the primary app. Its
        # outcome cannot make this diagnostic run successful.
        probe("control-preferences-launch", "xcrun", "simctl", "launch", device, "com.apple.Preferences", timeout=30)


def preserve_built_app(app, artifacts, info, runtime_info, run):
    archive = artifacts / "signed-simulator-app.zip"
    plist = (app / "Info.plist").read_bytes()
    (artifacts / "effective-Info.plist").write_bytes(plist)
    run("preserve-signed-app", "ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive))
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    metadata = {
        "diagnosticOnly": True, "releaseEvidence": False,
        "sourceSHA": run("source-sha", "git", "rev-parse", "HEAD", timeout=5),
        "sourceTree": run("source-tree", "git", "rev-parse", "HEAD^{tree}", timeout=5),
        "archive": archive.name, "sha256": digest, "bytes": archive.stat().st_size,
        "infoPlistSHA256": hashlib.sha256(plist).hexdigest(),
        "configuration": "Release", "signing": "Simulator ad-hoc, verified deep and strict",
        "bundleIdentifier": info["CFBundleIdentifier"],
        "runtime": {key: runtime_info.get(key) for key in ("identifier", "version", "buildversion")},
        "xcode": run("environment-xcode", "xcodebuild", "-version", timeout=10),
        "sdkBuild": run("environment-sdk", "xcrun", "--sdk", "iphonesimulator", "--show-sdk-build-version", timeout=10),
        "macOS": run("environment-macos", "sw_vers", timeout=10),
        "hostArchitecture": run("environment-architecture", "uname", "-m", timeout=10),
        "binaryArchitectures": run("binary-architectures", "lipo", "-archs", str(app / info["CFBundleExecutable"]), timeout=10),
    }
    (artifacts / "signed-app-provenance.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")


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


def reusable_diagnostic_app(directory, artifacts, run):
    # This is a single fixed diagnostic artifact, never a general build cache
    # or normal CI/release evidence source.
    if (os.environ.get("GITHUB_REPOSITORY") != "soso-so-27/neko-widget"
            or os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
            or os.environ.get("GITHUB_REF") != "refs/heads/diagnostic/icon-first-launch-20260921"):
        raise ValueError("App reuse is restricted to the fixed diagnostic workflow")
    head = run("reuse-checkout-sha", "git", "rev-parse", "HEAD", timeout=5)
    if head != os.environ.get("GITHUB_SHA") or head != os.environ.get("ICON_DIAGNOSTIC_SOURCE_SHA"):
        raise ValueError("Diagnostic checkout SHA mismatch")
    run("reuse-source-ancestor", "git", "merge-base", "--is-ancestor", REUSE_SOURCE, head, timeout=5)
    raw = run("reuse-source-diff", "git", "diff", "--raw", "--no-abbrev", "--no-renames", "-z", REUSE_SOURCE, head, timeout=5)
    records = raw.rstrip("\0").split("\0") if raw else []
    if len(records) % 2:
        raise ValueError("Invalid source tree comparison")
    seen = set()
    for index in range(0, len(records), 2):
        fields, path = records[index].split(), records[index + 1]
        if (len(fields) != 5 or fields[:2] != [":100644", "100644"] or fields[4] != "M"
                or path not in REUSE_PATHS or path in seen):
            raise ValueError("Only existing diagnostic verifier/workflow changes may reuse this app")
        seen.add(path)
    provenance = json.loads((directory / "signed-app-provenance.json").read_text(encoding="utf-8"))
    archive = directory / "signed-simulator-app.zip"
    if (archive.is_symlink() or archive.stat().st_size != REUSE_BYTES
            or provenance.get("sourceSHA") != REUSE_SOURCE
            or provenance.get("sourceTree") != run("reuse-source-tree", "git", "rev-parse", f"{REUSE_SOURCE}^{{tree}}", timeout=5)
            or provenance.get("sha256") != REUSE_SHA256 or provenance.get("bytes") != REUSE_BYTES
            or provenance.get("diagnosticOnly") is not True or provenance.get("releaseEvidence") is not False
            or provenance.get("configuration") != "Release" or provenance.get("bundleIdentifier") != "jp.nekowidget.app"):
        raise ValueError("Fixed app provenance mismatch")
    with archive.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != REUSE_SHA256:
            raise ValueError("Fixed signed app ZIP hash mismatch")
    with zipfile.ZipFile(archive) as bundle:
        for entry in bundle.infolist():
            path = PurePosixPath(entry.filename)
            if (path.is_absolute() or ".." in path.parts or "\\" in entry.filename
                    or not path.parts or path.parts[0] not in {"NekoWidget.app", "__MACOSX"}):
                raise ValueError("Unsafe app ZIP entry")
    destination = artifacts.parent / "icon-diagnostic-reused-products"
    destination.mkdir(exist_ok=False)
    run("reuse-extract", "ditto", "-x", "-k", str(archive), str(destination))
    app = destination / "NekoWidget.app"
    plist = (app / "Info.plist").read_bytes()
    if (hashlib.sha256(plist).hexdigest() != provenance.get("infoPlistSHA256")
            or plist != (directory / "effective-Info.plist").read_bytes()):
        raise ValueError("Extracted app Info.plist mismatch")
    info = plistlib.loads(plist)
    if info.get("CFBundleIdentifier") != "jp.nekowidget.app" or info.get("CFBundleExecutable") != "NekoWidget":
        raise ValueError("Extracted app identity mismatch")
    checks = {
        "xcode": ("xcodebuild", "-version"),
        "sdkBuild": ("xcrun", "--sdk", "iphonesimulator", "--show-sdk-build-version"),
        "macOS": ("sw_vers",), "hostArchitecture": ("uname", "-m"),
        "binaryArchitectures": ("lipo", "-archs", str(app / "NekoWidget")),
    }
    for key, args in checks.items():
        if run(f"reuse-environment-{key}", *args, timeout=10) != provenance.get(key):
            raise ValueError(f"Reused app environment mismatch: {key}")
    (artifacts / "effective-Info.plist").write_bytes(plist)
    (artifacts / "reused-app-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
    return app, provenance


def prepare_with_preferences(device, run):
    bundle = "com.apple.Preferences"
    launch = run("ready-preferences-launch", "xcrun", "simctl", "launch", device, bundle, timeout=30)
    match = re.fullmatch(r"com\.apple\.Preferences: ([1-9][0-9]*)", launch)
    if match is None:
        raise ValueError("Preferences preparation did not return its PID")
    pid = match.group(1)
    processes = run("ready-preferences-processes", "xcrun", "simctl", "spawn", device, "launchctl", "list", timeout=10)
    if not any(len(fields := line.split()) >= 3 and fields[0] == pid
               and fields[2].startswith(f"UIKitApplication:{bundle}[") for line in processes.splitlines()):
        raise ValueError("Preferences preparation did not remain alive")
    run("ready-preferences-terminate", "xcrun", "simctl", "terminate", device, bundle, timeout=10)


def inspect_app(app, artifacts, report, reuse_directory=None):
    def run(stage, *args, timeout=60, check=True):
        return command(*args, timeout=timeout, artifacts=artifacts, stage=stage, check=check)
    # Reuse the existing Release products; incrementally add Simulator ad-hoc
    # signing with Xcode's real entitlements, not a hand-crafted codesign mask.
    if reuse_directory is not None:
        app, provenance = reusable_diagnostic_app(reuse_directory, artifacts, run)
        report.update({"diagnosticOnly": True, "releaseEvidence": False, "reusedSourceSHA": REUSE_SOURCE, "reusedAppSHA256": REUSE_SHA256})
    else:
        derived = app.parents[3]
        run("simulator-signing", "xcodebuild", "-project", str(ROOT / "NekoWidget/NekoWidget.xcodeproj"),
            "-scheme", "NekoWidget", "-configuration", "Release", "-sdk", "iphonesimulator",
            "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", str(derived),
            "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "AD_HOC_CODE_SIGNING_ALLOWED=YES", "build", timeout=300)
    run("verify-signing", "codesign", "--verify", "--deep", "--strict", str(app))
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info["CFBundleIcons"]["CFBundlePrimaryIcon"]["CFBundleIconName"] != "AppIcon":
        raise ValueError("Built app does not select AppIcon")
    assets = json.loads(run("compiled-assets", "xcrun", "--sdk", "iphonesimulator", "assetutil", "--info", str(app / "Assets.car")))
    names = {entry.get("Name") for entry in assets}
    if "AppIcon" not in names or "OnboardingAppIcon" not in names:
        raise ValueError("Compiled icon renditions are missing")
    report["compiledAssetNames"] = sorted(names & {"AppIcon", "OnboardingAppIcon"})
    runtimes = json.loads(run("available-runtimes", "xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
    runtime_info = next((r for r in runtimes if r.get("isAvailable") and r.get("version") == "26.2"), None)
    if runtime_info is None:
        raise ValueError("Expected iOS 26.2 Simulator runtime is unavailable")
    runtime = runtime_info["identifier"]
    if reuse_directory is not None:
        if {key: runtime_info.get(key) for key in ("identifier", "version", "buildversion")} != provenance.get("runtime"):
            raise ValueError("Reused app runtime build mismatch")
    else:
        preserve_built_app(app, artifacts, info, runtime_info, run)
    device = run("create-simulator", "xcrun", "simctl", "create", "NekoIconCheck", "com.apple.CoreSimulator.SimDeviceType.iPhone-16", runtime)
    if not re.fullmatch(r"[0-9A-Fa-f-]{36}", device):
        raise ValueError("Invalid created Simulator identity")
    report.update({"runtime": runtime, "simulatorIdentifier": device, "bundleIdentifier": info["CFBundleIdentifier"]})
    failure = None
    launch_attempted = False
    bundle = info["CFBundleIdentifier"]
    try:
        run("boot", "xcrun", "simctl", "boot", device)
        run("bootstatus", "xcrun", "simctl", "bootstatus", device, "-b", timeout=180)
        run("status-bar", "xcrun", "simctl", "status_bar", device, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100")
        run("install", "xcrun", "simctl", "install", device, str(app))
        if reuse_directory is not None:
            prepare_with_preferences(device, run)
            report["preferencesPreparationAlive"] = True
        launch_attempted = True
        launch = run("launch", "xcrun", "simctl", "launch", device, bundle)
        pid = int(launch.rsplit(":", 1)[1].strip())
        time.sleep(5)
        processes = run("first-launch-processes", "xcrun", "simctl", "spawn", device, "launchctl", "list")
        if not any(line.split() and line.split()[0] == str(pid) and bundle in line for line in processes.splitlines()):
            raise ValueError("Installed app exited before first-launch capture")
        run("onboarding-screen", "xcrun", "simctl", "io", device, "screenshot", str(artifacts / "onboarding.png"))
        run("terminate", "xcrun", "simctl", "terminate", device, bundle)
        time.sleep(2)
        run("home-screen", "xcrun", "simctl", "io", device, "screenshot", str(artifacts / "home-screen.png"))
        report.update({"runtime": runtime, "bundleIdentifier": bundle, "firstLaunchAlive": True,
                       "screenshots": ["onboarding.png", "home-screen.png"], "visualReview": "screenshots-require-review"})
    except Exception as error:
        failure = error
        report["failureType"] = type(error).__name__
        try:
            collect_launch_failure(device, bundle, artifacts, run, include_control=launch_attempted and reuse_directory is None)
        except Exception:
            pass  # Diagnostics must preserve the original failure.
        raise
    finally:
        # Only the freshly created, exact Simulator is removed. Never erase all.
        cleanup_error = None
        for action in ("shutdown", "delete"):
            try:
                run(f"cleanup-{action}", "xcrun", "simctl", action, device, timeout=30, check=False)
            except Exception as error:
                cleanup_error = cleanup_error or error
        if failure is None and cleanup_error is not None:
            raise cleanup_error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--reuse-diagnostic-directory", type=Path)
    args = parser.parse_args()
    report = {"schemaVersion": 1, "commit": os.environ.get("GITHUB_SHA"), "assets": source_assets()}
    if args.app or args.reuse_diagnostic_directory:
        if not args.artifacts:
            parser.error("--app requires --artifacts")
        if args.app and args.reuse_diagnostic_directory:
            parser.error("Reused diagnostics must not supply a different app")
        args.artifacts.mkdir(parents=True, exist_ok=True)
        try:
            inspect_app(args.app, args.artifacts, report, reuse_directory=args.reuse_diagnostic_directory)
        finally:
            (args.artifacts / "icon-check.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
