import Photos
import SwiftUI

struct CandidatePickerRequest: Identifiable { let id = UUID() }

@MainActor
final class CandidateReviewStore: ObservableObject {
    @Published private(set) var selected: [String] = []
    @Published private(set) var saved: [IdentityPhotoSlot: [String]] = [:]
    @Published var picker: CandidatePickerRequest?
    @Published var differentScenes = false
    @Published private(set) var running = false
    @Published private(set) var progress = 0
    @Published var session: CandidateReviewSession?
    @Published private(set) var message: String?
    @Published private(set) var storageWarning: String?
    @Published private(set) var candidateReadFailed = false
    private var referenceReadFailed = false
    private var blocked: Bool { referenceReadFailed || candidateReadFailed }
    private let referenceArchive: IdentitySelectionArchive
    private let candidateArchive: CandidateSelectionArchive
    private let service = IdentityPhotoService()
    private let runner: (([IdentityPhotoSlot: [String]], [String]) async throws -> CandidateReviewRun)?
    private var generation = UUID()
    private var task: Task<Void, Never>?

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
        do { selected = try candidateArchive.load() }
        catch {
            candidateReadFailed = true
            message = "今回の写真選択を読み出せません。上書きしていません。「今回の写真選択を消去」で、この選択だけをやり直せます。見本は残ります。"
        }
    }

    var hasReferences: Bool { saved[.referenceA]?.count == 5 && saved[.referenceB]?.count == 5 }
    var canChoose: Bool { !blocked && !running && hasReferences }
    var canRun: Bool { canChoose && !selected.isEmpty && differentScenes }
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
            try CandidateReviewSelection.validate(values, saved: saved)
            guard values != selected else { return }
            selected = values
            session = nil
            differentScenes = false
            message = nil
            do { try candidateArchive.save(values); storageWarning = nil }
            catch { storageWarning = "選択の保存に失敗しました。この画面では使えますが、閉じると再選択が必要な場合があります。" }
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
                session = CandidateReviewSession(run: run)
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
        running = false; session = nil; picker = nil; differentScenes = false
    }

    func clearCandidateSelection() {
        guard !running else { return }
        do {
            try candidateArchive.save([]) // Exact candidate file only; legacy references are untouched.
            suspend(); selected = []; candidateReadFailed = false; storageWarning = nil
            if !referenceReadFailed { message = nil }
        } catch { storageWarning = "選択を消去できませんでした。保存内容は残しています。" }
    }
}
