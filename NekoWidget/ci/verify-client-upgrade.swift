import Foundation

@main struct VerifyClientUpgrade {
    static func main() throws {
        let exact = Data(#"{"error":{"code":"CLIENT_UPGRADE_REQUIRED"}}"#.utf8)
        let other = Data(#"{"error":{"code":"SERVICE_UNAVAILABLE"}}"#.utf8)
        let state = ClientUpgradeRequirement()
        for (status, body) in [(503, exact), (401, exact), (426, other), (426, Data()), (426, Data(repeating: 32, count: 16_385))] {
            try state.checkResponse(status: status, data: body)
            precondition(!state.isRequired)
            try state.checkAllowed()
        }
        do {
            try state.checkResponse(status: 426, data: exact)
            preconditionFailure("Exact 426 must be terminal")
        } catch let error as ClientUpgradeRequiredError {
            precondition(error.errorDescription == "新しいバージョンにアップデートしてください。")
        }
        var dispatched = 0
        for _ in 0..<3 {
            do { try state.checkAllowed(); dispatched += 1 }
            catch is ClientUpgradeRequiredError { }
        }
        precondition(state.isRequired && dispatched == 0, "Retries must stop before network dispatch")
        precondition(AppStoreListing.pageURL == nil, "Pre-release must not offer a missing store page")
        print("Client upgrade: exact response, ordinary errors, local retry stop, unpublished listing PASS")
    }
}
