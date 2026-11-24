import AppKit
import SwiftUI

final class HistoryModel: ObservableObject {
    static let retentionChoices: [(days: Int, title: String)] = [
        (7, "1 week"), (30, "1 month"), (60, "2 months"), (180, "6 months"), (0, "Never"),
    ]

    @Published var items: [History.Item] = []
    @Published var usage: Int64 = 0
    @Published var playingID: String?
    @Published var retentionDays: Int = History.retentionDays {
        didSet {
            guard retentionDays != oldValue else { return }
            History.retentionDays = retentionDays
            History.cleanup()
        }
    }

    private var player: NSSound?
    private var observer: NSObjectProtocol?
    private var pendingSaves: [String: DispatchWorkItem] = [:]

    init() {
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: History.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        player?.stop()
    }

    func reload() {
        items = History.loadAll()
        usage = History.diskUsage()
    }

    func copy(_ item: History.Item) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.entry.final, forType: .string)
    }

    func togglePlay(_ item: History.Item) {
        player?.stop()
        if playingID == item.id {
            playingID = nil
            return
        }
        player = NSSound(contentsOf: item.wav, byReference: true)
        player?.play()
        playingID = item.id
        let duration = item.entry.durationSeconds
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.2) { [weak self] in
            if self?.playingID == item.id { self?.playingID = nil }
        }
    }

    func delete(_ item: History.Item) {
        if playingID == item.id { player?.stop(); playingID = nil }
        History.trash([item])
    }

    func deleteAll() {
        player?.stop()
        playingID = nil
        History.trash(items)
    }

    /// Saves an edited transcript shortly after the last keystroke.
    func scheduleSave(_ item: History.Item) {
        pendingSaves[item.id]?.cancel()
        let work = DispatchWorkItem { History.update(item) }
        pendingSaves[item.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flushSaves() {
        for (id, work) in pendingSaves {
            work.cancel()
            if let item = items.first(where: { $0.id == id }) { History.update(item) }
        }
        pendingSaves.removeAll()
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    @State private var search = ""
    @State private var confirmDeleteAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Spacer()
                Text("\(model.items.count) recordings · \(ByteCountFormatter.string(fromByteCount: model.usage, countStyle: .file))")
                    .foregroundStyle(.secondary)
            }

            if model.items.isEmpty {
                Text("No dictations yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach($model.items) { $item in
                        if matches(item) {
                            row($item)
                        }
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(maxHeight: .infinity)
            }

            HStack {
                Picker("Delete recordings older than", selection: $model.retentionDays) {
                    ForEach(HistoryModel.retentionChoices, id: \.days) { choice in
                        Text(choice.title).tag(choice.days)
                    }
                }
                .frame(maxWidth: 330)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.open(AppPaths.history) }
                Button("Delete All…", role: .destructive) { confirmDeleteAll = true }
                    .disabled(model.items.isEmpty)
            }
            Text("Edits save automatically. Deleted recordings go to the Trash; old ones are removed for good by the setting above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 620, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity, alignment: .top)
        .confirmationDialog("Move all \(model.items.count) recordings to the Trash?",
                            isPresented: $confirmDeleteAll) {
            Button("Move to Trash", role: .destructive) { model.deleteAll() }
        }
    }

    private func row(_ item: Binding<History.Item>) -> some View {
        let value = item.wrappedValue
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(value.entry.date, format: .dateTime.day().month(.abbreviated).hour().minute())
                    .font(.caption.weight(.semibold))
                Text(String(format: "%.1f s", value.entry.durationSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { model.togglePlay(value) } label: {
                    Image(systemName: model.playingID == value.id ? "stop.fill" : "play.fill")
                }
                .help("Play the recording")
                Button { model.copy(value) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy the text")
                Button { model.delete(value) } label: { Image(systemName: "trash") }
                    .help("Move to Trash")
            }
            .buttonStyle(.borderless)

            TextField("", text: item.entry.final, axis: .vertical)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .lineLimit(1...8)
                .onChange(of: value.entry.final) { model.scheduleSave(item.wrappedValue) }

            if value.entry.raw != value.entry.final {
                Text("Heard: " + value.entry.raw)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func matches(_ item: History.Item) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty
            || item.entry.final.localizedCaseInsensitiveContains(query)
            || item.entry.raw.localizedCaseInsensitiveContains(query)
    }
}

/// Owns the History window; reopening brings the same window forward.
final class HistoryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: HistoryModel?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = HistoryModel()
        let window = NSWindow(contentViewController: NSHostingController(rootView: HistoryView(model: model)))
        window.title = "HearMe History"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 680, height: 600))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        self.model = model
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.flushSaves()
        model = nil
        window = nil
    }
}
