import Photos
import SwiftUI

struct CandidatePickerRequest: Identifiable { let id = UUID() }

@MainActor
final class CandidateReviewStore: ObservableObject {
    @Published private(set) var selected: [String] = []
    @Published private(set) var saved: [IdentityPhotoSlot: [String]] = [:]
    @Published var picker: CandidatePickerRequest?
    @Published private(set) var running = false
    @Published private(set) var progress = 0
    @Published private(set) var session: CandidateReviewSession?
    @Published private(set) var savedConfirmationCount = 0
    @Published private(set) var requiresProgressReset = false
    @Published var pendingSelection: [String]?
    @Published private(set) var message: String?
    @Published private(set) var storageWarning: String?
    @Published private(set) var candidateReadFailed = false
    @Published private(set) var hasArchivedSelection = false
    private var referenceReadFailed = false
    private var blocked: Bool { referenceReadFailed || candidateReadFailed || requiresProgressReset }
    private let referenceArchive: IdentitySelectionArchive
    private let candidateArchive: CandidateSelectionArchive
    private let service = IdentityPhotoService()
    private let runner: (([IdentityPhotoSlot: [String]], [String]) async throws -> CandidateReviewRun)?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var batch = CandidateSavedBatch(identifiers: [])

    init(referenceArchive: IdentitySelectionArchive = .device, candidateArchive: CandidateSelectionArchive = .device,
         runner: (([IdentityPhotoSlot: [String]], [String]) async throws -> CandidateReviewRun)? = nil) {
        self.referenceArchive = referenceArchive
        self.candidateArchive = candidateArchive
        self.runner = runner
        do {
            saved = try referenceArchive.load()
        } catch {
            referenceReadFailed = true
            message = "保存した見本を読み出せません。上書きしていません。「猫の検出を確認する」で保存状態を確認してください。"
        }
        do {
            batch = try candidateArchive.loadBatch()
            selected = batch.identifiers
            savedConfirmationCount = batch.progress?.decisions.count ?? 0
            hasArchivedSelection = !selected.isEmpty
        }
        catch {
            candidateReadFailed = true
            message = "今回の選択と確認結果を読み出せません。上書きしていません。「今回の選択と確認結果を消去」で、この検証だけをやり直せます。見本は残ります。"
        }
        if !blocked {
            let eligible = CandidateReviewSelection.excludingSaved(selected, saved: saved)
            let excludedCount = selected.count - eligible.count
            if excludedCount > 0 {
                // References may have changed since the candidate selection was saved.
                // Filter in memory without rewriting either archive during restoration.
                selected = eligible
                message = "保存済みの見本・判定写真と重なる\(excludedCount)枚を自動で外しました。"
            }
            if let progress = batch.progress {
                requiresProgressReset = (try? CandidateSavedProgress.fingerprint(saved)) != progress.referenceFingerprint
                    || selected != batch.identifiers
                if requiresProgressReset {
                    message = "見本または写真の対象が変わりました。以前の確認は保存したまま、別の猫への引き継ぎを止めています。"
                }
            }
        }
    }

    var hasReferences: Bool { saved[.referenceA]?.count == 5 && saved[.referenceB]?.count == 5 }
    var canChoose: Bool { !blocked && !running && hasReferences }
    var canRun: Bool { canChoose && !selected.isEmpty }
    var total: Int { saved.values.reduce(0) { $0 + $1.count } + selected.count }

    func choose() {
        guard canChoose, picker == nil else { return }
        let token = generation
        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard token == generation, canChoose else { return }
            guard status == .authorized || status == .limited else {
                message = "写真へのアクセスを許可してください。限定アクセスの場合は、見本と今回選ぶ写真を含めてください。"
                return
            }
            picker = CandidatePickerRequest()
        }
    }

    func picked(_ ids: [String?], request: CandidatePickerRequest) {
        guard picker?.id == request.id else { return }
        picker = nil
        guard canChoose else { return }
        // Empty cancellation never erases a previous selection.
        guard !ids.isEmpty else { return }
        guard ids.allSatisfy({ $0?.isEmpty == false }) else {
            message = "写真へのアクセスを確認できません。限定アクセスの場合は、選んだ写真にも許可してください。元の選択は残しています。"
            return
        }
        let values = ids.compactMap { $0 }
        do {
            let eligible = try CandidateReviewSelection.filteringKnownPhotos(values, saved: saved)
            let excludedCount = values.count - eligible.count
            guard !eligible.isEmpty else {
                message = "選んだ\(excludedCount)枚は保存済みの見本・判定写真なので、自動で外しました。"
                    + (selected.isEmpty ? "ほかの写真を追加できます。" : "元の\(selected.count)枚は残しています。そのまま候補を見られます。")
                return
            }
            message = excludedCount > 0 ? "保存済みの見本・判定写真と重なる\(excludedCount)枚を自動で外しました。残りの\(eligible.count)枚で進められます。" : nil
            guard eligible != selected else { return }
            if batch.progress != nil { pendingSelection = eligible }
            else { replaceSelection(eligible) }
        } catch let failure as IdentityPhotoFailure { message = failure.message }
        catch { message = "選択を確認できません。元の選択は残しています。" }
    }

    func start() {
        guard canRun else { return }
        do {
            // References changed in another screen? Do not publish a stale proposal.
            guard try referenceArchive.load() == saved else {
                message = "見本が変わりました。この画面を開き直してください。"; return
            }
            guard try candidateArchive.loadBatch() == batch else {
                message = "保存内容が別の画面で変わりました。この画面を開き直してください。"; return
            }
            try CandidateReviewSelection.validate(selected, saved: saved)
        } catch let failure as IdentityPhotoFailure { message = failure.message; return }
        catch { message = "保存した見本を確認できません。選択は上書きしていません。"; return }
        generation = UUID()
        let token = generation, references = saved, ids = selected
        session = nil; message = nil; running = true; progress = 0
        task = Task { @MainActor in
            do {
                let run: CandidateReviewRun
                if let runner { run = try await runner(references, ids) }
                else {
                    run = try await service.reviewCandidates(saved: references, selected: ids) { [weak self] count in
                        await self?.updateProgress(count, token: token)
                    }
                }
                guard generation == token, !Task.isCancelled else { return }
                guard try referenceArchive.load() == references else {
                    throw IdentityPhotoFailure(message: "見本が変わったため結果を採用しませんでした。画面を開き直してください。")
                }
                guard try candidateArchive.loadBatch() == batch,
                      run.photos.count == ids.count,
                      run.photos.map(\.id) == Array(ids.indices) else {
                    throw IdentityPhotoFailure(message: "写真と保存内容を照合できません。結果は変更せず、再開を止めました。")
                }
                session = CandidateReviewSession(run: run, progress: batch.progress, identifiers: ids)
            } catch is CancellationError {
            } catch let failure as IdentityPhotoFailure {
                if generation == token { message = failure.message }
            } catch {
                if generation == token { message = "処理を完了できませんでした。途中結果は採用せず、写真の選択は残しています。" }
            }
            guard generation == token else { return }
            running = false; task = nil
        }
    }

    private func updateProgress(_ count: Int, token: UUID) {
        guard token == generation, running else { return }
        progress = count
    }

    func suspend() {
        generation = UUID(); task?.cancel(); task = nil
        running = false; session = nil; picker = nil; pendingSelection = nil
    }

    func record(_ action: String) { session?.record(action) }

    @discardableResult func choose(_ choice: CandidateReviewChoice, for id: Int) -> Bool {
        commit { $0.choose(choice, for: id) }
    }
    func confirmGroup(_ choice: CandidateReviewChoice) { commit { $0.confirmGroup(choice) } }
    func toggleExcluded(_ id: Int) { commit { $0.toggleExcluded(id) } }
    func undo() { commit { $0.undo() } }
    @discardableResult func unconfirm(_ id: Int) -> Bool { commit { $0.unconfirm(id) } }

    @discardableResult private func commit(_ mutation: (inout CandidateReviewSession) -> Void) -> Bool {
        guard !blocked, !running, var next = session else { return false }
        mutation(&next)
        func keyed(_ decisions: [Int: CandidateReviewChoice]) -> [String: CandidateReviewChoice] {
            Dictionary(uniqueKeysWithValues: decisions.compactMap { index, choice in
                selected.indices.contains(index) ? (selected[index], choice) : nil
            })
        }
        do {
            guard try referenceArchive.load() == saved else { throw CocoaError(.fileReadCorruptFile) }
            let progress = CandidateSavedProgress(referenceFingerprint: try CandidateSavedProgress.fingerprint(saved),
                decisions: keyed(next.decisions), previousDecisions: next.previous.map { keyed($0.decisions) },
                excluded: Set(next.excluded.compactMap { selected.indices.contains($0) ? selected[$0] : nil }))
            try persist(.init(identifiers: selected, progress: progress))
            session = next
            return true
        } catch {
            storageWarning = "確認結果を保存できませんでした。確認・取消は変更していません。空き容量や見本の状態を確認して、もう一度お試しください。"
            return false
        }
    }

    private func persist(_ next: CandidateSavedBatch) throws {
        guard try candidateArchive.loadBatch() == batch else { throw CocoaError(.fileReadCorruptFile) }
        try candidateArchive.saveBatch(next)
        batch = next; savedConfirmationCount = next.progress?.decisions.count ?? 0
        hasArchivedSelection = !next.identifiers.isEmpty; storageWarning = nil
    }

    private func replaceSelection(_ ids: [String]) {
        do {
            guard try referenceArchive.load() == saved else { throw CocoaError(.fileReadCorruptFile) }
            try persist(.init(identifiers: ids))
            selected = ids; session = nil; pendingSelection = nil
        } catch { storageWarning = "新しい選択を保存できませんでした。以前の選択と確認結果は変更していません。" }
    }

    func confirmPendingSelection() {
        guard !running, !blocked, let ids = pendingSelection else { return }
        replaceSelection(ids)
    }

    // Explicit confirmation only. Preserve all selected photos; do not relabel old A/B decisions.
    func resetProgressForChangedReferences() {
        guard !running, requiresProgressReset, !referenceReadFailed, !candidateReadFailed else { return }
        do {
            guard try referenceArchive.load() == saved else { throw CocoaError(.fileReadCorruptFile) }
            try persist(.init(identifiers: selected))
            requiresProgressReset = false; message = nil
        } catch { storageWarning = "確認結果をリセットできませんでした。保存内容は残しています。" }
    }

    func clearCandidateSelection() {
        guard !running else { return }
        do {
            if candidateReadFailed {
                // The user may discard this corrupt file, but not a newer valid replacement.
                guard (try? candidateArchive.loadBatch()) == nil else {
                    storageWarning = "保存内容が変わりました。消去せずに止めました。この画面を開き直してください。"; return
                }
                try candidateArchive.save([])
            } else {
                try persist(.init(identifiers: []))
            } // Exact candidate file only; legacy references are untouched.
            suspend(); selected = []; candidateReadFailed = false; hasArchivedSelection = false; storageWarning = nil
            batch = .init(identifiers: []); savedConfirmationCount = 0; requiresProgressReset = false
            if !referenceReadFailed { message = nil }
        } catch { storageWarning = "選択を消去できませんでした。保存内容は残しています。この画面を開き直して確認してください。" }
    }
}
