import Foundation
import CoreFoundation

enum PreservationExportPhase: String, Sendable { case reading, assembling, writing }

/// Stable UI contract. The screen owns the wording, not the archive builder.
enum PreservationExportFailure: String, Sendable {
    case communication, accountChanged, missingOrDamaged, insufficientSpace, cancelled
    case contentsChanged, empty, unsupported, cleanup, unavailable

    static func classify(_ error: Error) -> Self {
        if error is CancellationError { return .cancelled }
        if error is PhotoMemoryNoteExportCleanupPending { return .cleanup }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileWriteOutOfSpace.rawValue
            || ns.domain == NSPOSIXErrorDomain && ns.code == 28 { return .insufficientSpace }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain && underlying.code == 28 { return .insufficientSpace }
        if error is URLError { return .communication }
        if let failure = error as? ManagedPreservationError {
            switch failure {
            case .staleSession, .authenticationRequired, .authenticationFailed, .billingIdentityChanged: return .accountChanged
            case .conflict: return .contentsChanged
            case .notFound, .invalidRecord, .invalidResponse, .integrityFailure: return .missingOrDamaged
            case .exportUnsupported: return .unsupported
            case .interrupted: return .cancelled
            case .unavailable, .uploadTimedOut, .rateLimited, .exportThrottled: return .communication
            default: return .unavailable
            }
        }
        if error is ToolBackupError { return .missingOrDamaged }
        if error is AppRecordJSON.Failure || error is DecodingError || error is FamilyNotebookError { return .missingOrDamaged }
        if let failure = error as? PhotoMemoryNoteExportError {
            switch failure {
            case .emptyRecords: return .empty
            case .cleanupFailed: return .cleanup
            default: return .unavailable
            }
        }
        return .unavailable
    }
}

/// One isolated export. All inputs are authenticated by the caller's fixed
/// owner/generation transaction. This never activates a dataset or uses the
/// normal restoration directory/cache. Photos are spooled one at a time.
enum ReadablePreservationExport {
    private struct Stored: Codable {
        let revision: Int
        let document: ManagedPreservationDocument
    }

    static func build(count: Int, expectedHead: UUID,
                      fetch: @escaping @Sendable (Int) async throws -> ManagedPreservationExportSnapshot,
                      progress: @escaping @Sendable (Int, Int) async -> Void,
                      validateContents: @escaping @Sendable (ToolBackupIndex, URL) async throws -> Void,
                      renderContents: (@Sendable (String, Data, [String: String]) async throws -> (text: String, count: Int))? = nil,
                      phase: @escaping @Sendable (PreservationExportPhase) async -> Void = { _ in },
                      temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                      writtenAt: Date = Date()) async throws -> PhotoMemoryNoteExportPayload {
        guard count > 0 else { throw PhotoMemoryNoteExportError.emptyRecords }
        guard count <= 200_000 else { throw ToolBackupError.capacity }
        let id = UUID()
        let directory = temporaryDirectory.appendingPathComponent("ReadablePreservationExports/" + id.uuidString, isDirectory: true)
        let payload = PhotoMemoryNoteExportPayload(id: id, fileURL: directory.appendingPathComponent("ねこのまど.zip"), directory: directory)
        var writer: StoredZIP64Writer?
        var created = false
        do {
            created = true; try ToolBackupFiles.protect(directory)
            let input = directory.appendingPathComponent("input", isDirectory: true)
            try ToolBackupFiles.protect(input)
            var seen = Set<UUID>(), copies: [UUID] = [], legacyTools: [UUID] = []
            var head: AppRecordHead?
            var hasAutomaticRoot = false
            let encoder = JSONEncoder()
            await phase(.reading)
            for offset in 0..<count {
                try Task.checkCancellation()
                let value = try await fetch(offset)
                let record = value.record
                let document = try value.document.validated()
                guard record.revision > 0, seen.insert(record.id).inserted,
                      (document.photoFile != nil) == (value.jpegData != nil) else { throw ToolBackupError.invalid }
                try ToolBackupFiles.write(encoder.encode(Stored(revision: record.revision, document: document)),
                                          to: input.appendingPathComponent(record.id.uuidString + ".json"))
                if let photo = value.jpegData {
                    try ToolBackupFiles.write(photo, to: input.appendingPathComponent(record.id.uuidString + ".jpg"))
                }
                if record.id == expectedHead {
                    head = try AppRecordHead.decode(document)
                } else if document.toolBackup == nil {
                    // An unexpected automatic head must never masquerade as a memo.
                    guard (try? AppRecordHead.decode(document)) == nil else { throw ToolBackupError.invalid }
                    copies.append(record.id)
                } else if let part = document.toolBackup, part.kind == "index" {
                    struct Header: Decodable { let version: Int }
                    guard let data = Data(base64Encoded: part.payload) else { throw ToolBackupError.invalid }
                    let version = try JSONDecoder().decode(Header.self, from: data).version
                    guard (1...4).contains(version) else { throw ManagedPreservationError.exportUnsupported }
                    if version < 3 { legacyTools.append(record.id) }
                    else if version == 3 { hasAutomaticRoot = true }
                    else if try ToolBackupTree.decode(part).prefix.isEmpty { hasAutomaticRoot = true }
                }
                await progress(offset + 1, count)
            }
            guard head != nil || !hasAutomaticRoot else { throw ToolBackupError.invalid }
            func read(_ id: UUID) throws -> Stored {
                guard seen.contains(id) else { throw ToolBackupError.invalid }
                return try JSONDecoder().decode(Stored.self, from: ToolBackupFiles.read(
                    input.appendingPathComponent(id.uuidString + ".json"), maximum: 512 * 1024))
            }
            func part(_ id: UUID) throws -> ToolBackupPart {
                let value = try read(id)
                guard value.revision == 1, let part = value.document.toolBackup else { throw ToolBackupError.invalid }
                try part.validate(photo: value.document.photoFile != nil)
                return part
            }
            func index(_ id: UUID, expectedHash: String?) throws -> ToolBackupIndex {
                let root = try part(id)
                guard root.kind == "index", root.snapshotId == id.uuidString.lowercased(),
                      expectedHash == nil || root.sha256 == expectedHash,
                      let bytes = Data(base64Encoded: root.payload) else { throw ToolBackupError.invalid }
                if let flat = try? JSONDecoder().decode(ToolBackupIndex.self, from: bytes), flat.version < 4 {
                    guard flat.snapshotID == id, expectedHash == nil || flat.version == 3 else { throw ToolBackupError.invalid }
                    try flat.validate(); return flat
                }
                let first = try ToolBackupTree.decode(root)
                var nodes: [ToolBackupPart] = [], visited = Set<UUID>(), encodedBytes = 0
                func visit(_ item: ToolBackupPart) throws {
                    try Task.checkCancellation()
                    let node = try ToolBackupTree.decode(item)
                    encodedBytes += item.payload.utf8.count
                    guard visited.insert(node.snapshotID).inserted, visited.count <= 8192,
                          encodedBytes <= ToolBackupIndex.maximumReceiptBytes else { throw ToolBackupError.capacity }
                    nodes.append(item)
                    for child in node.children ?? [] {
                        let next = try part(child.snapshotID)
                        try ToolBackupTree.validateChild(next, expected: child)
                        try visit(next)
                    }
                }
                try visit(root)
                let result = ToolBackupIndex(version: 4, snapshotID: id, createdAt: first.createdAt,
                    files: try ToolBackupTree.flatten(nodes, root: id), previousIndexID: first.previousIndexID, nodes: nodes)
                try result.validate(); return result
            }
            let archive = try StoredZIP64Writer(url: payload.fileURL, fileManager: .default)
            writer = archive
            var summary: [String] = []
            var archiveNames = Set<String>()
            func append(_ name: String, _ bytes: Data) throws {
                guard archiveNames.insert(name).inserted else { throw ToolBackupError.invalid }
                try archive.append(name: name, data: bytes)
            }
            func assemble(_ snapshot: ToolBackupIndex, prefix: String) async throws {
                await phase(.assembling)
                await progress(0, snapshot.files.count)
                let assembled = directory.appendingPathComponent("assembled/" + snapshot.snapshotID.uuidString, isDirectory: true)
                try ToolBackupFiles.protect(assembled)
                for (fileNumber, file) in snapshot.files.enumerated() {
                    try Task.checkCancellation()
                    var data = Data()
                    for (offset, id) in file.records.enumerated() {
                        let piece = try part(id)
                        let photo = file.path.hasSuffix(".jpg")
                        guard piece.snapshotId == (file.sourceSnapshotID ?? snapshot.snapshotID).uuidString.lowercased(),
                              piece.path == file.path, piece.part == offset, piece.count == file.records.count,
                              piece.kind == (photo ? "photo" : "json") else { throw ToolBackupError.invalid }
                        let chunk: Data
                        if photo { chunk = try ToolBackupFiles.read(input.appendingPathComponent(id.uuidString + ".jpg"), maximum: 20 * 1024 * 1024) }
                        else {
                            guard let decoded = Data(base64Encoded: piece.payload) else { throw ToolBackupError.invalid }
                            chunk = decoded
                        }
                        guard ToolBackupIndex.hash(chunk) == piece.sha256, data.count + chunk.count <= file.bytes else { throw ToolBackupError.invalid }
                        data.append(chunk)
                    }
                    guard data.count == file.bytes, ToolBackupIndex.hash(data) == file.sha256 else { throw ToolBackupError.invalid }
                    let target = assembled.appendingPathComponent(file.path)
                    try ToolBackupFiles.protect(target.deletingLastPathComponent())
                    try ToolBackupFiles.write(data, to: target)
                    await progress(fileNumber + 1, snapshot.files.count)
                }
                let originals = assembled.appendingPathComponent("export-originals", isDirectory: true)
                try ToolBackupFiles.protect(originals)
                for tool in ToolBackupIndex.manifests.keys {
                    let path = tool + "/" + ToolBackupIndex.manifests[tool]!
                    if snapshot.files.contains(where: { $0.path == path }) {
                        try ToolBackupFiles.write(AppRecordJSON.read(assembled.appendingPathComponent(path)),
                                                  to: originals.appendingPathComponent(tool + ".json"))
                    }
                }
                // Existing schema/photo/fragment/reference validation, solely in
                // this export's private temporary directory.
                try await validateContents(snapshot, assembled)
                await phase(.writing)
                let tools = ToolBackupIndex.manifests.keys.sorted().filter { tool in
                    snapshot.files.contains { $0.path == tool + "/" + ToolBackupIndex.manifests[tool]! }
                }
                await progress(0, tools.count)
                for (toolNumber, tool) in tools.enumerated() {
                    let path = tool + "/" + ToolBackupIndex.manifests[tool]!
                    guard snapshot.files.contains(where: { $0.path == path }) else { continue }
                    let data = try ToolBackupFiles.read(originals.appendingPathComponent(tool + ".json"), maximum: AppRecordJSON.maximumBytes)
                    let folder = prefix + ReadablePreservationText.folder(tool)
                    let photoPaths = Dictionary(uniqueKeysWithValues: snapshot.files.filter {
                        $0.path.hasPrefix(tool + "/") && $0.path.hasSuffix(".jpg")
                    }.map { (String($0.path.split(separator: "/")[1]), prefix + "写真のコピー/" + $0.path) })
                    let rendered: (text: String, count: Int)
                    if let renderContents { rendered = try await renderContents(tool, data, photoPaths) }
                    else { rendered = try ReadablePreservationText.render(data, title: ReadablePreservationText.title(tool), photoPaths: photoPaths) }
                    try append(folder + "/元の記録.json", data)
                    try append(folder + "/記録.txt", Data(rendered.text.utf8))
                    // AppRecordJSON reconstructs the exact original JSON bytes;
                    // split transport fragments are not independent JSON files.
                    for file in snapshot.files where file.path.hasPrefix(tool + "/") && file.path.hasSuffix(".jpg") {
                        let bytes = try ToolBackupFiles.read(assembled.appendingPathComponent(file.path), maximum: 20 * 1024 * 1024)
                        try append(prefix + "写真のコピー/" + file.path, bytes)
                    }
                    let photos = snapshot.files.filter { $0.path.hasPrefix(tool + "/") && $0.path.hasSuffix(".jpg") }.map(\.path).sorted()
                    let links = photos.map { "写真のコピー/" + $0 }.joined(separator: "\n")
                    try append(folder + "/写真の一覧.txt", Data(("写真のコピー（\(photos.count)枚）\n同じ保存分のフォルダから開けます。\n" + links + "\n").utf8))
                    summary.append("\(prefix)\(ReadablePreservationText.title(tool))：\(rendered.count)件、写真\(photos.count)枚")
                    await progress(toolNumber + 1, tools.count)
                }
                try FileManager.default.removeItem(at: assembled)
            }
            if let head {
                try await assemble(index(head.snapshotID, expectedHash: head.indexHash), prefix: "")
            }
            for id in legacyTools.sorted(by: { $0.uuidString < $1.uuidString }) {
                try await assemble(index(id, expectedHash: nil), prefix: "以前に保存したコピー/ツール/" + id.uuidString + "/")
            }
            await phase(.writing)
            await progress(0, copies.count)
            for (copyNumber, id) in copies.sorted(by: { $0.uuidString < $1.uuidString }).enumerated() {
                try Task.checkCancellation()
                let value = try read(id), document = value.document
                let jpeg: Data?
                if document.photoFile == nil { jpeg = nil }
                else { jpeg = try ToolBackupFiles.read(input.appendingPathComponent(id.uuidString + ".jpg"), maximum: 20 * 1024 * 1024) }
                let folder = "以前に保存したコピー/メモと写真/" + id.uuidString + "/"
                let files = try PhotoMemoryNoteExporter.archiveFiles(text: document.text,
                    capturedAt: document.capturedAt, writtenAt: document.writtenAt, updatedAt: document.updatedAt,
                    catNames: document.catNames, jpegData: jpeg, weight: document.weight)
                for file in files { try append(folder + file.name, file.data) }
                await progress(copyNumber + 1, copies.count)
            }
            guard head != nil || !copies.isEmpty || !legacyTools.isEmpty else { throw PhotoMemoryNoteExportError.emptyRecords }
            summary.append("以前に1枚ずつ保存したコピー：\(copies.count)件")
            let date = ISO8601DateFormatter().string(from: writtenAt)
            let readme = "ねこのまど — 保存したもの\n書き出した日時：\(date)（UTC）\n\n" + summary.joined(separator: "\n")
                + "\n\n記録.txtはそのまま読めます。元の記録.jsonには、保存した内容が入っています。\n"
                + "写真のコピーには、保存した写真だけが入っています。写真アプリのすべての写真ではありません。\n"
                + "以前に保存したコピーは、今の記録とは別のフォルダにあります。\n"
            try append("はじめにお読みください.txt", Data(readme.utf8))
            try archive.finish(); try archive.close(); writer = nil
            try FileManager.default.removeItem(at: input)
            let assemblyRoot = directory.appendingPathComponent("assembled")
            if FileManager.default.fileExists(atPath: assemblyRoot.path) { try FileManager.default.removeItem(at: assemblyRoot) }
            try Task.checkCancellation()
            return payload
        } catch {
            let failure = error
            try? writer?.close()
            if created {
                do { try payload.cleanup() }
                catch { throw PhotoMemoryNoteExportCleanupPending(payload: payload) }
            }
            throw failure
        }
    }
}

enum ReadablePreservationText {
    static let titles = ["CatIdentity": "猫のこと", "PhotoMemoryNotes": "メモ", "FamilyNotebook": "家族の手帳",
        "CareHandoff": "お世話の引き継ぎ", "EvacuationPreparation": "避難の準備", "VeterinaryVisits": "通院の記録",
        "ShowcasePhotos": "お気に入りの写真", "LostCatDrafts": "迷子のチラシ", "CatPreparedness": "猫の備え", "CatCare": "お世話の記録"]
    static func title(_ tool: String) -> String { titles[tool] ?? tool }
    static func folder(_ tool: String) -> String {
        ["CatIdentity", "PhotoMemoryNotes", "FamilyNotebook"].contains(tool) ? title(tool) : "ツールの記録/" + title(tool)
    }
    static let labels = ["name": "名前", "displayName": "名前", "nickname": "呼び名", "text": "本文", "note": "メモ", "notes": "メモ", "memo": "メモ",
        "title": "題名", "body": "本文", "description": "説明", "cats": "猫", "catName": "猫の名前", "catNames": "猫の名前",
        "records": "記録", "entries": "記録", "items": "項目", "copies": "保存した手帳", "state": "記録", "context": "写真のこと",
        "birthday": "誕生日", "birthDate": "誕生日", "sex": "性別", "breed": "種類", "color": "毛色", "weight": "体重", "grams": "体重（g）",
        "measuredOn": "測った日", "capturedAt": "撮影した日", "writtenAt": "書いた日", "updatedAt": "更新した日", "createdAt": "作った日",
        "date": "日付", "day": "日付", "author": "書いた人", "authorName": "書いた人", "photoFile": "写真のファイル", "photoFilename": "写真のファイル",
        "photoIdentifier": "写真の番号", "photoID": "写真の番号", "fileName": "ファイル名", "filename": "ファイル名",
        "hospital": "病院", "hospitalName": "病院名", "clinic": "病院", "clinicName": "病院名", "symptoms": "症状", "diagnosis": "診断", "treatment": "治療",
        "medication": "薬", "medicine": "薬", "food": "ごはん", "water": "水", "amount": "量", "frequency": "回数", "time": "時刻",
        "phone": "電話番号", "address": "住所", "contact": "連絡先", "contacts": "連絡先", "instructions": "お願い", "checked": "確認済み",
        "completed": "完了", "enabled": "使う", "isNeutered": "避妊・去勢済み", "microchipNumber": "マイクロチップ番号", "features": "特徴",
        "location": "場所", "lastSeenAt": "最後に見た日時", "lastSeenLocation": "最後に見た場所", "household": "家族", "members": "家族",
        "visits": "通院", "plans": "予定", "tasks": "やること", "checklist": "持ち物", "supplies": "持ち物", "quantity": "数",
        "profiles": "猫", "lifeDates": "猫の誕生日・迎えた日", "lifeReference": "猫の日付", "adoptionDay": "迎えた日",
        "birthdayIsApproximate": "誕生日はおおよそ", "adoptionDayIsApproximate": "迎えた日はおおよそ", "lifeReferenceIsApproximate": "日付はおおよそ",
        "year": "年", "month": "月", "value": "内容", "recipient": "お願いする人", "period": "期間", "request": "お願い",
        "usualFood": "いつものごはん", "meals": "ごはん", "toilet": "トイレ", "handling": "接し方", "important": "気をつけること",
        "callWhen": "こんなときは連絡", "healthStatus": "薬・アレルギー", "healthDetails": "薬・アレルギーの内容",
        "medicalStatus": "病歴・薬", "medicalDetails": "病歴・薬の内容", "photoName": "写真のファイル", "photos": "写真",
        "reference": "いつもの写真", "face": "顔", "bodyPhoto": "全身の写真", "facePhoto": "顔の写真", "withOwner": "飼い主と一緒",
        "reviewedAt": "見直した日", "checkedAt": "確かめた日", "confirmedAt": "確かめた日", "isNeeded": "必要なもの",
        "destinations": "避難先", "conditions": "気をつけること", "telephone": "電話番号", "carriedIDs": "持ち出したものの番号",
        "startedOn": "始めた日", "endedOn": "終わった日", "observations": "気づいたこと", "questions": "聞きたいこと", "completedAt": "終わった日",
        "imageFileName": "写真のファイル", "microchipped": "マイクロチップあり", "faceFileName": "顔の写真", "bodyFileName": "全身の写真",
        "collar": "首輪", "approachAdvice": "近づくときのお願い", "lastSeenNear": "最後に見た場所", "lastSeenDescription": "最後に見たときの様子", "message": "メッセージ",
        "dose": "薬の量", "schedule": "飲むタイミング", "givenOn": "受けた日", "nextDueOn": "次の予定日", "proof": "証明書",
        "ownerContact": "飼い主の連絡先", "backupContact": "ほかの連絡先", "vet": "かかりつけの病院", "meetingPlace": "集合場所",
        "neutered": "避妊・去勢", "coat": "毛色", "marks": "目印", "microchip": "マイクロチップ", "indoorOnly": "室内だけで暮らしている",
        "allergy": "アレルギー", "weights": "体重", "medications": "薬", "vaccinations": "ワクチン", "specialDiet": "食事の注意",
        "litter": "トイレ", "temperament": "性格", "vetOverride": "この猫の病院", "allergyStatus": "アレルギー", "allergyText": "アレルギーの内容",
        "vetName": "病院名", "vetPhone": "病院の電話番号", "vetNote": "病院のメモ", "medicationName": "薬の名前", "farewellDay": "家族の手帳をやめた日"]
    private static let bookkeeping: Set<String> = ["schemaVersion", "version", "revision", "id", "catID", "familyID", "deviceID", "ownerID", "generation", "deletedAt",
        "profileID", "toolCatID", "sourceNoteID", "sourceRevision", "familyRecordID", "familyDetached", "prefilledFields", "prefilledUsualFood",
        "mutationRevision", "memberships", "globalExcludedAssets", "legacyUnscoped", "mode", "photoAlbumLink", "keyPhotoLocalIdentifier",
        "archiveBindings", "sharedWindowIDs", "editedBy", "editedAt", "sourceAssetID", "origin", "sourcePhotoIdentifier", "source", "order", "status"]

    static func render(_ data: Data, title: String, photoPaths: [String: String] = [:]) throws -> (text: String, count: Int) {
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        var lines = [title, ""]
        var visited = 0
        func walk(_ value: Any, depth: Int, key: String? = nil) throws {
            visited += 1
            guard depth <= 64, visited <= 2_000_000 else { throw ToolBackupError.capacity }
            if visited % 128 == 0 { try Task.checkCancellation() }
            let indentation = String(repeating: "  ", count: depth)
            if let object = value as? [String: Any] {
                if let deleted = object["deletedAt"], !(deleted is NSNull) {
                    lines.append(indentation + "削除した記録です。以前の内容は元の記録.jsonに残っています。")
                    return
                }
                let collection = ["notes", "records", "drafts"].contains(key ?? "")
                for (offset, name) in object.keys.sorted().filter({ !bookkeeping.contains($0) }).enumerated() {
                    let label = collection ? "記録\(offset + 1)" : labels[name] ?? (UUID(uuidString: name) == nil ? name : "記録")
                    lines.append(indentation + label + "：")
                    try walk(object[name]!, depth: depth + 1, key: name)
                }
            } else if let array = value as? [Any] {
                if array.isEmpty { lines.append(indentation + "なし") }
                for (offset, item) in array.enumerated() {
                    lines.append(indentation + "【\(offset + 1)】")
                    try walk(item, depth: depth + 1, key: key)
                }
            } else if value is NSNull { lines.append(indentation + "未記入") }
            else if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { lines.append(indentation + (number.boolValue ? "はい" : "いいえ")) }
                else if let key, ["createdAt", "updatedAt", "writtenAt", "capturedAt", "date", "completedAt", "reviewedAt", "checkedAt", "confirmedAt", "lastSeenAt"].contains(key) {
                    lines.append(indentation + ISO8601DateFormatter().string(from: Date(timeIntervalSinceReferenceDate: number.doubleValue)))
                } else { lines.append(indentation + number.stringValue) }
            } else {
                let text = String(describing: value)
                lines.append(indentation + (photoPaths[text] ?? text))
            }
        }
        try walk(value, depth: 0)
        let count: Int
        if let array = value as? [Any] { count = array.count }
        else if let object = value as? [String: Any], let array = ["records", "entries", "copies", "cats", "profiles", "visits"].compactMap({ object[$0] as? [Any] }).first { count = array.count }
        else if let object = value as? [String: Any], let values = ["notes", "records", "drafts"].compactMap({ object[$0] as? [String: Any] }).first { count = values.count }
        else { count = 1 }
        return (lines.joined(separator: "\n") + "\n", count)
    }
}

/// Use the same conflict/deletion rules as the notebook. Never present raw CRDT
/// operations as the current notebook, and never silently drop a conflict.
enum FamilyNotebookReadableText {
    static func render(_ copies: [FamilyNotebookSnapshot]) throws -> (text: String, count: Int) {
        let collections: [FamilyNotebookCollection: String] = [.cat: "猫のこと", .weight: "体重", .medication: "薬",
            .vaccination: "ワクチン", .meal: "ごはん", .visit: "通院", .visitEntry: "通院のメモ",
            .handoff: "お世話の引き継ぎ", .handoffMeal: "ごはんのお願い"]
        var lines = ["家族の手帳", "", "今の記録です。以前の内容も元の記録.jsonに残っています。"], count = 0
        let dates = ISO8601DateFormatter()
        func value(_ input: FamilyNotebookValue?) -> String {
            switch input {
            case .text(let text), .day(let text): return text
            case .integer(let number): return String(number)
            case .decimal(let number): return String(number)
            case .date(let date): return dates.string(from: date)
            case .clear, .none: return "未記入"
            }
        }
        for (offset, snapshot) in copies.enumerated() {
            try Task.checkCancellation()
            lines.append("\n【手帳\(offset + 1)】")
            let cats = Set(snapshot.operations.map { $0.target.familyCatID }).sorted { $0.uuidString < $1.uuidString }
            for (catNumber, cat) in cats.enumerated() {
                let name = snapshot.fieldState(for: .init(familyCatID: cat, field: .name)).flatMap { $0.isDeleted ? nil : $0.operation.value }
                lines.append("\n猫\(catNumber + 1)：" + (name == nil ? "名前未記入" : value(name)))
                let targets = Set(snapshot.operations.map(\.target)).filter { $0.familyCatID == cat && $0.field != nil }
                    .sorted {
                        ($0.collection.rawValue, $0.recordID?.uuidString ?? "", $0.field?.rawValue ?? "")
                            < ($1.collection.rawValue, $1.recordID?.uuidString ?? "", $1.field?.rawValue ?? "")
                    }
                var previous: String?
                for target in targets {
                    try Task.checkCancellation()
                    guard let state = snapshot.fieldState(for: target), !state.isDeleted, let field = target.field else { continue }
                    let group = target.collection.rawValue + (target.recordID?.uuidString ?? "")
                    if group != previous { lines.append("\n" + (collections[target.collection] ?? "記録")); previous = group; count += 1 }
                    let label = ReadablePreservationText.labels[field.rawValue] ?? field.rawValue
                    lines.append(label + "：" + value(state.operation.value))
                    lines.append("  書いた人：" + state.operation.author.displayName + "／" + dates.string(from: state.operation.editedAt))
                    for alternative in state.history where alternative.isConcurrentConflict {
                        lines.append("  同じころに書かれた内容：" + value(alternative.operation.value) + "（" + alternative.operation.author.displayName + "）")
                    }
                }
            }
        }
        return (lines.joined(separator: "\n") + "\n", count)
    }
}
