import Combine
import SwiftUI

// MARK: - 「この子」 page: the cat's records (11/13, 「記録が並ぶ」)
//
// Under the buttons: 「1年前のきょう」, 「さいきんの写真」 and 「{name}の記録」,
// each only when there is something in it. Nothing new is stored: the photos
// are the cat's photo set of the 写真 tab, the rest is read from the photo
// memos, 「この子のこと」 and 病院で見せる. The order and words are in
// CatHomeRecordsCore.swift.

/// What each cat's records are, read after the page is drawn and kept per
/// cat. The memos and vet memos are read on their stores' actors; the merge
/// runs off the main thread. Read again when either store saves, and when the
/// tab appears again.
@MainActor
final class CatHomeRecordsModel: ObservableObject {
    /// Bumped when the memos or vet memos may have changed; part of each page's key.
    @Published private(set) var sourcesRevision = 0
    @Published private(set) var snapshots: [String: CatHomeRecordsSnapshot] = [:]
    private var keys: [String: CatHomeRecordsKey] = [:]
    private var sources: (revision: Int, task: Task<Sources, Never>)?
    private var loadedOnce = false
    private var observer: AnyCancellable?

    struct Sources: Sendable {
        var memos: [PhotoMemoryNoteRecord] = []
        var visits: [VeterinaryVisit] = []
    }

    init() {
        observer = NotificationCenter.default.publisher(for: .appRecordsCommitted)
            .compactMap { ($0.object as? URL)?.path }
            .filter { $0.contains("/PhotoMemoryNotes") || $0.contains("/VeterinaryVisits") }
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    /// Reads the memos and vet memos again on the next look (nothing before the first).
    func refresh() {
        guard loadedOnce else { return }
        sourcesRevision &+= 1
    }

    func snapshot(_ catID: String) -> CatHomeRecordsSnapshot? { snapshots[catID] }

    /// The finished vet memo a row opens, as last read.
    func visit(_ id: UUID) async -> VeterinaryVisit? {
        await currentSources().visits.first { $0.id == id }
    }

    /// Builds one cat's records unless they are known for this key. Never
    /// blocks drawing: it waits a turn, reads on the stores' actors and
    /// merges on a background task.
    func load(_ key: CatHomeRecordsKey, photos: [PhotoPresentation]) async {
        guard keys[key.cat] != key else { return }
        await Task.yield()
        let sources = await currentSources()
        guard !Task.isCancelled else { return }
        let input = (catIDs: key.catIDs, weights: key.weights, vaccinations: key.vaccinations)
        let snapshot = await Task.detached(priority: .userInitiated) {
            CatHomeRecordsCore.snapshot(
                catIDs: input.catIDs, memos: sources.memos, visits: sources.visits,
                weights: input.weights, vaccinations: input.vaccinations,
                photos: photos.map { CatHomeRecordsCore.Photo(identifier: $0.localIdentifier, creationDate: $0.creationDate) },
                now: Date())
        }.value
        guard !Task.isCancelled else { return }
        keys[key.cat] = key
        if snapshots[key.cat] != snapshot { snapshots[key.cat] = snapshot }
    }

    /// One read of both stores per revision, shared by every page.
    private func currentSources() async -> Sources {
        if let sources, sources.revision == sourcesRevision { return await sources.task.value }
        let task = Task<Sources, Never> {
            let memos = (try? await PhotoMemoryNoteStore.shared.records()) ?? []
            let visits = (try? await VeterinaryVisitStore.shared.visits()) ?? []
            return Sources(memos: memos, visits: visits)
        }
        sources = (sourcesRevision, task)
        loadedOnce = true
        return await task.value
    }
}

/// When a cat's records must be built again: its IDs, what この子のこと has,
/// its photo set and the stores' revision.
struct CatHomeRecordsKey: Equatable, Sendable {
    var cat: String
    var catIDs: Set<UUID>
    var weights: [CatCareWeight]
    var vaccinations: [CatCareVaccination]
    var photoCount: Int
    var newestPhoto: String?
    var sources: Int
    var day: CatCareDay?

    init(cat: CatHomeCat, record: CatCareRecord?, photos: [PhotoPresentation], sources: Int, now: Date = Date()) {
        self.cat = cat.id
        catIDs = Set([UUID(uuidString: cat.id), record?.catID].compactMap { $0 })
        weights = record?.activeWeights ?? []
        vaccinations = record?.activeVaccinations ?? []
        photoCount = photos.count
        newestPhoto = photos.first?.localIdentifier
        self.sources = sources
        day = CatCareDay(date: now)
    }
}

extension View {
    /// Builds the page's records once it is drawn, again when its key changes.
    @MainActor
    func catHomeRecordsLoading(_ model: CatHomeRecordsModel, cat: CatHomeCat, record: CatCareRecord?,
                               photos: [PhotoPresentation]) -> some View {
        let key = CatHomeRecordsKey(cat: cat, record: record, photos: photos, sources: model.sourcesRevision)
        return task(id: key) { await model.load(key, photos: photos) }
    }
}

/// The blocks under the buttons. A Group, so a block with nothing takes no
/// space and no gap in the page's stack.
struct CatHomeRecordsSection: View {
    let cat: CatHomeCat
    let record: CatCareRecord?
    let photos: [PhotoPresentation]
    /// 「あと23日」 / 「きょう」 (CatHomeFacts), only within 30 days.
    let birthdayIn: String?
    let tools: CatHomeTools
    @ObservedObject var model: CatHomeRecordsModel

    var body: some View {
        let snapshot = model.snapshot(cat.id)
        Group {
            if let birthdayIn { CatHomeBirthdayCard(text: CatHomeRecordsCore.birthdayLine(birthdayIn)) }
            if let yearsAgo = snapshot?.yearsAgo {
                CatHomeYearsAgoCard(cat: cat, item: yearsAgo, tools: tools)
            }
            if let profile = cat.profile, !photos.isEmpty {
                CatHomePhotoStrip(profileID: profile.identifier, name: cat.name, photos: photos, tools: tools)
            }
            if let rows = snapshot?.rows, !rows.isEmpty {
                CatHomeRecordsCard(cat: cat, catID: record?.catID, rows: rows, tools: tools, model: model)
            }
        }
    }
}

// MARK: - Blocks

/// 「誕生日まで あと23日」 / 「きょうは誕生日」, only within 30 days.
private struct CatHomeBirthdayCard: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "birthday.cake")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.pink)
                .accessibilityHidden(true)
            Text(text)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .catHomeCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cat-home-birthday")
    }
}

/// 「1年前のきょう」: the photo, the label and the memo's first words.
private struct CatHomeYearsAgoCard: View {
    let cat: CatHomeCat
    let item: CatHomeYearsAgo
    let tools: CatHomeTools
    @Environment(\.catProfilePhotoDestination) private var photoDestination

    var body: some View {
        if let destination {
            NavigationLink { destination } label: { content }
                .buttonStyle(CatHomeRecordPressStyle())
                .accessibilityIdentifier("cat-home-years-ago")
        }
    }

    /// The memo opens as the memo list opens it; a photo as the cat's photos do.
    private var destination: AnyView? {
        switch item.source {
        case let .memo(recordID): return tools.memoPhoto(recordID)
        case .photo:
            guard let profile = cat.profile, let photoDestination else { return nil }
            return photoDestination(profile.identifier, item.photoIdentifier)
        }
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 14) {
            CatHomeThumbnail(identifier: item.photoIdentifier, side: 84, radius: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let text = item.text {
                    Text(text)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .catHomeCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.label, item.text].compactMap { $0 }.joined(separator: "、"))
    }
}

/// 「さいきんの写真」 with the count, and the newest photos in a row.
private struct CatHomePhotoStrip: View {
    let profileID: String
    let name: String
    let photos: [PhotoPresentation]
    let tools: CatHomeTools
    @Environment(\.catProfilePhotoDestination) private var photoDestination

    static let shown = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CatHomeBlockHeading(text: "さいきんの写真")
                Spacer(minLength: 8)
                Button { tools.showPhotos(profileID) } label: {
                    HStack(spacing: 3) {
                        Text("\(photos.count.formatted())枚")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(name)の写真、\(photos.count)枚")
                .accessibilityHint("写真タブで開きます")
                .accessibilityIdentifier("cat-home-photos-all")
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(Array(photos.prefix(Self.shown).enumerated()), id: \.element.localIdentifier) { index, photo in
                        cell(photo)
                            .accessibilityIdentifier("cat-home-photo-\(index)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            // To the screen's edges, the first photo in line with the cards.
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .padding(.horizontal, -16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cat-home-photos")
    }

    @ViewBuilder private func cell(_ photo: PhotoPresentation) -> some View {
        let thumbnail = CatHomeThumbnail(identifier: photo.localIdentifier, box: photo.catBoundingBox, side: 104, radius: 14)
        let label = photo.creationDate.flatMap { CatCareDay(date: $0) }
            .map { "\($0.year)年\($0.month)月\($0.day)日の写真" } ?? "写真"
        if let photoDestination {
            NavigationLink { photoDestination(profileID, photo.localIdentifier) } label: { thumbnail }
                .buttonStyle(CatHomeRecordPressStyle())
                .accessibilityLabel(label)
        } else {
            thumbnail.accessibilityLabel(label)
        }
    }
}

/// 「{name}の記録」: the newest five, then 20 more per 「もっと見る」.
private struct CatHomeRecordsCard: View {
    let cat: CatHomeCat
    /// The cat's 「この子のこと」 (the weight and vaccination lists).
    let catID: UUID?
    let rows: [CatHomeRecordRow]
    let tools: CatHomeTools
    @ObservedObject var model: CatHomeRecordsModel
    @State private var shown = CatHomeRecordsCore.firstRows
    @State private var openedVisit: VeterinaryVisit?

    var body: some View {
        let visible = Array(rows.prefix(shown))
        VStack(alignment: .leading, spacing: 10) {
            CatHomeBlockHeading(text: "\(cat.name)の記録")
            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, 16) }
                    entry(row)
                        .accessibilityIdentifier("cat-home-record-\(index)")
                }
                if rows.count > shown {
                    Divider().padding(.leading, 16)
                    Button { shown += CatHomeRecordsCore.moreRows } label: {
                        HStack {
                            Text("もっと見る")
                                .font(.body)
                                .foregroundStyle(Color.accentColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CatHomeRecordPressStyle())
                    .accessibilityIdentifier("cat-home-records-more")
                }
            }
            .catHomeCard()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cat-home-records")
        .sheet(item: $openedVisit, onDismiss: { model.refresh() }) { visit in
            tools.vetMemo(visit)
        }
    }

    @ViewBuilder private func entry(_ row: CatHomeRecordRow) -> some View {
        let label = CatHomeRecordRowView(row: row)
        switch row.kind {
        case let .memo(recordID, _):
            NavigationLink { tools.memoPhoto(recordID) } label: { label }
                .buttonStyle(CatHomeRecordPressStyle())
        case .weight:
            careList(.weight, label)
        case .vaccination:
            careList(.vaccination, label)
        case let .vet(visitID):
            Button {
                Task { openedVisit = await model.visit(visitID) }
            } label: { label }
                .buttonStyle(CatHomeRecordPressStyle())
        }
    }

    @ViewBuilder private func careList(_ kind: CatCareListEditor.Kind, _ label: CatHomeRecordRowView) -> some View {
        if let catID {
            NavigationLink { CatHomeCareListPage(kind: kind, catID: catID) } label: { label }
                .buttonStyle(CatHomeRecordPressStyle())
        } else {
            label
        }
    }
}

/// A row: the date in a narrow column, the record and its small line, the
/// memo's photo, a chevron. At the accessibility sizes the date goes on top.
private struct CatHomeRecordRowView: View {
    let row: CatHomeRecordRow
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var dateWidth: CGFloat = 74

    var body: some View {
        HStack(spacing: 10) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                Text(row.dateText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: typeSize.isAccessibilitySize ? nil : dateWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let caption = row.caption {
                        Text(caption)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if case let .memo(_, photo) = row.kind {
                CatHomeThumbnail(identifier: photo, side: 44, radius: 8)
            }
            ToolChevron()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken)
    }
}

/// 体重 or ワクチン of 「この子のこと」, as its own list opens it there:
/// a row opens the same form, and a change is saved the same way.
private struct CatHomeCareListPage: View {
    let kind: CatCareListEditor.Kind
    let catID: UUID
    @ObservedObject private var store = CatCareStore.shared
    @State private var editing: CatCareListEditor?
    @State private var saveFailed = false

    var body: some View {
        CatCareListView(kind: kind, catID: catID, editing: $editing)
            .sheet(item: $editing) { editor in
                CatCareListEntrySheet(editor: editor, catID: catID) { result in apply(result) }
            }
            .alert("保存できませんでした", isPresented: $saveFailed) {
                Button("閉じる", role: .cancel) {}
            } message: {
                Text("少し待ってから、もう一度お試しください。")
            }
    }

    private func apply(_ result: CatCareListEditor.Result) {
        let saved = store.update { state in
            guard let index = state.cats.firstIndex(where: { $0.catID == catID }) else { return }
            result.apply(to: &state.cats[index], by: state.deviceID, now: Date())
        }
        if !saved { saveFailed = true }
    }
}

// MARK: - Parts

/// A block's small heading: 「さいきんの写真」, 「むぎの記録」.
private struct CatHomeBlockHeading: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
            .padding(.leading, 4)
    }
}

/// A square photo from the shared thumbnail cache, the photo filling it.
private struct CatHomeThumbnail: View {
    let identifier: String
    var box: CGRect? = nil
    let side: CGFloat
    let radius: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let pixels = (side * max(displayScale, 1)).rounded()
        PhotoAssetImageView(localIdentifier: identifier, catBoundingBox: box,
                            targetPixelSize: CGSize(width: pixels, height: pixels), targetAspectRatio: 1)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct CatHomeRecordPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private extension View {
    /// The page's card: the grouped surface, 16pt corners.
    func catHomeCard() -> some View {
        background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
