"""Select the Ubuntu-only checks for changes outside the native app."""

import os
import re
import subprocess


PUBLIC_SITE_TEST = "NekoWidget/ci/test-public-policy-site.py"
SHARING_INPUT = re.compile(r"NekoWidget/SharingService/(?:src/.+\.ts|migrations/[^/]+\.sql|test/.+\.test\.ts)")


def git(*args):
    return subprocess.check_output(["git", *args], stderr=subprocess.DEVNULL).decode("utf-8")


def changed_paths(event, ref, before):
    if event not in ("push", "pull_request"):
        return set()

    try:
        # Include both ends when a path moves between the native and server trees.
        bases = []
        if before and before != "0" * 40:
            if not re.fullmatch(r"[0-9a-f]{40}", before):
                return set()
            git("merge-base", "--is-ancestor", before, "HEAD")
            bases.append(before)
        elif event == "pull_request" or ref == "refs/heads/main":
            return set()

        if event == "push" and ref != "refs/heads/main":
            # A small final push on a feature branch can still include app changes.
            bases.append(git("merge-base", "refs/remotes/origin/main", "HEAD").strip())

        return {
            path
            for base in set(bases)
            for path in git("diff", "--name-only", "--no-renames", "-z", base, "HEAD").split("\0")
            if path
        }
    except (subprocess.CalledProcessError, UnicodeDecodeError):
        return set()


def select_checks(paths):
    docs = False
    sharing = False
    for path in paths:
        if path.startswith("docs/") or path == PUBLIC_SITE_TEST:
            docs = True
        elif SHARING_INPUT.fullmatch(path):
            sharing = True
        else:
            return {"mac": True, "docs": False, "sharing": False}

    return {"mac": not (docs or sharing), "docs": docs, "sharing": sharing}


if __name__ == "__main__":
    paths = changed_paths(os.environ["GITHUB_EVENT_NAME"], os.environ["GITHUB_REF"], os.environ.get("BASE", ""))
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        for key, selected in select_checks(paths).items():
            print(f"{key}={str(selected).lower()}", file=output)
