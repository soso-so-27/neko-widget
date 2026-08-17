import Foundation

private enum ContractVerificationError: Error {
    case missingFixturePath
}

@main
private struct PairingAPIResponseVerifier {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw ContractVerificationError.missingFixturePath
        }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        try PairingAPIContractVerifier.verifyGoldenResponses(
            Data(contentsOf: fixtureURL)
        )
        print("Pairing API v1 Swift response contract: PASS")
    }
}
