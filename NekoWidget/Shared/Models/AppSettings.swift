import Foundation

enum PhotoDateRange: String, CaseIterable, Codable, Identifiable, Sendable {
    case all
    case recentYear

    var id: Self { self }
}

struct AppSettings: Codable, Equatable, Sendable {
    var dateRange: PhotoDateRange
    var albumMaximum: Int
    var confidenceThreshold: Float
    var minimumCatAreaRatio: Double
    var albumName: String
    var quickScanLimit: Int
    var widgetEntryCount: Int
    var widgetEntryIntervalMinutes: Int
    var analysisRevision: Int

    static let `default` = AppSettings(
        dateRange: .all,
        albumMaximum: 300,
        confidenceThreshold: 0.7,
        minimumCatAreaRatio: 0.08,
        albumName: "うちの子",
        quickScanLimit: 500,
        widgetEntryCount: 20,
        widgetEntryIntervalMinutes: 20,
        analysisRevision: 1
    )

    func normalized() -> AppSettings {
        var value = self
        value.albumMaximum = min(2_000, max(1, albumMaximum))
        value.confidenceThreshold = min(1, max(0, confidenceThreshold))
        value.minimumCatAreaRatio = min(1, max(0, minimumCatAreaRatio))
        value.quickScanLimit = min(2_000, max(1, quickScanLimit))
        value.widgetEntryCount = min(20, max(15, widgetEntryCount))
        value.widgetEntryIntervalMinutes = min(30, max(10, widgetEntryIntervalMinutes))
        value.analysisRevision = max(1, analysisRevision)
        return value
    }

    var analysisFingerprint: String {
        "cat-v2:\(confidenceThreshold.bitPattern):\(minimumCatAreaRatio.bitPattern):\(analysisRevision)"
    }
}
