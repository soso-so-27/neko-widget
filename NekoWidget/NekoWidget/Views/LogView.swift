import SwiftUI
import UIKit

@MainActor
private final class LogViewModel: ObservableObject {
    @Published private(set) var entries: [SharedLogEntry] = []
    @Published private(set) var malformedLineCount = 0
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let store = AppLogStore()

    var formattedText: String {
        SharedLog.formattedText(for: entries)
    }

    func refresh() async {
        isLoading = true
        let result = await store.load()
        entries = result.entries
        malformedLineCount = result.malformedLineCount
        isLoading = false
    }

    func clear() async {
        await store.clear()
        entries = []
        malformedLineCount = 0
    }

    func makeExportFile() async -> URL? {
        do {
            return try await store.makeExportFile()
        } catch {
            SharedLog.app.error(
                "diagnostics",
                "Diagnostic log export failed",
                metadata: SharedLog.errorMetadata(error, category: .diagnostics)
            )
            errorMessage = "診断情報を書き出せませんでした。iPhoneの空き容量を確かめて、もう一度お試しください。"
            return nil
        }
    }
}

struct LogView: View {
    @StateObject private var viewModel = LogViewModel()
    @State private var exportFile: LogExportFile?
    @State private var showsClearConfirmation = false
    @State private var showsCopiedConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()

            ScrollView([.horizontal, .vertical]) {
                Text(logText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(uiColor: .secondarySystemBackground))

            Divider()
            actionBar
        }
        .navigationTitle("診断情報")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.refresh()
        }
        .refreshable {
            await viewModel.refresh()
        }
        .sheet(item: $exportFile, onDismiss: cleanupDiagnosticExport) { file in
            LogActivityView(activityItems: [file.url])
                .presentationDetents([.medium, .large])
        }
        .onDisappear(perform: cleanupDiagnosticExport)
        .confirmationDialog(
            "診断情報をすべて削除しますか？",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("すべて削除", role: .destructive) {
                Task { await viewModel.clear() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("削除しても、アプリを使うとまた記録されます。")
        }
        .alert("コピーしました", isPresented: $showsCopiedConfirmation) {
            Button("閉じる", role: .cancel) {}
        }
        .alert(
            "書き出せませんでした",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("閉じる", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "もう一度お試しください。")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Text("\(viewModel.entries.count.formatted())件")
                .font(.caption.weight(.semibold))
            Text("アプリとウィジェットの記録（時刻順）")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if viewModel.malformedLineCount > 0 {
                Label(
                    "読めなかった記録 \(viewModel.malformedLineCount)行",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label("更新", systemImage: "arrow.clockwise")
            }

            Button {
                UIPasteboard.general.string = viewModel.formattedText
                showsCopiedConfirmation = true
            } label: {
                Label("コピー", systemImage: "doc.on.doc")
            }
            .disabled(viewModel.entries.isEmpty)

            Button {
                Task {
                    cleanupDiagnosticExport()
                    if let url = await viewModel.makeExportFile() {
                        exportFile = LogExportFile(url: url)
                    }
                }
            } label: {
                Label("共有", systemImage: "square.and.arrow.up")
            }

            Spacer(minLength: 0)

            Button(role: .destructive) {
                showsClearConfirmation = true
            } label: {
                Label("削除", systemImage: "trash")
            }
            .disabled(viewModel.entries.isEmpty)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(10)
        .accessibilityElement(children: .contain)
    }

    private var logText: String {
        if viewModel.isLoading, viewModel.entries.isEmpty {
            return "読み込み中…"
        }
        if viewModel.entries.isEmpty {
            return "まだ記録はありません。\nアプリやウィジェットを使ったあとに、もう一度開いてください。"
        }
        return viewModel.formattedText
    }

    private func cleanupDiagnosticExport() {
        TemporaryExportFileLifecycle.removeManagedFile(at: exportFile?.url)
        exportFile = nil
    }
}

private struct LogExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct LogActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
