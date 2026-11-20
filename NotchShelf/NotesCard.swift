import SwiftUI

@MainActor
final class NoteLibrary: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let modified: Date
        let locked: Bool
    }

    struct Detail: Equatable {
        let id: String
        let title: String
        let text: String
        let locked: Bool
    }

    private static let connectedKey = "NotesConnected"
    nonisolated private static let limit = 40

    @Published private(set) var permission = Int32(errAEEventWouldRequireUserConsent)
    @Published private(set) var items: [Item] = []
    @Published private(set) var detail: Detail?
    @Published private(set) var loading = false
    @Published private(set) var requesting = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published var selection: String?
    @Published var draft = ""

    private let queue = DispatchQueue(label: "NotchShelf.notes")
    private var revision = 0
    private var detailRevision = 0

    /// Whether this Mac has allowed automation before, so the card can start Notes on its own.
    private var connected: Bool {
        get { UserDefaults.standard.bool(forKey: Self.connectedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.connectedKey) }
    }

    var ready: Bool { permission == noErr }

    func connect() {
        guard !requesting else { return }
        if permission == errAEEventNotPermitted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        requesting = true
        launchNotes { [weak self] in self?.refresh(ask: true) }
    }

    func refresh(ask: Bool = false) {
        guard ask || connected || NotesReader.isRunning() else { return }
        if !NotesReader.isRunning() {
            launchNotes { [weak self] in self?.refresh(ask: ask) }
            return
        }
        revision += 1
        let token = revision
        loading = true
        queue.async {
            let access = NotesReader.permissionAsk(ask)
            let rows = access == noErr ? NotesReader.recentNotes(Self.limit) : nil
            let items = rows?.compactMap { row -> Item? in
                guard let id = row["id"] as? String else { return nil }
                return Item(id: id, title: row["name"] as? String ?? "", modified: row["date"] as? Date ?? .distantPast,
                            locked: row["locked"] as? Bool ?? false)
            }
            DispatchQueue.main.async {
                if ask { self.requesting = false }
                guard self.revision == token else { return }
                self.loading = false
                self.permission = access
                if access == noErr { self.connected = true }
                guard access == noErr else { self.items = []; self.detail = nil; return }
                guard let items else { self.error = String(localized: "Couldn’t load notes."); return }
                self.error = nil
                if items != self.items { self.items = items }
                if let selection = self.selection, !items.contains(where: { $0.id == selection }) { self.selection = nil }
                self.loadDetail()
            }
        }
    }

    func select(_ item: Item) {
        selection = selection == item.id ? nil : item.id
        loadDetail()
    }

    func open(_ id: String) {
        queue.async { NotesReader.showNote(id) }
    }

    func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, ready, !saving else { return }
        saving = true
        queue.async {
            var message: NSString?
            let id = NotesReader.createNote(text, error: &message)
            DispatchQueue.main.async {
                self.saving = false
                guard let id else {
                    self.error = (message as String?) ?? String(localized: "Couldn’t save the note.")
                    return
                }
                if self.draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { self.draft = "" }
                self.error = nil
                self.selection = id
                self.refresh()
            }
        }
    }

    private func loadDetail() {
        detailRevision += 1
        let token = detailRevision
        guard let id = selection else { detail = nil; return }
        if detail?.id != id { detail = nil }
        queue.async {
            let row = NotesReader.note(withID: id)
            DispatchQueue.main.async {
                guard self.detailRevision == token else { return }
                guard let row, let title = row["name"] as? String else { self.detail = nil; return }
                var text = row["text"] as? String ?? ""
                // Notes makes the first line the title; avoid showing it twice.
                if let first = text.firstIndex(where: \.isNewline), text[..<first].trimmingCharacters(in: .whitespaces) == title {
                    text = String(text[text.index(after: first)...])
                } else if text.trimmingCharacters(in: .whitespaces) == title { text = "" }
                self.detail = Detail(id: id, title: title, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                     locked: row["locked"] as? Bool ?? false)
            }
        }
    }

    private func launchNotes(then next: @escaping @MainActor () -> Void) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") else {
            requesting = false
            error = String(localized: "Notes isn’t installed on this Mac.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, failure in
            Task { @MainActor in
                if app == nil {
                    self.requesting = false
                    self.error = failure?.localizedDescription ?? String(localized: "Couldn’t open Notes.")
                    return
                }
                // Notes answers Apple events shortly after it finishes launching.
                try? await Task.sleep(for: .milliseconds(600))
                next()
            }
        }
    }
}

struct NotesCard: View {
    let active: Bool
    @ObservedObject var model: NoteLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if model.ready {
                GeometryReader { geo in
                    HStack(alignment: .top, spacing: 10) {
                        list.frame(width: min(170, geo.size.width * 0.42))
                        Divider()
                        preview.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
                HStack(spacing: 6) {
                    CardTextField(placeholder: String(localized: "New Note"), text: $model.draft) {
                        model.add()
                        return false
                    }.frame(height: 20)
                    Button { model.add() } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: 16))
                    }.buttonStyle(.plain).accessibilityLabel("Add Note")
                        .disabled(model.saving || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text("Notes").font(.system(size: 13, weight: .semibold))
                Text("See recent notes and jot down new ones without leaving what you’re doing.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(model.permission == errAEEventNotPermitted ? String(localized: "Open Automation Settings") : String(localized: "Connect Notes")) {
                    model.connect()
                }.controlSize(.small).disabled(model.requesting)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.yellow).lineLimit(2) }
            if !model.ready { Spacer(minLength: 0) }
        }
        .task(id: active) {
            guard active else { return }
            model.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                model.refresh()
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in
            if active { model.refresh() }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notes").font(.system(size: 13, weight: .semibold))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.items.isEmpty {
                        Text(model.loading ? String(localized: "Loading…") : String(localized: "No notes yet."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.items) { item in row(item) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(_ item: NoteLibrary.Item) -> some View {
        let selected = model.selection == item.id
        let title = item.title.isEmpty ? String(localized: "New Note") : item.title
        return Button { model.select(item) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    if item.locked { Image(systemName: "lock.fill").font(.system(size: 8)) }
                    Text(verbatim: title).font(.system(size: 12)).lineLimit(1)
                }
                Text(item.modified, format: Calendar.autoupdatingCurrent.isDateInToday(item.modified)
                     ? .dateTime.hour().minute() : .dateTime.year(.twoDigits).month().day())
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.white.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var preview: some View {
        if let detail = model.detail {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(verbatim: detail.title.isEmpty ? String(localized: "New Note") : detail.title)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { model.open(detail.id) } label: {
                        Image(systemName: "arrow.up.forward.app").font(.system(size: 13))
                    }.buttonStyle(.plain).help("Open in Notes").accessibilityLabel("Open in Notes")
                }
                if detail.locked {
                    Label("This note is locked. Open it in Notes to view it.", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(verbatim: detail.text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else {
            Text(model.selection == nil ? String(localized: "Select a note to read it here.") : String(localized: "Loading…"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
