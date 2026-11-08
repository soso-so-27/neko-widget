"""Run the production executor and editing lease against a synthetic fingerprint."""
from pathlib import Path
import sys
source = Path("NekoWidget/Services/AppRecordPersistence.swift").read_text(encoding="utf-8")
def block(start):
    a = source.index(start)
    return source[a:source.index("\n}", a) + 2]
observer = source[source.index("observer = NotificationCenter.default.addObserver(forName: .appRecordsCommitted"):source.index("datasetObserver =")]
assert "fingerprint(" not in observer
assert "@MainActor\nenum AppRecordCapture" not in source
program = """import Foundation
import Combine
enum AppRecordDataset {
    static let writeLock = NSRecursiveLock()
    static var reads = 0
    static func fingerprint() -> String {
        precondition(!Thread.isMainThread, "fingerprint must not run on the UI thread")
        reads += 1
        return "synthetic"
    }
}
extension Notification.Name { static let appRecordEditingFinished = Notification.Name("probe-finished") }
"""
program += next(line for line in source.splitlines() if line.startswith("enum AppRecordEditingError:")) + "\n"
program += block("final class AppRecordEditingLease:") + "\n"
program += block("enum AppRecordBackground {") + "\n"
program += """
@main struct Probe {
    @MainActor static func main() async throws {
        let lease = AppRecordEditingLease()
        lease.acquire()
        do { _ = try await AppRecordBackground.fingerprint(); fatalError("editing was not deferred") }
        catch AppRecordEditingError.inProgress { }
        precondition(AppRecordDataset.reads == 0)
        lease.release()
        let result = try await AppRecordBackground.fingerprint()
        precondition(result == "synthetic" && AppRecordDataset.reads == 1)
        print("AUTOSAVE_BACKGROUND PASS: no UI-thread fingerprint, lease defers then resumes")
    }
}
"""
Path(sys.argv[1]).write_text(program, encoding="utf-8")
