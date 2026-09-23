import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct ShowcaseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "jp.nekowidget.showcase") {
            ControlWidgetButton(action: OpenShowcaseIntent(target: .prepared)) {
                Label("うちのこを見せる", systemImage: "pawprint")
            }
        }
        .displayName("うちのこを見せる")
        .description("準備した猫の写真だけを開きます。")
    }
}
