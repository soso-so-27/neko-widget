import Foundation
import SwiftUI
import WidgetKit

@main
struct NekoWidgetBundle: WidgetBundle {
    init() {
        SharedLog.widget.info(
            "lifecycle",
            "Widget extension process initialized",
            metadata: [
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            ]
        )
    }

    var body: some Widget {
        NekoWidget()
    }
}
