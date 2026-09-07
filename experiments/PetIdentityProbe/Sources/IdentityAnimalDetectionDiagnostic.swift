import Foundation

// Temporary Vision class labels, never PhotoKit identifiers or individual-cat names.
struct IdentityAnimalLabelSample {
    let label: String
    let confidence: Float
}

struct IdentityAnimalLabelDiagnostic: Encodable {
    let label: String
    let observationCount: Int
    let maximumConfidence: Double?
}

/// Describes one detector invocation without changing which boxes are accepted.
struct IdentityAnimalDetectionDiagnostic: Encodable {
    let revision: Int
    let systemCatLabel: String
    let resultsAvailable: Bool
    let observationCount: Int?
    let exactCatObservationCount: Int
    let caseInsensitiveCatObservationCount: Int
    let acceptedCatObservationCount: Int
    let caseInsensitiveAcceptedCatObservationCount: Int
    let maximumCatConfidence: Double?
    let maximumCaseInsensitiveCatConfidence: Double?
    let labels: [IdentityAnimalLabelDiagnostic]
    let acceptedLabel = "Cat"
    let minimumLabelConfidence = 0.5
    let labelMatching = "case-sensitive;unchanged"
    let scope = "one-selected-photo;animal-class-labels-only;no-photo-identifiers-or-boxes"

    static func acceptsCat(_ labels: [IdentityAnimalLabelSample]) -> Bool {
        labels.contains { $0.label == "Cat" && $0.confidence >= 0.5 }
    }

    init(observationLabels: [[IdentityAnimalLabelSample]], revision: Int, systemCatLabel: String,
         resultsAvailable: Bool = true) {
        self.revision = revision
        self.systemCatLabel = systemCatLabel
        self.resultsAvailable = resultsAvailable
        let observations = resultsAvailable ? observationLabels : []
        observationCount = resultsAvailable ? observations.count : nil
        let all = observations.flatMap { $0 }
        let exact = all.filter { $0.label == "Cat" }
        let insensitive = all.filter { $0.label.caseInsensitiveCompare("cat") == .orderedSame }
        exactCatObservationCount = observations.filter { $0.contains { $0.label == "Cat" } }.count
        caseInsensitiveCatObservationCount = observations.filter {
            $0.contains { $0.label.caseInsensitiveCompare("cat") == .orderedSame }
        }.count
        acceptedCatObservationCount = observations.filter(Self.acceptsCat).count
        caseInsensitiveAcceptedCatObservationCount = observations.filter {
            $0.contains { $0.label.caseInsensitiveCompare("cat") == .orderedSame && $0.confidence >= 0.5 }
        }.count
        maximumCatConfidence = Self.maximum(exact)
        maximumCaseInsensitiveCatConfidence = Self.maximum(insensitive)
        labels = Set(all.map(\.label)).sorted().map { label in
            IdentityAnimalLabelDiagnostic(label: label,
                observationCount: observations.filter { $0.contains { $0.label == label } }.count,
                maximumConfidence: Self.maximum(all.filter { $0.label == label }))
        }
    }

    private static func maximum(_ labels: [IdentityAnimalLabelSample]) -> Double? {
        labels.map(\.confidence).filter(\.isFinite).max().map(Double.init)
    }

    var summary: String {
        if !resultsAvailable { return "検出結果が返りませんでした。" }
        if observationCount == 0 { return "動物の候補が見つかりませんでした。" }
        if acceptedCatObservationCount == 0 && caseInsensitiveAcceptedCatObservationCount > 0 {
            return "猫の候補はありますが、ラベルの大文字・小文字が採用条件と一致していません。"
        }
        if acceptedCatObservationCount == 0 && exactCatObservationCount > 0 {
            return "猫の候補はありますが、信頼度が採用基準に達していません。"
        }
        if acceptedCatObservationCount == 0 { return "猫として採用するラベルが見つかりませんでした。" }
        if acceptedCatObservationCount > 1 { return "採用条件を満たす猫の候補が複数あります。" }
        return "採用条件を満たす猫の候補が1件あります。"
    }
}
