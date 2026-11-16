#!/usr/bin/env python3
"""11/16: the app stopped (no crash, no input) right after a vaccine was
written to a family cat, while the この子 pages were swiped.

The family sync is an actor (off the main thread). Its receive/acknowledge
writes go through FamilyNotebookStore.transaction, which held the record
write lock and the notebook lock while it posted `.appRecordsCommitted`.
An observer added with `queue: .main` makes that post wait until the main
thread runs it. When the main thread was itself waiting for one of those
locks (CatCareStore.update, FamilyNotebookStore.snapshot), neither moved.

Fixed at the root, two ways, both checked here:
- the notebook's notice is posted after both locks are released;
- no observer of the record notices waits on a queue (queue nil, then a
  main-actor Task, as the other observers already do).
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "NekoWidget"


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8").replace("\r\n", "\n")


def function(source: str, signature: str) -> str:
    start = source.index(signature)
    depth = 0
    for index in range(source.index("{", start), len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError(signature)


STORE = read("NekoWidget/Services/FamilyNotebookStore.swift")
NOTICES = ("appRecordsCommitted", "appRecordDatasetChanged", "appRecordEditingFinished")


class RecordCommitNoticeHangTests(unittest.TestCase):
    def test_notebook_notice_is_posted_after_the_locks(self) -> None:
        transaction = function(STORE, "private func transaction<T>(")
        locked = function(STORE, "private func lockedTransaction<T>(")
        self.assertIn("AppRecordDataset.committed(stateURL)", transaction)
        self.assertNotIn("lock()", transaction)
        self.assertIn("try lockedTransaction(", transaction)
        self.assertNotIn("committed(", locked)
        self.assertIn("AppRecordDataset.writeLock.lock(); defer { AppRecordDataset.writeLock.unlock() }", locked)
        self.assertIn("Self.transactionLock.lock(); defer { Self.transactionLock.unlock() }", locked)
        # Told only when the file was written.
        self.assertIn("guard next != original else { return (result, false) }", locked)
        self.assertIn("if wrote { AppRecordDataset.committed(stateURL) }", transaction)
        self.assertEqual(STORE.count("AppRecordDataset.committed("), 1)

    def test_the_sync_writes_through_the_transaction_off_the_main_thread(self) -> None:
        sync = read("NekoWidget/Services/FamilyNotebookSync.swift")
        self.assertIn("actor FamilyNotebookSync", sync)
        self.assertIn("try store.receiveRetaining(incoming)", sync)
        self.assertIn("try store.acknowledge(", sync)

    def test_no_record_notice_observer_waits_on_a_queue(self) -> None:
        pattern = re.compile(r"addObserver\(\s*forName:\s*\.(\w+),[^)]*?queue:\s*([^)\s,]+)", re.S)
        found = []
        for path in APP.rglob("*.swift"):
            text = path.read_text(encoding="utf-8")
            for name, queue in pattern.findall(text):
                if name in NOTICES:
                    found.append((path.name, name, queue))
                    self.assertEqual(queue, "nil", f"{path.name}: .{name} observer must use queue nil")
        names = {(file, name) for file, name, _ in found}
        self.assertIn(("AppViewModel.swift", "appRecordsCommitted"), names)
        self.assertIn(("CatCareStore.swift", "appRecordDatasetChanged"), names)
        self.assertIn(("FamilyNotebookView.swift", "appRecordsCommitted"), names)
        # Combine publishers of the notices hop with receive(on:) / debounce,
        # which never make the poster wait.
        for path in APP.rglob("*.swift"):
            text = path.read_text(encoding="utf-8")
            for name in NOTICES:
                for match in re.finditer(r"publisher\(for: \." + name + r"\)", text):
                    following = text[match.end():match.end() + 400]
                    self.assertNotIn(".sink", following.split(".receive(on:")[0].split(".debounce(")[0],
                                     f"{path.name}: .{name} publisher must hop before it is handled")


if __name__ == "__main__":
    unittest.main()
