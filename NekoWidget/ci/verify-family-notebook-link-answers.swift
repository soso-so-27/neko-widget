import Foundation

// 11/20: the answers to 「同じ子ですか」 after deleting the app.
// UserDefaults is wiped; the device-only Keychain keeps a copy
// (FamilyCatLinkAnswersMemory) of the answers that left no link.
// Synthetic family and cat IDs and an in-memory Keychain only; no network.

private enum Failure: Error { case check(String) }
private func check(_ value: Bool, _ message: String) throws { if !value { throw Failure.check(message) } }

/// One Keychain service in memory; `failing` stands for a Keychain error.
private final class SyntheticKeychain: GroupSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Data] = [:]
    private var writeCount = 0
    var failing = false
    var values: [String: Data] { lock.lock(); defer { lock.unlock() }; return stored }
    var writes: Int { lock.lock(); defer { lock.unlock() }; return writeCount }
    func read(_ account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if failing { throw GroupClientError.authenticationRequired }; return stored[account]
    }
    func write(_ data: Data, account: String, createOnly: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if failing { throw GroupClientError.authenticationRequired }; writeCount += 1; stored[account] = data
    }
    func accounts(prefix: String) throws -> [String] { lock.lock(); defer { lock.unlock() }; return stored.keys.filter { $0.hasPrefix(prefix) } }
    func remove(_ account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failing { throw GroupClientError.authenticationRequired }; stored.removeValue(forKey: account)
    }
}

@main private enum VerifyFamilyNotebookLinkAnswers {
    /// FamilyNotebookCatLink.answerKey's shape (family:cat, lowercased).
    static func key(_ family: UUID, _ cat: UUID) -> String { family.uuidString.lowercased() + ":" + cat.uuidString.lowercased() }

    static func main() {
        do {
            var defaults: [String]?
            var keychain: SyntheticKeychain? = SyntheticKeychain()
            let memory = FamilyCatLinkAnswersMemory(defaults: { defaults }, setDefaults: { defaults = $0 }, keychain: { keychain })
            let family = UUID(), other = key(family, UUID()), same = key(family, UUID()), unlinked = key(family, UUID())
            var checked = false
            try check(memory.restore(checked: &checked) { _ in true } == [] && keychain?.writes == 0, "nothing answered, nothing written")

            // 「べつの子」, 「同じ子」.
            memory.remember(other, linked: false)
            memory.remember(same, linked: true)
            try check(Set(defaults ?? []) == [other, same] && defaults == defaults?.sorted(), "UserDefaults holds both answers, sorted")
            try check(FamilyCatLinkAnswersMemory.keys(keychain?.values[FamilyCatLinkAnswersMemory.account]) == [other],
                      "the Keychain keeps 「べつの子」 only: the 「同じ子」 link goes with the app")
            let writes = keychain?.writes ?? 0
            memory.remember(other, linked: false)
            try check(keychain?.writes == writes && (defaults ?? []).count == 2, "the same answer again writes nothing")

            // Deleting the app: UserDefaults is gone; a new process works out the questions.
            defaults = nil; checked = false
            try check(memory.restore(checked: &checked) { _ in true } == [other] && defaults == [other],
                      "「べつの子」 comes back after a reinstall, 「同じ子」 is asked again")
            _ = memory.restore(checked: &checked) { _ in true }
            try check(keychain?.writes == writes, "restoring writes nothing to the Keychain, and once per process")

            // 「つながりを外す」 on a linked cat (already answered): kept from now on.
            memory.remember(same, linked: true)
            memory.remember(same, linked: false)
            try check(Set(FamilyCatLinkAnswersMemory.keys(keychain?.values[FamilyCatLinkAnswersMemory.account])) == [other, same],
                      "an unlinked cat is not asked again after a reinstall")
            // 「このiPhoneの子とつなぐ」 after 「べつの子」: linked, so the copy drops it.
            memory.remember(other, linked: true)
            try check(FamilyCatLinkAnswersMemory.keys(keychain?.values[FamilyCatLinkAnswersMemory.account]) == [same],
                      "a cat linked later is asked again after a reinstall")
            memory.remember(same, linked: true)
            try check(keychain?.values[FamilyCatLinkAnswersMemory.account] == nil, "nothing to keep: the Keychain item is removed")

            // An install from before the copy: answers in UserDefaults only; the
            // ones without a link are copied once, the linked one is not.
            keychain = SyntheticKeychain(); defaults = [other, same, unlinked].sorted(); checked = false
            try check(memory.restore(checked: &checked) { $0 != same } == [other, same, unlinked].sorted(), "UserDefaults unchanged")
            try check(Set(FamilyCatLinkAnswersMemory.keys(keychain?.values[FamilyCatLinkAnswersMemory.account])) == [other, unlinked]
                      && keychain?.writes == 1, "copied into the Keychain once, without the linked answer")
            for _ in 0..<3 { _ = memory.restore(checked: &checked) { _ in true } }
            try check(keychain?.writes == 1, "later restores in the process touch only UserDefaults")
            checked = false
            _ = memory.restore(checked: &checked) { $0 != same }
            try check(keychain?.writes == 1, "a new process with nothing new writes nothing")

            // A failing Keychain: the answer still holds in UserDefaults, the copy is untouched.
            let before = keychain?.values[FamilyCatLinkAnswersMemory.account]
            keychain?.failing = true
            let late = key(family, UUID())
            memory.remember(late, linked: false)
            try check(defaults?.contains(late) == true, "UserDefaults holds the answer")
            defaults = nil; checked = false
            try check(memory.restore(checked: &checked) { _ in true } == [] && defaults == nil, "an unreadable Keychain restores nothing")
            keychain?.failing = false
            try check(keychain?.values[FamilyCatLinkAnswersMemory.account] == before, "the failing Keychain was not overwritten")

            // No Keychain at all (review captures): UserDefaults only.
            keychain = nil; defaults = nil; checked = false
            memory.remember(other, linked: false)
            try check(defaults == [other] && memory.restore(checked: &checked) { _ in true } == [other], "UserDefaults only")

            // Bound: the newest `limit` answers, the oldest dropped first.
            keychain = SyntheticKeychain(); defaults = nil
            let many = (0..<(FamilyCatLinkAnswersMemory.limit + 5)).map { _ in key(family, UUID()) }
            for answer in many { memory.remember(answer, linked: false) }
            let kept = FamilyCatLinkAnswersMemory.keys(keychain?.values[FamilyCatLinkAnswersMemory.account])
            try check(kept == Array(many.suffix(FamilyCatLinkAnswersMemory.limit)), "the newest \(FamilyCatLinkAnswersMemory.limit) answers are kept")
            try check((keychain?.values[FamilyCatLinkAnswersMemory.account]?.count ?? 0) < 16_000, "the item stays small")
            print("family notebook link answers: ok")
        } catch {
            print("family notebook link answers FAILED: \(error)")
            exit(1)
        }
    }
}
