import Foundation

// 機種変更の画面：状態ごとに「どのボタンが出て、押したら何を呼ぶか」を固定する。
// 通信はしない。送るものは Codex の型（nextAction・freshGenerationChoice）が決める。

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(description: message) }
}

@main
enum GroupRecoveryPresentationVerifier {
    static let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    static func screen(_ state: GroupRecoveryRegistrationState) throws -> GroupRecoveryPresentation {
        guard let screen = GroupRecoveryPresentation.make(for: state) else {
            throw Failure(description: "no screen for \(state)")
        }
        return screen
    }

    static func main() throws {
        // ready：画面は出さない（閉じて、まどを開く）。一覧にも出さない。
        let ready = GroupRecoveryRegistrationState.ready(operationID: id, deviceID: "d")
        try check(GroupRecoveryPresentation.make(for: ready) == nil, "ready has no screen")
        try check(GroupRecoveryPresentation.rowStatus(for: ready) == nil, "ready is not listed")
        try check(ready.nextAction == .complete, "ready opens the window")

        // 確かめ中：押すものは出さない（二重の問い合わせにしない）。
        let checking = try screen(.checking(operationID: id))
        try check(checking.title == GroupRecoveryWords.checkingTitle && checking.icon == .progress, "checking words")
        try check(checking.primary == nil && checking.secondary == nil, "checking has no buttons")

        // 通信できない：［もう一度］は同じ手続きの問い合わせだけ。登録なしとは扱わない。
        let disabled = try screen(.serverDisabled(operationID: id))
        try check(disabled.title == "機種変更の確認はいま使えません" && disabled.message == nil
                  && disabled.primary == nil && disabled.secondary == nil, "disabled is one line")
        let unavailable = try screen(.unavailable(operationID: id))
        try check(unavailable.primary == GroupRecoveryButton(title: "もう一度", step: .send(.perform(.queryStatus(id)))),
                  "retry queries the same operation")
        try check(unavailable.secondary == nil, "retry is the only button")

        // 前のまどが見つかった：［続ける］は同じ手続きを送る、［今はしない］は何も送らない。
        let found = try screen(.notStarted(operationID: id))
        try check(found.primary == GroupRecoveryButton(title: "続ける", step: .send(.perform(.submitSameOperation(id)))),
                  "continue submits the same operation")
        try check(found.secondary == GroupRecoveryButton(title: "今はしない", step: .send(.dismiss)), "not now sends nothing")

        // 登録済み・待つ：ボタンなし（閉じるだけ）。期限なし。
        let waiting = try screen(.registeredWaitingForKeys(operationID: id, deviceID: "d"))
        try check(waiting.primary == nil && waiting.secondary == nil, "waiting has no buttons")

        // 1 人のまど・前の端末なし：［新しく続ける］は名前の欄へ進むだけ。何も送らない。
        let noProvider = GroupRecoveryRegistrationState.noKeyProvider(operationID: id, deviceID: "d")
        let noProviderScreen = try screen(noProvider)
        try check(noProviderScreen.primary == GroupRecoveryButton(title: "新しく続ける", step: .askFreshName),
                  "fresh continue only opens the name step")
        try check(noProviderScreen.secondary?.step == .send(.dismiss), "not now sends nothing")
        // 名前を入れて［続ける］を押したときだけ、準備の提案になる。
        try check(GroupRecoveryActions.freshGeneration(noProvider, newName: "") == nil, "empty name sends nothing")
        try check(GroupRecoveryActions.freshGeneration(noProvider, newName: "  \n") == nil, "blank name sends nothing")
        try check(GroupRecoveryActions.freshGeneration(noProvider, newName: String(repeating: "あ", count: 27)) == nil,
                  "too long name sends nothing")
        try check(GroupRecoveryActions.freshGeneration(noProvider, newName: " 新しいまど ")
                    == .perform(.prepareFreshGeneration(id, newName: "新しいまど")), "trimmed name prepares")
        for other in [GroupRecoveryRegistrationState.notStarted(operationID: id), .deviceLimit(operationID: id),
                      .needsOriginalDeviceOrInvitation(operationID: id), .revoked(operationID: id),
                      .registeredWaitingForKeys(operationID: id, deviceID: "d")] {
            try check(GroupRecoveryActions.freshGeneration(other, newName: "新しいまど") == nil,
                      "fresh generation only from noKeyProvider: \(other)")
        }

        // 前の iPhone か招待が必要：ボタンなし（× で閉じる）。新しい本人は作らない。
        let needs = try screen(.needsOriginalDeviceOrInvitation(operationID: id))
        try check(needs.primary == nil && needs.secondary == nil, "needs original has no buttons")

        // 3 台まで：一覧から選んで確認したときだけ、その端末を外す。自動では外さない。
        let limit = GroupRecoveryRegistrationState.deviceLimit(operationID: id)
        let limitScreen = try screen(limit)
        try check(limitScreen.layout == .deviceList && limitScreen.primary == nil, "device limit is a list")
        try check(GroupRecoveryActions.removeDevice(limit, deviceID: "old") == .removeDevice(operationID: id, deviceID: "old"),
                  "remove the chosen device")
        try check(GroupRecoveryActions.removeDevice(limit, deviceID: "") == nil, "no device, nothing sent")
        try check(GroupRecoveryActions.removeDevice(.notStarted(operationID: id), deviceID: "old") == nil,
                  "removing only at the limit")

        // 退会・削除・失効：ボタンなし。やり直しで戻さない。
        let revoked = try screen(.revoked(operationID: id))
        try check(revoked.primary == nil && revoked.secondary == nil, "revoked has no buttons")

        // 本人が 2 つ：選んで確認したときだけ。候補にないもの・1 つだけのときは送らない。
        let a = GroupRecoveryRootCandidate(summary: .init(rootID: "a", windowIDs: ["w1"], notebookIDs: []),
                                           openableWindowNames: ["うちの猫"])
        let b = GroupRecoveryRootCandidate(summary: .init(rootID: "b", windowIDs: [], notebookIDs: []),
                                           openableWindowNames: [])
        let choose = GroupRecoveryPresentation.make(for: .chooseRoot([a, b]))
        try check(choose?.layout == .rootChoice && choose?.title == "どちらを使いますか", "root choice screen")
        try check(GroupRecoveryActions.chooseRoot([a, b], rootID: "b") == .chooseRoot("b"), "choose the picked root")
        try check(GroupRecoveryActions.chooseRoot([a, b], rootID: "c") == nil, "unknown root sends nothing")
        try check(GroupRecoveryActions.chooseRoot([a], rootID: "a") == nil, "one root is not a choice")

        // 入っている所の言い方（作った日や順番では選ばせない）。
        try check(a.text == "みんなのまど『うちの猫』に入っている", a.text)
        try check(b.text == "まだどこにも入っていない", b.text)
        try check(GroupRecoveryWords.describe(windowCount: 1, openableWindowNames: [], inFamilyNotebook: false)
                    == "まど 1 つに入っている", "unopenable window is counted")
        try check(GroupRecoveryWords.describe(windowCount: 3, openableWindowNames: ["実家"], inFamilyNotebook: true)
                    == "みんなのまど『実家』ほか 2 つ・家族の手帳に入っている", "several windows and the notebook")

        // まどが複数：名前が開けなければ「まど」。2 行目は画面の見出しと同じ言葉。
        let unnamed = GroupRecoveryWindowItem(windowID: "w", name: nil, state: .notStarted(operationID: id))
        try check(unnamed.displayName == "まど", "unnamed window")
        try check(GroupRecoveryPresentation.rowStatus(for: .notStarted(operationID: id)) == "前の iPhone のまどがあります",
                  "row status reuses the title")

        // 11/19（機種変更 水準2）：家族の手帳の行。続けるかを聞いて、待つ間は 1 行だけ。
        let notebookFound = GroupRecoveryPresentation.make(for: .notebook(.notStarted(operationID: id)))
        try check(notebookFound?.title == "家族の手帳" && notebookFound?.message == "この iPhone でも続けますか。",
                  "notebook asks to continue")
        try check(notebookFound?.primary?.step == .send(.perform(.submitSameOperation(id))), "continue registers the same operation")
        try check(notebookFound?.secondary?.step == .send(.dismiss), "not now sends nothing")
        let notebookWaiting = GroupRecoveryPresentation.make(for: .notebook(.registeredWaitingForKeys(operationID: id, deviceID: "new")))
        try check(notebookWaiting?.title == "家族の誰かがアプリを開くと戻ります" && notebookWaiting?.message == nil
                  && notebookWaiting?.primary == nil && notebookWaiting?.secondary == nil, "notebook waiting is one line")
        try check(GroupRecoveryPresentation.make(for: .notebook(.ready(operationID: id, deviceID: "new"))) == nil, "notebook ready closes")
        try check(GroupRecoveryPresentation.make(for: .notebook(.unavailable(operationID: id)))
                  == GroupRecoveryPresentation.make(for: .unavailable(operationID: id)), "other notebook states are the window's")
        let notebookRow = GroupRecoveryWindowItem(windowID: "notebook-x", name: nil,
            state: .registeredWaitingForKeys(operationID: id, deviceID: "new"), notebook: true)
        try check(notebookRow.displayName == "家族の手帳" && notebookRow.screenState == .notebook(notebookRow.state)
                  && GroupRecoveryPresentation.rowStatus(for: notebookRow) == "家族の誰かがアプリを開くと戻ります", "notebook row")

        print("Group recovery presentation verifier passed")
    }
}
