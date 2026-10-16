"""One-off, ready Simulator process sampling capability probe. Never release evidence."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import signal
import subprocess
import time

BASE = "9c7149f712e53c77f946095b6c8d6bdd8834fc57"
BRANCH = "refs/heads/diagnostic/automatic-membership-sampler-probe-20261016"
EXPECTED = {".github/workflows/ios-ui-diagnostic.yml", "NekoWidget/ci/diagnose-simulator-sampler.py"}


def command(args, timeout=15, check=True):
    started = time.monotonic()
    proc = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    result = {"args": args, "exit": proc.returncode, "seconds": time.monotonic() - started,
              "stdout": proc.stdout, "stderr": proc.stderr}
    if check and proc.returncode:
        raise RuntimeError(json.dumps(result))
    return result


def identity():
    source = os.environ["NEKO_SAMPLER_SOURCE"]
    if (__debug__ is False or os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
            or os.environ.get("GITHUB_REF") != BRANCH or os.environ.get("GITHUB_RUN_ATTEMPT") != "1"
            or re.fullmatch(r"[0-9a-f]{40}", source) is None or source != os.environ.get("GITHUB_SHA")
            or command(["git", "rev-parse", "HEAD"])["stdout"].strip() != source
            or command(["git", "rev-parse", "HEAD^"])["stdout"].strip() != BASE
            or command(["git", "status", "--porcelain", "--untracked-files=no"])["stdout"]):
        raise RuntimeError("Exact clean one-off diagnostic source required")
    changes = command(["git", "diff", "--raw", "--no-abbrev", BASE, source])["stdout"].splitlines()
    paths = set()
    for row in changes:
        metadata, path = row.split("\t")
        old_mode, new_mode, _, _, status = metadata[1:].split()
        if path not in EXPECTED or new_mode != "100644" or status not in ("A", "M"):
            raise RuntimeError("Only two ordinary diagnostic files may change")
        if old_mode not in ("000000", "100644"):
            raise RuntimeError("Unexpected source mode")
        paths.add(path)
    if paths != EXPECTED or platform.machine() != "arm64":
        raise RuntimeError("Unexpected source closure or runner architecture")
    return source


def metrics(pid, executable):
    result = command(["/bin/ps", "-ww", "-p", str(pid), "-o", "pid=,state=,rss=,comm="], timeout=10)
    parts = result["stdout"].strip().split(None, 3)
    result["identityAccepted"] = (len(parts) == 4 and parts[0] == str(pid)
                                  and not any(x in parts[1] for x in "TZ")
                                  and parts[3] == str(executable))
    return result


def sample(root, label, pid, executable, no_symbols=False):
    output = root / (label + ".sample.txt")
    before = metrics(pid, executable)
    if not before["identityAccepted"]:
        return {"label": label, "usable": False, "before": before}
    args = ["/usr/bin/sample", str(pid), "1", "-file", str(output)]
    if no_symbols:
        args.append("-noSymbols")
    started = time.monotonic()
    proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    timed_out = False
    try:
        stdout, stderr = proc.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        timed_out = True
        if proc.poll() is None and os.getpgid(proc.pid) == proc.pid:
            os.killpg(proc.pid, signal.SIGKILL)
        stdout, stderr = proc.communicate(timeout=5)
    elapsed = time.monotonic() - started
    (root / (label + ".command.txt")).write_text(stdout + "\nSTDERR:\n" + stderr, encoding="utf-8")
    after = metrics(pid, executable)
    size = output.stat().st_size if output.exists() else 0
    body = output.read_text(encoding="utf-8", errors="replace") if 0 < size <= 8 * 1024 * 1024 else ""
    valid = (re.search(r"^Process:.*\[" + str(pid) + r"\]", body, re.M) is not None
             and "Call graph:" in body and re.search(r"Thread[_ ]", body) is not None)
    return {"label": label, "pid": pid, "requestedSeconds": 1, "wallSeconds": elapsed,
            "exit": proc.returncode, "timedOut": timed_out, "sampleBytes": size,
            "noSymbols": no_symbols, "before": before, "after": after,
            "usable": not timed_out and proc.returncode == 0 and valid and after["identityAccepted"]}


def main():
    source = identity()
    run = os.environ["GITHUB_RUN_ID"]
    if re.fullmatch(r"[0-9]+", run) is None:
        raise RuntimeError("Invalid run identity")
    root = Path(os.environ["RUNNER_TEMP"]) / "neko-sampler-probe"
    root.mkdir(exist_ok=False)
    result = {"diagnosticOnly": True, "releaseEvidence": False, "source": source, "base": BASE,
              "run": run, "rootCommands": 0, "samples": [], "cleanup": []}
    simulator = None
    child = None
    bundle = "dev.nekonomado.samplercapability.r" + run
    nonce = run + "-" + source[:12]
    started = time.monotonic()
    try:
        help_result = command(["/usr/bin/sample", "-help"], timeout=10, check=False)
        (root / "sample-help.json").write_text(json.dumps(help_result, indent=2), encoding="utf-8")
        app = root / "NekoSamplerProbe.app"
        app.mkdir()
        swift = root / "Probe.swift"
        swift.write_text('''import UIKit
import SwiftUI
import Vision
final class Delegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: Text("Sampler capability probe"))
        window.makeKeyAndVisible()
        self.window = window
        DispatchQueue.main.async {
            let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("probe-ready.txt")
            let value = "\\(ProcessInfo.processInfo.processIdentifier)|\\(CommandLine.arguments.last ?? "")"
            try? Data(value.utf8).write(to: file, options: .atomic)
        }
        return true
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(Delegate.self))
''', encoding="utf-8")
        sdk = command(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])["stdout"].strip()
        result["compile"] = command(["xcrun", "--sdk", "iphonesimulator", "swiftc", "-swift-version", "5",
                                     "-target", "arm64-apple-ios18.0-simulator", "-sdk", sdk,
                                     str(swift), "-o", str(app / "NekoSamplerProbe")], timeout=90)
        with (app / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": bundle, "CFBundleExecutable": "NekoSamplerProbe",
                          "CFBundleName": "NekoSamplerProbe", "CFBundlePackageType": "APPL",
                          "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
                          "LSRequiresIPhoneOS": True, "MinimumOSVersion": "18.0", "UIDeviceFamily": [1],
                          "UILaunchScreen": {}, "CFBundleSupportedPlatforms": ["iPhoneSimulator"]}, stream)
        result["sign"] = command(["/usr/bin/codesign", "--force", "--sign", "-", str(app)])
        created = command(["xcrun", "simctl", "create", "SamplerProbe-" + run,
                           "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro",
                           "com.apple.CoreSimulator.SimRuntime.iOS-18-6"])["stdout"].strip()
        if re.fullmatch(r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}", created) is None:
            raise RuntimeError("Invalid owned Simulator identity")
        simulator = created
        result["simulator"] = simulator
        command(["xcrun", "simctl", "boot", simulator])
        result["boot"] = command(["xcrun", "simctl", "bootstatus", simulator, "-b"], timeout=90)
        command(["xcrun", "simctl", "install", simulator, str(app)], timeout=30)
        launched = command(["xcrun", "simctl", "launch", simulator, bundle, nonce])["stdout"].strip()
        matched = re.fullmatch(re.escape(bundle) + r": ([1-9][0-9]*)", launched)
        if matched is None:
            raise RuntimeError("Unexpected launch identity")
        pid = int(matched[1])
        containers = {}
        for kind in ("app", "data"):
            path = Path(command(["xcrun", "simctl", "get_app_container", simulator, bundle, kind])["stdout"].strip()).resolve()
            expected_component = "/" + simulator + "/data/Containers/" + ("Bundle" if kind == "app" else "Data") + "/Application/"
            if expected_component not in str(path):
                raise RuntimeError("Container outside owned Simulator")
            containers[kind] = path
        ready = containers["data"] / "Documents/probe-ready.txt"
        deadline = time.monotonic() + 30
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.25)
        if not ready.exists() or ready.read_text() != str(pid) + "|" + nonce:
            raise RuntimeError("App did not reach ready main run loop")
        executable = containers["app"] / "NekoSamplerProbe"
        result["ready"] = {"pid": pid, "nonce": nonce, "executable": str(executable), "metrics": metrics(pid, executable)}
        if not result["ready"]["metrics"]["identityAccepted"]:
            raise RuntimeError("Ready process identity/state mismatch")
        result["psAllBefore"] = command(["/bin/ps", "-ww", "-axo", "pid=,comm="], timeout=10)
        # Compare the same two processes serially and in parallel; sleep remains owned/alive throughout.
        child = subprocess.Popen(["/bin/sleep", "180"])
        targets = [("app", pid, executable), ("sleep", child.pid, Path("/bin/sleep"))]
        for name, target_pid, target_executable in targets:
            result["samples"].append(sample(root, "serial-" + name, target_pid, target_executable))
        with ThreadPoolExecutor(max_workers=2) as pool:
            result["samples"].extend(pool.map(lambda target: sample(root, "parallel-" + target[0], target[1], target[2]), targets))
        if "-noSymbols" in help_result["stdout"] + help_result["stderr"]:
            result["samples"].append(sample(root, "serial-app-no-symbols", pid, executable, no_symbols=True))
        result["psAllAfter"] = command(["/bin/ps", "-ww", "-axo", "pid=,comm="], timeout=10)
    except Exception as error:
        result["error"] = type(error).__name__ + ": " + str(error)
    finally:
        if child is not None and child.poll() is None:
            try:
                child.terminate()
                child.wait(timeout=5)
                result["cleanup"].append({"ownedSleep": child.pid, "terminated": True})
            except Exception as error:
                result["cleanup"].append({"ownedSleep": child.pid, "error": str(error)})
        if simulator is not None:
            for args in (["xcrun", "simctl", "terminate", simulator, bundle], ["xcrun", "simctl", "shutdown", simulator]):
                try:
                    result["cleanup"].append(command(args, timeout=15, check=False))
                except Exception as error:
                    result["cleanup"].append({"args": args, "error": str(error)})
        result["seconds"] = time.monotonic() - started
        result["serialReadyAppUsable"] = any(item["label"] == "serial-app" and item["usable"] for item in result["samples"])
        (root / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: result.get(key) for key in ("source", "seconds", "serialReadyAppUsable", "error", "samples")}))
    return 0 if result["serialReadyAppUsable"] and "error" not in result else 2


if __name__ == "__main__":
    raise SystemExit(main())
