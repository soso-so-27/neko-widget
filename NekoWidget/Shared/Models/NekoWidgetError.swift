import Foundation

enum NekoWidgetError: LocalizedError, Sendable {
    case appGroupUnavailable(String)
    case photoAccessDenied
    case albumCreationFailed
    case noCatPhotos
    case exportFailed

    var errorDescription: String? {
        switch self {
        case let .appGroupUnavailable(identifier):
            return "App Group \(identifier) を開けません。Signing & Capabilities を確認してください。"
        case .photoAccessDenied:
            return "写真へのアクセスが許可されていません。"
        case .albumCreationFailed:
            return "アルバムを作れませんでした。"
        case .noCatPhotos:
            return "表示できる猫の写真がまだありません。"
        case .exportFailed:
            return "データを書き出せませんでした。"
        }
    }
}
