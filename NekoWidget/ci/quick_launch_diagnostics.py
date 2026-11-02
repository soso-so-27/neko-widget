"""Small, private-data-free diagnostics for a fresh synthetic CI Simulator.

Never collect a Simulator data directory, full diagnose bundle, receipt,
Keychain, environment, crash report or unfiltered log message.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile

from production_candidate import fixture, require, verify_products

MAX_CAPTURE = 4 * 1024 * 1024
PHASES = ("before-launch", "after-launch", "before-retry", "after-retry")
ERROR_DOMAINS = ("FBSOpenApplicationServiceErrorDomain", "FBSOpenApplicationErrorDomain",
                 "RBSRequestErrorDomain", "RBSServiceErrorDomain", "NSPOSIXErrorDomain",
                 "NSCocoaErrorDomain", "NSMachErrorDomain")
TERMS = ("launch", "timeout", "timed out", "failed", "error", "denied", "terminated",
         "running", "foreground", "background", "scene", "assertion", "connection", "bootstrap")
PROCESS_NAMES = {"CoreSimulatorService", "com.apple.CoreSimulator.CoreSimulatorService",
                 "Simulator", "SpringBoard", "launchd_sim", "simdiskimaged"}


def command(args, timeout=5):
    try:
        result = subprocess.run(args, capture_output=True, timeout=timeout)
        if result.returncode != 0:
            return None, f"command-exit-{result.returncode}"
        if len(result.stdout) > MAX_CAPTURE:
            return None, "output-too-large"
        return result.stdout.decode("utf-8", errors="strict"), "ok"
    except subprocess.TimeoutExpired:
        return None, "diagnostic-timeout"
    except (OSError, UnicodeError):
        return None, "diagnostic-unavailable"


def simulator_state(payload, device):
    """Retain only this disposable device's state and its runtime identity."""
    rows = []
    for runtime, devices in payload.get("devices", {}).items():
        if not re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+", runtime):
            continue
        for row in devices:
            if row.get("udid") == device:
                state = row.get("state")
                rows.append({"udid": device, "runtime": runtime,
                             "state": state if state in ("Booted", "Shutdown", "Booting", "Shutting Down", "Creating") else "unknown",
                             "available": row.get("isAvailable") is True})
    return {"devices": rows}


def snapshot(output, device, phase):
    require(phase in PHASES, "Unknown snapshot phase")
    raw, status = command(["xcrun", "simctl", "list", "--json"])
    value = {"status": status, "devices": []}
    if raw is not None:
        try:
            value.update(simulator_state(json.loads(raw), device))
        except (TypeError, ValueError, AttributeError):
            value["status"] = "invalid-simctl-json"
    output.mkdir(parents=True, exist_ok=True)
    (output / f"simctl-list-{phase}.json").write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def springboard_events(payload):
    """Classify lifecycle logs without saving their arbitrary/free-text content."""
    require(isinstance(payload, list), "Expected structured log entries")
    result = []
    for row in payload:
        if not isinstance(row, dict):
            continue
        message = str(row.get("eventMessage", ""))
        process = str(row.get("processImagePath", "")).rsplit("/", 1)[-1]
        if process != "SpringBoard" or "jp.nekowidget.app" not in message:
            continue
        timestamp = str(row.get("timestamp", ""))
        timestamp = timestamp if re.fullmatch(r"[0-9T :.+Z-]{19,40}", timestamp) else "unavailable"
        kind = row.get("messageType")
        result.append({"timestamp": timestamp, "process": "SpringBoard",
                       "messageType": kind if kind in ("Default", "Error", "Fault", "Info", "Debug") else "unknown",
                       "terms": [term for term in TERMS if term in message.lower()],
                       "errorDomains": [domain for domain in ERROR_DOMAINS if domain in message],
                       "errorCodes": re.findall(r"\b[Cc]ode\s*[=:]\s*(-?[0-9]{1,5})\b", message)[:8]})
    return result[-200:]


def process_states(raw):
    result = []
    for line in raw.splitlines():
        match = re.fullmatch(r"\s*([0-9]+)\s+([A-Za-z+<>-]+)\s+(.+)", line)
        if match and match[3].rsplit("/", 1)[-1] in PROCESS_NAMES:
            result.append({"pid": int(match[1]), "state": match[2], "process": match[3].rsplit("/", 1)[-1]})
    return result


def archive_candidate(app, contract, destination):
    require(contract == fixture(), "Only the exact synthetic CI contract can be retained")
    require(app.name == "NekoWidget.app" and app.is_dir() and not app.is_symlink(), "Expected a built app directory")
    products = verify_products(app, contract, synthetic=True)
    require(all(info.get("CFBundleSupportedPlatforms") == ["iPhoneSimulator"] for info in products.values()), "Only Simulator products may be retained")
    forbidden_parts = {"documents", "library", "keychains", "_masreceipt", "storekit", "receipts"}
    forbidden_suffixes = {".p8", ".p12", ".pem", ".key", ".mobileprovision", ".storekit", ".receipt", ".sqlite", ".sqlite3", ".db"}
    total = 0
    for path in app.rglob("*"):
        relative = path.relative_to(app)
        require(not any(part.lower() in forbidden_parts or "receipt" in part.lower() for part in relative.parts)
                and path.suffix.lower() not in forbidden_suffixes, "Private/runtime material is not a build artifact")
        require(path.resolve().is_relative_to(app.resolve()), "App symlink escapes the built bundle")
        if path.is_file():
            total += path.stat().st_size
    require(total <= 256 * 1024 * 1024, "Synthetic app exceeds diagnostic size bound")
    # Preserve executable modes, symlinks, signatures and bytes for later install.
    with tarfile.open(destination, "w:gz", compresslevel=1) as archive:
        archive.add(app, arcname="NekoWidget.app")


def collect(output, snapshots, device, app, contract, exit_status):
    require(type(exit_status) is int and 1 <= exit_status <= 255, "Only failed checks may create a failure artifact")
    output.mkdir(parents=True, exist_ok=True)
    statuses = [f"Original quick-check exit status: {exit_status}"]
    # Reparse copied snapshots; never pick up arbitrary files from the directory.
    for phase in PHASES:
        path = snapshots / f"simctl-list-{phase}.json"
        if path.is_file():
            value = json.loads(path.read_text(encoding="utf-8"))
            require(set(value) == {"status", "devices"}, "Unexpected snapshot fields")
            status = value["status"]
            require(isinstance(status, str) and re.fullmatch(r"ok|diagnostic-timeout|diagnostic-unavailable|invalid-simctl-json|output-too-large|command-exit--?[0-9]{1,3}", status), "Unexpected snapshot status")
            payload = {"devices": {}}
            for row in value["devices"]:
                payload["devices"].setdefault(row["runtime"], []).append({"udid": row["udid"], "state": row["state"], "isAvailable": row["available"]})
            clean = {"status": status, **simulator_state(payload, device)}
            (output / path.name).write_text(json.dumps(clean, indent=2) + "\n", encoding="utf-8")
    archive_candidate(app, contract, output / "synthetic-simulator-app.tar.gz")
    predicate = 'process == "SpringBoard" AND eventMessage CONTAINS "jp.nekowidget.app"'
    raw, status = command(["xcrun", "simctl", "spawn", device, "log", "show", "--last", "3m",
                           "--style", "json", "--predicate", predicate], timeout=12)
    statuses.append("SpringBoard structured lifecycle log: " + status)
    if raw is not None:
        try:
            events = springboard_events(json.loads(raw))
        except (ValueError, TypeError):
            events = []
            statuses.append("SpringBoard log could not be parsed; raw output discarded")
        (output / "springboard-lifecycle.json").write_text(json.dumps(events, indent=2) + "\n", encoding="utf-8")
    raw, status = command(["ps", "-axo", "pid=,stat=,comm="])
    statuses.append("CoreSimulator process states: " + status)
    if raw is not None:
        (output / "simulator-processes.json").write_text(json.dumps(process_states(raw), indent=2) + "\n", encoding="utf-8")
    (output / "README.txt").write_text("\n".join(statuses) + "\n\n"
        "Synthetic Simulator build only; not signed for device distribution.\n"
        "No Simulator data containers, Photos library, Keychain, receipts or raw log messages are collected.\n"
        "Bundled artwork and the public synthetic fixture are part of the built app.\n"
        "On a compatible Mac Simulator, extract with: tar -xzf synthetic-simulator-app.tar.gz\n"
        "Then: xcrun simctl install <fresh-device-udid> NekoWidget.app\n"
        "Then: xcrun simctl launch <fresh-device-udid> jp.nekowidget.app\n"
        "These diagnostics do not turn the failed CI check into a pass.\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("snapshot", "collect"))
    parser.add_argument("--device", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--phase", choices=PHASES)
    parser.add_argument("--snapshots", type=Path)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--contract", type=Path)
    parser.add_argument("--exit-status", type=int)
    args = parser.parse_args()
    require(re.fullmatch(r"[A-Fa-f0-9-]{36}", args.device), "Expected a Simulator UDID")
    if args.command == "snapshot":
        snapshot(args.output, args.device, args.phase)
    else:
        collect(args.output, args.snapshots, args.device, args.app,
                json.loads(args.contract.read_text(encoding="utf-8")), args.exit_status)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Do not echo arbitrary parser/command payloads into the runner log.
        print("Launch diagnostic collection unavailable: " + type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
