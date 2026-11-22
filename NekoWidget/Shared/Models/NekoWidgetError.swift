import Foundation

enum NekoWidgetError: LocalizedError, Sendable {
    case appGroupUnavailable(String)
    case photoAccessDenied
    case albumCreationFailed
    case noCatPhotos
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            // 11/22 (1122n): people never see setup words. The group's
            // identifier stays in the case value for logs and tests.
            return "うまくいきませんでした。アプリを開き直してください。"
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
