import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct ShowcaseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "jp.nekowidget.showcase") {
            ControlWidgetButton(action: OpenShowcaseIntent(target: .prepared)) {
                Label("写真を見せる", systemImage: "square.grid.3x3.fill")
            }
        }
        .displayName("写真を見せる")
        .description("自慢の9枚を開きます。")
    }
}
