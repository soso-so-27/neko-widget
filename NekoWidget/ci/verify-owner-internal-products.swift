import Foundation

@main
enum OwnerInternalProducts {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        for relative in ["Info.plist", "PlugIns/NekoWidgetShareExtension.appex/Info.plist",
                         "PlugIns/NekoWidgetWidgetExtension.appex/Info.plist"] {
            let data = try Data(contentsOf: root.appendingPathComponent(relative))
            let info = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
            let config = SharingAPIConfiguration.from(info: info)
            precondition(config.isOwnerInternalReportsDisabled && !config.isEncryptedReportAvailable)
            precondition(!config.requiresLocalSharingPurge, "report OFF cannot authorize data removal")
            if relative == "Info.plist" {
                precondition(config.isMediaAvailable, "photo sharing must remain available")
            }
        }
        print("PASS actual owner internal app and both extensions: reports OFF, no sharing purge")
    }
}
