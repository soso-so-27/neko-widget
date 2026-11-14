"""Keep the required launch check red unless a sequential attempt really passed."""
import json
import os


def passed(needs):
    if needs.get("quick-check", {}).get("result") != "success":
        return False
    complete = False
    for number in range(1, 4):
        job = needs.get(f"launch-attempt-{number}", {})
        if complete:
            if job.get("result") != "skipped":
                return False
            continue
        if job.get("result") != "success":
            return False
        result = job.get("outputs", {}).get("result")
        if result == "passed":
            complete = True
        elif result != "install_timeout":
            return False
    return complete


if __name__ == "__main__":
    state = json.loads(os.environ["LAUNCH_NEEDS"])
    ok = passed(state)
    print("Fresh runner launch: " + ("passed" if ok else "failed or exhausted"))
    raise SystemExit(0 if ok else 1)
