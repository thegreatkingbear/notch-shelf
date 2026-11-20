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
        /// The note's plain text as Notes last reported it, title line included.
        var text: String
        let locked: Bool
        let editable: Bool
    }

    enum SaveState: Equatable { case idle, saving, saved, conflict }

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
    /// True while writing a note that Notes doesn't have yet.
    @Published private(set) var composing = false
    @Published private(set) var saveState = SaveState.idle
    /// Text shown in the editor. `editorToken` changes when the model replaces it.
    @Published private(set) var editorText = ""
    @Published private(set) var editorToken = 0
    @Published private(set) var focusToken = 0

    private var dirty = false
    private var editing = false
    private var saveTask: Task<Void, Never>?

    private let queue = DispatchQueue(label: "NotchShelf.notes")
    private var revision = 0
    private var detailRevision = 0
    /// A note saved from the card, shown until Notes includes it in its note list.
    private var pending: (item: Item, until: Date)?

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
                guard var items else { self.error = String(localized: "Couldn’t load notes."); return }
                self.error = nil
                if let pending = self.pending {
                    if items.contains(where: { $0.id == pending.item.id }) || Date() > pending.until { self.pending = nil }
                    else { items.insert(pending.item, at: 0) }
                }
                if items != self.items { self.items = items }
                if let selection = self.selection, !items.contains(where: { $0.id == selection }) { self.selection = nil }
                if self.selection == nil, !self.composing { self.selection = items.first?.id }
                self.loadDetail()
            }
        }
    }

    var canEdit: Bool { composing || (detail?.editable ?? false) }

    func select(_ item: Item) {
        guard selection != item.id || composing else { return }
        commit()
        composing = false
        selection = item.id
        loadDetail()
    }

    func open(_ id: String) {
        commit()
        queue.async { NotesReader.showNote(id) }
    }

    /// Starts an empty note in the editor; Notes gets it once there is text to save.
    func compose() {
        guard ready else { return }
        commit()
        composing = true
        selection = nil
        detail = nil
        saveState = .idle
        replaceEditor("")
        focusToken += 1
    }

    func edit(_ text: String) {
        guard canEdit, text != editorText else { return }
        editorText = text
        dirty = true
        if saveState != .conflict { saveState = .idle }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.commit()
        }
    }

    func setEditing(_ value: Bool) {
        editing = value
        if !value { commit() }
    }

    /// Saves pending editor changes now.
    func commit() {
        saveTask?.cancel()
        saveTask = nil
        guard dirty, saveState != .conflict, saveState != .saving else { return }
        let text = editorText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        dirty = false
        saveState = .saving
        if composing {
            queue.async {
                var message: NSString?
                let id = NotesReader.createNote(text, error: &message)
                DispatchQueue.main.async { self.created(id, text: text, message: message as String?) }
            }
        } else if let detail, detail.editable {
            let expected = detail.text
            queue.async {
                var conflict = ObjCBool(false)
                var message: NSString?
                let saved = NotesReader.updateNote(detail.id, expected: expected, text: text, conflict: &conflict, error: &message)
                DispatchQueue.main.async {
                    guard self.detail?.id == detail.id else { return }
                    if let saved {
                        self.detail?.text = saved
                        self.saveState = .saved
                        self.retitle(detail.id, from: text)
                        if self.dirty { self.commit() }
                    } else {
                        self.dirty = true
                        self.saveState = conflict.boolValue ? .conflict : .idle
                        self.error = conflict.boolValue
                            ? String(localized: "This note changed in Notes, so your edit wasn’t saved. Open it in Notes to check.")
                            : (message as String?) ?? String(localized: "Couldn’t save the note.")
                    }
                }
            }
        } else {
            saveState = .idle
        }
    }

    private func created(_ id: String?, text: String, message: String?) {
        guard let id else {
            dirty = true
            saveState = .idle
            error = message ?? String(localized: "Couldn’t save the note.")
            return
        }
        error = nil
        // Notes can take a moment to list a new note; show it right away.
        let item = Item(id: id, title: Self.title(of: text), modified: Date(), locked: false)
        pending = (item, Date().addingTimeInterval(15))
        items.removeAll { $0.id == id }
        items.insert(item, at: 0)
        composing = false
        selection = id
        detail = Detail(id: id, text: text, locked: false, editable: true)
        saveState = .saved
        if dirty { commit() }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if self.pending != nil { self.refresh() }
        }
    }

    private func retitle(_ id: String, from text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[index]
        items[index] = Item(id: id, title: Self.title(of: text), modified: Date(), locked: old.locked)
    }

    private static func title(of text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private func replaceEditor(_ text: String) {
        editorText = text
        editorToken += 1
        dirty = false
    }

    private func loadDetail() {
        detailRevision += 1
        let token = detailRevision
        guard let id = selection else {
            if !composing { detail = nil; replaceEditor("") }
            return
        }
        // Don't replace what the person is typing.
        if detail?.id == id, dirty || editing || saveState == .saving { return }
        if detail?.id != id { detail = nil; saveState = .idle; replaceEditor("") }
        queue.async {
            let row = NotesReader.note(withID: id)
            DispatchQueue.main.async {
                guard self.detailRevision == token, self.selection == id else { return }
                if self.detail?.id == id, self.dirty || self.editing || self.saveState == .saving { return }
                guard let row, row["name"] is String else {
                    if self.pending?.item.id != id { self.detail = nil }
                    return
                }
                let text = (row["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let next = Detail(id: id, text: text, locked: row["locked"] as? Bool ?? false,
                                  editable: row["editable"] as? Bool ?? false)
                if next != self.detail {
                    self.detail = next
                    if self.saveState == .conflict { self.saveState = .idle }
                    self.replaceEditor(text)
                }
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
            HStack(spacing: 8) {
                Text("Notes").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if model.ready {
                    status
                    Button { model.compose() } label: {
                        Image(systemName: "square.and.pencil").font(.system(size: 13))
                    }.buttonStyle(.plain).help("New Note").accessibilityLabel("New Note")
                    if let detail = model.detail, !model.composing {
                        Button { model.open(detail.id) } label: {
                            Image(systemName: "arrow.up.forward.app").font(.system(size: 13))
                        }.buttonStyle(.plain).help("Open in Notes").accessibilityLabel("Open in Notes")
                    }
                }
            }
            if model.ready {
                GeometryReader { geo in
                    HStack(alignment: .top, spacing: 8) {
                        list.frame(width: min(135, geo.size.width * 0.36))
                        Divider()
                        editor.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.yellow).lineLimit(2) }
            } else {
                Text("See recent notes and jot down new ones without leaving what you’re doing.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(model.permission == errAEEventNotPermitted ? String(localized: "Open Automation Settings") : String(localized: "Connect Notes")) {
                    model.connect()
                }.controlSize(.small).disabled(model.requesting)
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.yellow).lineLimit(2) }
                Spacer(minLength: 0)
            }
        }
        .task(id: active) {
            guard active else { model.commit(); return }
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

    @ViewBuilder private var status: some View {
        switch model.saveState {
        case .saving: Text("Saving…").font(.system(size: 10)).foregroundStyle(.secondary)
        case .saved: Text("Saved").font(.system(size: 10)).foregroundStyle(.secondary)
        case .conflict: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.yellow)
        case .idle:
            if let detail = model.detail, !detail.editable, !detail.locked, !model.composing {
                Text("View only").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("This note has images, lists or formatting. Open it in Notes to edit it.")
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if model.items.isEmpty {
                    Text(model.loading ? String(localized: "Loading…") : String(localized: "No notes yet."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.items) { item in row(item) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ item: NoteLibrary.Item) -> some View {
        let selected = model.selection == item.id && !model.composing
        let title = item.title.isEmpty ? String(localized: "New Note") : item.title
        return Button { model.select(item) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    if item.locked { Image(systemName: "lock.fill").font(.system(size: 8)) }
                    Text(verbatim: title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
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
        .help(Text(verbatim: title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var editor: some View {
        if let detail = model.detail, detail.locked, !model.composing {
            Label("This note is locked. Open it in Notes to view it.", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.secondary)
        } else if model.detail != nil || model.composing {
            NoteEditor(model: model)
                .overlay(alignment: .topLeading) {
                    if model.composing && model.editorText.isEmpty {
                        Text("Type a note. The first line becomes its title.")
                            .font(.system(size: 11.5)).foregroundStyle(.tertiary).allowsHitTesting(false)
                    }
                }
        } else {
            Text(model.selection == nil ? String(localized: "Select a note to read it here.") : String(localized: "Loading…"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A plain-text editor that can make the nonactivating panel key. Read-only notes stay selectable.
private struct NoteEditor: NSViewRepresentable {
    @ObservedObject var model: NoteLibrary

    final class TextView: NSTextView {
        override var needsPanelToBecomeKey: Bool { isEditable }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    static let bodyFont = NSFont.systemFont(ofSize: 11.5)
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .bold)

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        let model: NoteLibrary
        var token = -1
        var focus = 0
        init(_ model: NoteLibrary) { self.model = model }

        @MainActor func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { model.edit(view.string) }
        }
        /// Notes makes the first line the title, so show it bold as Notes does.
        func textStorage(_ storage: NSTextStorage, didProcessEditing actions: NSTextStorageEditActions,
                         range: NSRange, changeInLength delta: Int) {
            guard actions.contains(.editedCharacters) else { return }
            let text = storage.string as NSString
            let title = text.paragraphRange(for: NSRange(location: 0, length: 0))
            storage.addAttribute(.font, value: NoteEditor.bodyFont, range: NSRange(location: 0, length: text.length))
            storage.addAttribute(.font, value: NoteEditor.titleFont, range: title)
        }

        @MainActor func textDidBeginEditing(_ notification: Notification) { model.setEditing(true) }
        @MainActor func textDidEndEditing(_ notification: Notification) { model.setEditing(false) }

        @MainActor func textView(_ textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard command == #selector(NSResponder.cancelOperation(_:)) else { return false }
            textView.window?.makeFirstResponder(nil)
            textView.window?.resignKey()
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let text = TextView()
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineFragmentPadding = 0
        text.textContainerInset = .zero
        text.drawsBackground = false
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.font = Self.bodyFont
        text.textColor = NSColor.white.withAlphaComponent(0.9)
        text.insertionPointColor = .white
        text.setAccessibilityLabel(String(localized: "Note"))
        text.delegate = context.coordinator
        text.textStorage?.delegate = context.coordinator
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? TextView else { return }
        text.isEditable = model.canEdit
        text.isSelectable = true
        if context.coordinator.token != model.editorToken {
            context.coordinator.token = model.editorToken
            if text.string != model.editorText {
                text.string = model.editorText
                text.scrollToBeginningOfDocument(nil)
            }
        }
        if context.coordinator.focus != model.focusToken {
            context.coordinator.focus = model.focusToken
            DispatchQueue.main.async {
                guard let window = text.window else { return }
                window.makeKey()
                window.makeFirstResponder(text)
            }
        }
    }
}
