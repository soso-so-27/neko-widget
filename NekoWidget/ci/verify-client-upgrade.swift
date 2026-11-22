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
            precondition(error.errorDescription == "App Storeでアプリを最新にしてください。")
        }
        var dispatched = 0
        for _ in 0..<3 {
            do { try state.checkAllowed(); dispatched += 1 }
            catch is ClientUpgradeRequiredError { }
        }
        precondition(state.isRequired && dispatched == 0, "Retries must stop before network dispatch")
        precondition(AppStoreListing.pageURL == nil, "Pre-release must not offer a missing store page")
        precondition(AppStoreListing.pageURL(isPublished: false) == nil, "Ordinary builds hide the store link")
        precondition(AppStoreListing.pageURL(isPublished: true)?.absoluteString == "https://apps.apple.com/jp/app/id6801962436",
                     "Submission builds must use the fixed Japan store page")
        print("Client upgrade: exact response, local retry stop, Japan store link opt-in PASS")
    }
}
