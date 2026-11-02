"""Read Xcode settings twice; no build, simulator boot, app launch or cloud access."""
import json
import os
from pathlib import Path
import subprocess
import production_candidate as candidate


def main():
    root = Path(os.environ["RUNNER_TEMP"])
    expected = candidate.settings(candidate.fixture(), synthetic=True)
    base = ["xcodebuild", "-project", "NekoWidget.xcodeproj", "-scheme", "NekoWidget",
            "-configuration", "Release", "-sdk", "iphonesimulator",
            "-destination", "generic/platform=iOS Simulator",
            "-derivedDataPath", str(root / "PublicIPadProbe"),
            "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "AD_HOC_CODE_SIGNING_ALLOWED=YES",
            "ONLY_ACTIVE_ARCH=YES", "SWIFT_OPTIMIZATION_LEVEL=-Onone", "SWIFT_COMPILATION_MODE=singlefile"]
    base += [f"{key}={value}" for key, value in expected.items()]
    output = []
    for label, extra in (("with-coverage", ["-enableCodeCoverage", "NO"]), ("without-coverage", [])):
        command = base + extra + ["-showBuildSettings", "-json"]
        result = subprocess.run(command, cwd=candidate.ROOT, capture_output=True, text=True, timeout=90)
        output.append(f"=== {label}: exit {result.returncode} ===")
        output.append("stderr: " + result.stderr)
        if result.returncode == 0:
            rows = json.loads(result.stdout)
            for row in rows:
                settings = row["buildSettings"]
                output.append(json.dumps({"target": row["target"], "settings": {
                    key: settings.get(key) for key in ("CONFIGURATION", "SDKROOT", "TARGETED_DEVICE_FAMILY",
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS", "OTHER_SWIFT_FLAGS", "INTERNAL_PRESENTATION_CONDITION")
                }}, ensure_ascii=False))
        else:
            output.append("stdout: " + result.stdout)
        text = "\n".join(output)
        (root / "ipad-settings-probe.txt").write_text(text, encoding="utf-8")
    print("\n".join(output))
    print("Observation only: no application test or release check has run.")


if __name__ == "__main__":
    main()
