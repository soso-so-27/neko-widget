"""Extract the actual metadata transaction and dataset scope checks for a cheap native probe."""
from pathlib import Path
import sys
source=Path("NekoWidget/Services/AppRecordPersistence.swift").read_text(encoding="utf-8")
def block(signature, indent):
 a=source.index(signature)
 b=source.index("\n"+" "*indent+"}",a)+indent+2
 return source[a:b]
parts=["import Foundation\nimport CryptoKit",
 block("enum AppRecordBindingError:",0),block("enum AppRecordRebinding {",0),
 "enum ToolBackupError: Error { case invalid }",
 "enum ManagedPreservationError: Error { case staleSession }",
 "enum ToolBackupFiles { static func read(_ u: URL, maximum: Int) throws -> Data { let d=try Data(contentsOf:u); guard d.count<=maximum else {throw ToolBackupError.invalid}; return d } }",
 "enum AppRecordDataset { static let writeLock=NSRecursiveLock(); static var support=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); static var control:URL {support.appendingPathComponent(\"control\")}; static var datasets:URL {support.appendingPathComponent(\"datasets\")}; static var pointerURL:URL {control.appendingPathComponent(\"active.json\")}; static let knownManifestPaths:Set<String>=[\"CatCare/state.json\"]",
 block("    struct Pointer:",4),block("    static func pointer()",4),block("    static func root()",4),block("    static func requireScope(",4),"}"]
parts.append(Path("ci/verify-preservation-rebind.swift").read_text())
Path(sys.argv[1]).write_text("\n".join(parts),encoding="utf-8")
