import Foundation

private enum VerificationError: Error {
    case invalidArguments
}

@main
private struct SharingAPIResponseVerifier {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw VerificationError.invalidArguments
        }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        try DailySharingAPIContractVerifier.verifyGoldenResponses(
            Data(contentsOf: fixtureURL)
        )
        print("Sharing API v1 Swift response fixture: PASS")
    }
}
