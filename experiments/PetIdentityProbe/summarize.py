"""Extract aggregate synthetic-probe evidence; never label Simulator as device."""
import json
from pathlib import Path
import sys


def summarize(log):
    results = {}
    coreml_error = None
    for line in log.splitlines():
        for mode, prefix in (("cpu", "PROBE_CPU_JSON="), ("coreML", "PROBE_COREML_JSON=")):
            if prefix in line:
                value = json.loads(line.split(prefix, 1)[1])
                if value["platform"] != "simulator" or value["mode"] != mode:
                    raise ValueError("Unexpected probe platform/mode")
                if value["runtimeVersion"] != "1.24.2":
                    raise ValueError("Unexpected runtime")
                results[mode] = value
        if "PROBE_COREML_UNVERIFIED=" in line:
            coreml_error = line.split("PROBE_COREML_UNVERIFIED=", 1)[1]
    if "cpu" not in results or "PROBE_SMOKE_COMPLETE" not in log:
        raise ValueError("CPU probe did not finish")
    return {
        "scope": "synthetic_simulator_smoke_only",
        "device_performance_measured": False,
        "cat_accuracy_measured": False,
        "coreml_verified": "coreML" in results,
        "coreml_error": coreml_error,
        "results": results,
    }


if __name__ == "__main__":
    summary = summarize(Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace"))
    Path(sys.argv[2]).write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))
