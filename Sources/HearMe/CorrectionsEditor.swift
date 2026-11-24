import AppKit
import SwiftUI

/// One "heard → write as" pair in the editor.
struct CorrectionRow: Identifiable, Equatable {
    let id = UUID()
    var heard: String
    var replacement: String
}

final class CorrectionsModel: ObservableObject {
    @Published var rows: [CorrectionRow] = []
    private var pendingSave: DispatchWorkItem?

    init() {
        reload()
    }

    func reload() {
        rows = Corrections.load()
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { CorrectionRow(heard: $0.key, replacement: $0.value) }
    }

    /// Rows that will actually be saved: blank "heard" cells are skipped, and for a
    /// repeated "heard" the lower row wins.
    var table: [String: String] {
        var table: [String: String] = [:]
        for row in rows {
            let key = row.heard.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            table[key] = row.replacement.trimmingCharacters(in: .whitespaces)
        }
        return table
    }

    func isDuplicate(_ row: CorrectionRow) -> Bool {
        let key = row.heard.trimmingCharacters(in: .whitespaces)
        return !key.isEmpty && rows.filter { $0.heard.trimmingCharacters(in: .whitespaces) == key }.count > 1
    }

    func add() {
        rows.insert(CorrectionRow(heard: "", replacement: ""), at: 0)
    }

    func remove(_ id: UUID) {
        rows.removeAll { $0.id == id }
    }

    /// Saves shortly after the last keystroke, so typing doesn't rewrite the file each letter.
    func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        Corrections.save(table)
    }
}

struct CorrectionsView: View {
    @ObservedObject var model: CorrectionsModel
    @State private var search = ""
    @State private var sample = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                Text("\(model.table.count) terms").foregroundStyle(.secondary)
                Button {
                    search = ""
                    model.add()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            HStack {
                Text("Heard (as the model writes it)").frame(maxWidth: .infinity, alignment: .leading)
                Text("Write as").frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 24, height: 1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)

            List {
                ForEach($model.rows) { $row in
                    if matches(row) {
                        HStack(spacing: 8) {
                            TextField("e.g. لارافيل", text: $row.heard)
                                .multilineTextAlignment(.trailing)
                                .overlay(alignment: .leading) {
                                    if model.isDuplicate(row) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                            .help("This word is listed more than once. The lower row wins.")
                                    }
                                }
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            TextField("e.g. Laravel", text: $row.replacement)
                            Button {
                                model.remove(row.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete")
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(maxHeight: .infinity)

            GroupBox("Try it") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Type a sentence the way the model wrote it", text: $sample)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Text(sample.isEmpty ? " " : Corrections.apply(sample, table: model.table))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            Text("Saved automatically. Changes apply to your next dictation. Hamza forms, ه/ة, ي/ى and tashkeel are matched loosely.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.rows) { model.scheduleSave() }
    }

    private func matches(_ row: CorrectionRow) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        // New, still-empty rows stay visible so you can fill them in.
        if row.heard.isEmpty && row.replacement.isEmpty { return true }
        return row.heard.localizedCaseInsensitiveContains(query)
            || row.replacement.localizedCaseInsensitiveContains(query)
    }
}

/// Owns the editor window; reopening brings the same window forward.
final class CorrectionsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: CorrectionsModel?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        Corrections.ensureFile()
        let model = CorrectionsModel()
        let window = NSWindow(contentViewController: NSHostingController(rootView: CorrectionsView(model: model)))
        window.title = "HearMe Corrections"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 620, height: 560))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        self.model = model
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.saveNow()
        model = nil
        window = nil
    }
}
