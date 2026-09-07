import Foundation
import XCTest
@testable import PetIdentityProbe

final class IdentityAnimalDetectionDiagnosticTests: XCTestCase {
    private func sample(_ label: String, _ confidence: Float) -> IdentityAnimalLabelSample {
        IdentityAnimalLabelSample(label: label, confidence: confidence)
    }

    private func diagnostic(_ observations: [[IdentityAnimalLabelSample]], resultsAvailable: Bool = true) -> IdentityAnimalDetectionDiagnostic {
        IdentityAnimalDetectionDiagnostic(observationLabels: observations, revision: 2,
                                          systemCatLabel: "Cat", resultsAvailable: resultsAvailable)
    }

    func testNoObservationsAndUnavailableResultsRemainDistinct() {
        let empty = diagnostic([])
        let unavailable = diagnostic([], resultsAvailable: false)
        XCTAssertTrue(empty.resultsAvailable)
        XCTAssertEqual(empty.observationCount, 0)
        XCTAssertFalse(unavailable.resultsAvailable)
        XCTAssertNil(unavailable.observationCount)
        XCTAssertNotEqual(empty.summary, unavailable.summary)
        for result in [empty, unavailable] {
            XCTAssertEqual(result.exactCatObservationCount, 0)
            XCTAssertEqual(result.caseInsensitiveCatObservationCount, 0)
            XCTAssertEqual(result.acceptedCatObservationCount, 0)
            XCTAssertEqual(result.caseInsensitiveAcceptedCatObservationCount, 0)
            XCTAssertNil(result.maximumCatConfidence)
            XCTAssertNil(result.maximumCaseInsensitiveCatConfidence)
            XCTAssertTrue(result.labels.isEmpty)
        }
    }

    func testLowConfidenceCatIsObservedButNotAccepted() {
        let labels = [sample("Cat", 0.49)]
        let result = diagnostic([labels])
        XCTAssertEqual(result.observationCount, 1)
        XCTAssertEqual(result.exactCatObservationCount, 1)
        XCTAssertEqual(result.caseInsensitiveCatObservationCount, 1)
        XCTAssertEqual(result.acceptedCatObservationCount, 0)
        XCTAssertEqual(result.caseInsensitiveAcceptedCatObservationCount, 0)
        XCTAssertEqual(result.maximumCatConfidence, Double(Float(0.49)))
        XCTAssertEqual(result.maximumCaseInsensitiveCatConfidence, Double(Float(0.49)))
        XCTAssertFalse(IdentityAnimalDetectionDiagnostic.acceptsCat(labels))
    }

    func testLowercaseCatIsOnlyAcceptedByTheDiagnosticInsensitiveComparison() {
        let labels = [sample("cat", 0.75)]
        let result = IdentityAnimalDetectionDiagnostic(observationLabels: [labels], revision: 2,
                                                       systemCatLabel: "cat")
        XCTAssertEqual(result.systemCatLabel, "cat")
        XCTAssertEqual(result.observationCount, 1)
        XCTAssertEqual(result.exactCatObservationCount, 0)
        XCTAssertEqual(result.caseInsensitiveCatObservationCount, 1)
        XCTAssertEqual(result.acceptedCatObservationCount, 0)
        XCTAssertEqual(result.caseInsensitiveAcceptedCatObservationCount, 1)
        XCTAssertNil(result.maximumCatConfidence)
        XCTAssertEqual(result.maximumCaseInsensitiveCatConfidence, 0.75)
        // The runtime's reported label is evidence, not a change to the original rule.
        XCTAssertFalse(IdentityAnimalDetectionDiagnostic.acceptsCat(labels))
    }

    func testObservationsAreCountedOnceAndTheExactThresholdIsInclusive() throws {
        let first = [sample("Cat", 0.5), sample("Cat", 0.75), sample("Dog", 0.9)]
        let one = diagnostic([first])
        XCTAssertEqual(one.observationCount, 1)
        XCTAssertEqual(one.exactCatObservationCount, 1)
        XCTAssertEqual(one.acceptedCatObservationCount, 1)
        XCTAssertEqual(try XCTUnwrap(one.labels.first { $0.label == "Cat" }).observationCount, 1)

        let second = [sample("Cat", 0.5), sample("cat", 0.75)]
        let two = diagnostic([first, second])
        XCTAssertEqual(two.observationCount, 2)
        XCTAssertEqual(two.exactCatObservationCount, 2)
        XCTAssertEqual(two.caseInsensitiveCatObservationCount, 2)
        XCTAssertEqual(two.acceptedCatObservationCount, 2)
        XCTAssertEqual(two.caseInsensitiveAcceptedCatObservationCount, 2)
        XCTAssertEqual(try XCTUnwrap(two.labels.first { $0.label == "Cat" }).observationCount, 2)
        XCTAssertTrue(IdentityAnimalDetectionDiagnostic.acceptsCat([sample("Cat", 0.5)]))
        XCTAssertFalse(IdentityAnimalDetectionDiagnostic.acceptsCat([sample("Cat", Float(0.5).nextDown)]))
        XCTAssertFalse(IdentityAnimalDetectionDiagnostic.acceptsCat([sample("Dog", 1)]))
    }

    func testJSONIsFiniteAndContainsOnlyDetectorMetadataAndLabelAggregates() throws {
        let result = diagnostic([
            [sample("Cat", .nan), sample("Dog", .infinity)],
            [sample("Cat", .infinity), sample("cat", -.infinity)],
            [sample("Cat", 0.75), sample("Cat", .nan)]
        ])
        XCTAssertEqual(result.exactCatObservationCount, 3)
        XCTAssertEqual(result.acceptedCatObservationCount, 2)
        XCTAssertEqual(result.maximumCatConfidence, 0.75)
        XCTAssertEqual(result.maximumCaseInsensitiveCatConfidence, 0.75)
        XCTAssertNil(try XCTUnwrap(result.labels.first { $0.label == "Dog" }).maximumConfidence)
        XCTAssertNil(try XCTUnwrap(result.labels.first { $0.label == "cat" }).maximumConfidence)
        // Only exported maxima filter nonfinite values; keep the existing comparison unchanged.
        XCTAssertTrue(IdentityAnimalDetectionDiagnostic.acceptsCat([sample("Cat", .infinity)]))
        XCTAssertFalse(IdentityAnimalDetectionDiagnostic.acceptsCat([sample("Cat", .nan)]))
        XCTAssertFalse(IdentityAnimalDetectionDiagnostic.acceptsCat([sample("Cat", -.infinity)]))

        let data = try JSONEncoder().encode(result)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "revision", "systemCatLabel", "resultsAvailable", "observationCount",
            "exactCatObservationCount", "caseInsensitiveCatObservationCount",
            "acceptedCatObservationCount", "caseInsensitiveAcceptedCatObservationCount",
            "maximumCatConfidence", "maximumCaseInsensitiveCatConfidence", "labels",
            "acceptedLabel", "minimumLabelConfidence", "labelMatching", "scope"
        ])
        XCTAssertNil(object["summary"])
        XCTAssertEqual(object["revision"] as? Int, 2)
        XCTAssertEqual(object["maximumCatConfidence"] as? Double, 0.75)
        let labels = try XCTUnwrap(object["labels"] as? [[String: Any]])
        let allowedLabelKeys: Set<String> = ["label", "observationCount", "maximumConfidence"]
        for label in labels {
            XCTAssertTrue(Set(label.keys).isSubset(of: allowedLabelKeys))
            XCTAssertNotNil(label["label"] as? String)
            XCTAssertNotNil(label["observationCount"] as? Int)
            if let maximum = label["maximumConfidence"] as? Double { XCTAssertTrue(maximum.isFinite) }
        }
    }
}
