import Photos
import SwiftUI

@MainActor
final class CandidateValidationStore: ObservableObject {
    @Published private(set) var study: CandidateValidationStudy?
    @Published private(set) var message: String?
    @Published private(set) var blocked = false
    @Published private(set) var running = false
    @Published private(set) var processed = 0
    @Published private(set) var report: CandidateValidationReport?
    @Published var picker: CandidatePickerRequest?
    @Published private(set) var focusIndex: Int?
    @Published private(set) var focusImage: CGImage?
    @Published private(set) var focusLoaded = false
    @Published private(set) var referenceA: CGImage?
    @Published private(set) var referenceB: CGImage?
    private let references: IdentitySelectionArchive
    private let development: CandidateSelectionArchive
    private let archive: CandidateValidationArchive
    private let worker = IdentityPhotoService()
    private let metadata: (([String]) async throws -> String)?
    private let imageLoader: ((String) async throws -> CGImage?)?
    private let runner: (([IdentityPhotoSlot: [String]], [String], [String]) async throws -> CandidateReviewRun)?
    private var saved: [IdentityPhotoSlot: [String]] = [:]
    private var known: [String] = []
    private var developmentIDs: [String] = []
    private var generation = UUID()
    private var task: Task<Void, Never>?

    init(references: IdentitySelectionArchive = .device, development: CandidateSelectionArchive = .device,
         archive: CandidateValidationArchive = .device,
         metadata: (([String]) async throws -> String)? = nil,
         imageLoader: ((String) async throws -> CGImage?)? = nil,
         runner: (([IdentityPhotoSlot: [String]], [String], [String]) async throws -> CandidateReviewRun)? = nil) {
        self.references = references; self.development = development; self.archive = archive
        self.metadata = metadata; self.imageLoader = imageLoader; self.runner = runner
        do {
            saved = try references.load(); developmentIDs = try development.load()
            try IdentityRecoveryComparisonCore.validateSelection(saved)
            guard saved[.referenceA]?.count == 5, saved[.referenceB]?.count == 5 else { throw CocoaError(.fileReadCorruptFile) }
            known = Set(saved.values.flatMap { $0 } + developmentIDs).sorted()
            study = try archive.load()
            if let study {
                guard study.algorithmMatches, study.knownIdentifiers == known,
                      study.referenceFingerprint == (try CandidateValidationStudy.fingerprint(saved)) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        } catch {
            blocked = true
            message = "保存内容・見本・検証条件を照合できません。上書きしていません。見本を変更した場合も、この検証へ自動で引き継ぎません。"
        }
    }
    var count: Int { study?.identifiers.count ?? 0 }
    var confirmed: Int { study?.decisions.count ?? 0 }
    var isSealed: Bool { study?.sealed == true }
    var pickerLimit: Int { max(1, min(24, CandidateValidationStudy.limit - count)) }
    var canAdd: Bool { !blocked && !running && !isSealed && count < CandidateValidationStudy.limit }
    var canCompare: Bool { !blocked && !running && study?.canSeal == true }

    func choosePhotos() {
        guard canAdd, picker == nil else { return }
        let token = generation
        Task { @MainActor in
            let permission = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard generation == token, canAdd else { return }
            guard permission == .authorized || permission == .limited else {
                message = "見本と選んだ写真へのアクセスを許可してください。限定アクセスでも使えます。"; return
            }
            picker = CandidatePickerRequest()
        }
    }
    func picked(_ values: [String?], request: CandidatePickerRequest) {
        guard picker?.id == request.id else { return }; picker = nil
        guard canAdd, !values.isEmpty else { return }
        guard values.count <= pickerLimit, values.allSatisfy({ $0?.isEmpty == false }) else {
            message = "選択を確認できません。前の写真・確認は残しています。"; return
        }
        let ids = values.compactMap { $0 }
        guard Set(ids).count == ids.count else { message = "同じ写真が選択されています。保存は変えていません。"; return }
        let ignored = Set(known + (study?.identifiers ?? []))
        let newIDs = ids.filter { !ignored.contains($0) }
        guard !newIDs.isEmpty else { message = "すべて保存済みの写真でした。自動で外したので、以前の選択を覚える必要はありません。"; return }
        perform { [self] in
            try await checkInputs()
            let fingerprint = try await assetState(known + (study?.identifiers ?? []) + newIDs)
            try await checkInputs() // Do not silently adopt an edited old input while adding new IDs.
            var next: CandidateValidationStudy
            if let current = study { next = current }
            else {
                next = try CandidateValidationStudy(method: CandidateValidationStudy.protocolKey,
                    identityModel: ProbeModelFile.sha256, objectModel: CandidateObjectDetector.modelSHA256,
                    runtime: IdentityEvaluationCore.expectedRuntimeVersion, osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    referenceFingerprint: CandidateValidationStudy.fingerprint(saved), knownIdentifiers: known,
                    assetStateFingerprint: fingerprint)
            }
            try next.append(newIDs, assetFingerprint: fingerprint)
            try persist(next)
            message = ids.count == newIDs.count ? nil : "保存済みと重なる\(ids.count - newIDs.count)枚を外し、\(newIDs.count)枚を追加しました。"
        }
    }
    func openPhoto(_ index: Int? = nil) {
        guard !blocked, !running, !isSealed, let study else { return }
        let target = index ?? study.identifiers.firstIndex(where: { study.decisions[$0] == nil })
        guard let target, study.identifiers.indices.contains(target) else { return }
        focusIndex = target; focusImage = nil; focusLoaded = false
        perform { [self] in
            try await checkInputs()
            let image = try await loadImage(study.identifiers[target])
            let a = try await loadImage(saved[.referenceA]![0])
            let b = try await loadImage(saved[.referenceB]![0])
            try await checkInputs()
            try Task.checkCancellation()
            guard a != nil, b != nil else { throw CocoaError(.fileReadCorruptFile) }
            guard focusIndex == target else { return }
            focusImage = image; referenceA = a; referenceB = b; focusLoaded = true
        }
    }
    func choose(_ choice: CandidateReviewChoice) {
        guard !blocked, !running, !isSealed, focusLoaded, let index = focusIndex, let study,
              study.identifiers.indices.contains(index), focusImage != nil || choice == .unsure else { return }
        perform { [self] in
            try await checkInputs()
            var next = study; try next.choose(choice, id: study.identifiers[index]); try persist(next)
            if let target = next.identifiers.firstIndex(where: { next.decisions[$0] == nil }) {
                focusIndex = target; focusLoaded = false; focusImage = nil
                let image = try await loadImage(next.identifiers[target])
                try await checkInputs(); try Task.checkCancellation()
                guard focusIndex == target else { return }
                focusImage = image; focusLoaded = true
            } else { closePhoto() }
        }
    }
    func remove(_ index: Int) {
        guard !blocked, !running, !isSealed, let study, study.identifiers.indices.contains(index) else { return }
        perform { [self] in
            try await checkInputs()
            var next = study; let id = next.identifiers.remove(at: index); next.decisions.removeValue(forKey: id)
            next.assetStateFingerprint = try await assetState(known + next.identifiers)
            try await checkInputs()
            try persist(next); closePhoto()
        }
    }
    func compare() {
        guard canCompare, var next = study else { return }
        perform { [self] in
            try await checkInputs()
            if !next.sealed { try next.seal(); try persist(next) }
            // The label file is sealed BEFORE inference, including on retry after interruption.
            var all: [CandidateReviewPhoto] = []; var missingSources = 0
            for start in stride(from: 0, to: next.identifiers.count, by: 24) {
                try Task.checkCancellation(); try await checkInputs()
                let ids = Array(next.identifiers[start..<min(start + 24, next.identifiers.count)])
                let duplicates = Set(known + Array(next.identifiers.prefix(start))).sorted()
                let run: CandidateReviewRun
                if let runner { run = try await runner(saved, ids, duplicates) }
                else { run = try await worker.reviewCandidates(saved: saved, selected: ids, duplicateOnlyIDs: duplicates) { _ in } }
                try Task.checkCancellation()
                guard run.photos.count == ids.count, run.photos.map(\.id) == Array(ids.indices) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                for photo in run.photos {
                    all.append(.init(id: start + photo.id, image: photo.image, suggestion: photo.suggestion,
                        issue: photo.issue, cropDiagnostic: photo.cropDiagnostic, regionReview: photo.regionReview,
                        distanceAssessment: photo.distanceAssessment, objectCheck: photo.objectCheck))
                }
                missingSources += run.duplicateSourcesUnavailable; processed = all.count
            }
            try await checkInputs(); try Task.checkCancellation()
            report = try .init(study: next, photos: all, duplicateSourcesUnavailable: missingSources)
        }
    }
    func closePhoto() { focusIndex = nil; focusImage = nil; focusLoaded = false; referenceA = nil; referenceB = nil }
    func suspend() {
        generation = UUID(); task?.cancel(); task = nil; running = false; picker = nil; closePhoto(); report = nil
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !running else { return }
        running = true; message = nil; processed = 0
        let token = generation
        task = Task { @MainActor in
            do { try await action() }
            catch is CancellationError {}
            catch {
                if generation == token { message = "処理または保存を完了できませんでした。前の写真・確認は残しています。写真の編集・削除、見本の変更、空き容量やアクセス許可を確認してください。" }
            }
            guard generation == token else { return }
            running = false; task = nil
        }
    }
    private func assetState(_ ids: [String]) async throws -> String {
        if let metadata { return try await metadata(ids) }
        return try await worker.validationAssetState(ids: ids)
    }
    private func loadImage(_ id: String) async throws -> CGImage? {
        if let imageLoader { return try await imageLoader(id) }
        return try await worker.validationPhoto(id: id)
    }
    private func checkInputs() async throws {
        try Task.checkCancellation()
        guard try references.load() == saved, try development.load() == developmentIDs,
              try archive.load() == study else { throw CocoaError(.fileReadCorruptFile) }
        if let study {
            guard study.algorithmMatches, try await assetState(known + study.identifiers) == study.assetStateFingerprint else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        try Task.checkCancellation()
    }
    private func persist(_ next: CandidateValidationStudy) throws {
        try Task.checkCancellation()
        guard try references.load() == saved, try development.load() == developmentIDs,
              try archive.load() == study else { throw CocoaError(.fileReadCorruptFile) }
        try archive.save(next); study = next; report = nil
    }
}
