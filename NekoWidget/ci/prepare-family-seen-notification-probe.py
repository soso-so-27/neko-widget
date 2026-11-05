"""Exercise the actual UI model method with a synthetic snapshot and Combine."""
from pathlib import Path
import sys

source = Path('NekoWidget/Views/FamilyNotebookView.swift').read_text(encoding='utf-8')
start = source.index('    func markSeen() {')
end = source.index('\n    }', start) + len('\n    }')
method = source[start:end]
program = '''import Foundation
import Combine
@MainActor final class Probe: ObservableObject {
    struct Snapshot { let clock: UInt64 }
    var snapshot: Snapshot? = Snapshot(clock: 5)
    let currentSeenKey = "synthetic.family.seen." + UUID().uuidString
    let objectWillChange = ObservableObjectPublisher()
METHOD
}
@main struct Check {
    @MainActor static func main() {
        let model = Probe()
        defer { UserDefaults.standard.removeObject(forKey: model.currentSeenKey) }
        var notifications = 0
        let token = model.objectWillChange.sink { notifications += 1 }
        model.markSeen()
        precondition(notifications == 1)
        for _ in 0..<100 { model.markSeen() }
        precondition(notifications == 1, "identical seen clock must not notify")
        model.snapshot = .init(clock: 6)
        model.markSeen()
        precondition(notifications == 2, "changed seen clock must notify")
        precondition(UserDefaults.standard.integer(forKey: model.currentSeenKey) == 6)
        model.snapshot = nil
        model.markSeen()
        precondition(notifications == 2)
        withExtendedLifetime(token) {}
        print("Family seen notifications: 100 unchanged calls = 0, changed clocks = 2")
    }
}
'''.replace('METHOD', method)
Path(sys.argv[1]).write_text(program, encoding='utf-8')
