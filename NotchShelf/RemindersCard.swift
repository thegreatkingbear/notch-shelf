import SwiftUI
@preconcurrency import EventKit

@MainActor
final class ReminderList: ObservableObject {
    struct Item: Identifiable {
        let id: String
        let title: String
    }

    @Published private(set) var access = EKEventStore.authorizationStatus(for: .reminder)
    @Published private(set) var listName: String?
    @Published private(set) var items: [Item] = []
    @Published private(set) var loading = false
    @Published private(set) var requesting = false
    @Published private(set) var error: String?
    @Published var draft = ""

    private let store = EKEventStore()
    private var revision = 0

    func connect() async {
        guard !requesting else { return }
        if EKEventStore.authorizationStatus(for: .reminder) == .denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        requesting = true
        defer { requesting = false }
        do { _ = try await store.requestFullAccessToReminders() }
        catch { self.error = error.localizedDescription }
        refresh()
    }

    func refresh() {
        revision += 1
        let token = revision
        access = EKEventStore.authorizationStatus(for: .reminder)
        guard access == .fullAccess, let list = store.defaultCalendarForNewReminders() else {
            listName = nil
            items = []
            loading = false
            return
        }
        if listName != list.title { items = [] }
        listName = list.title
        loading = true
        let query = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list])
        store.fetchReminders(matching: query) { reminders in
            let rows = reminders?.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
                .map { Item(id: $0.calendarItemIdentifier, title: $0.title ?? "") }
            Task { @MainActor in
                guard self.revision == token else { return }
                self.loading = false
                if let rows { self.items = rows }
                else { self.error = String(localized: "Couldn’t load the list.") }
            }
        }
    }

    func add() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard let list = store.defaultCalendarForNewReminders(), list.allowsContentModifications else {
            error = String(localized: "Choose a writable default list in Reminders.")
            return
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = title
        do {
            try store.save(reminder, commit: true)
            draft = ""
            error = nil
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    func complete(_ item: Item) {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { refresh(); return }
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
            error = nil
        } catch {
            _ = reminder.refresh()
            self.error = error.localizedDescription
        }
        refresh()
    }
}

private struct ReminderTitleField: NSViewRepresentable {
    @ObservedObject var model: ReminderList

    final class Field: NSTextField {
        override var needsPanelToBecomeKey: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: ReminderList
        init(_ model: ReminderList) { self.model = model }

        @MainActor func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { model.draft = field.stringValue }
        }

        @MainActor func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            if command == #selector(NSResponder.insertNewline(_:)) {
                model.add()
                if !model.draft.isEmpty { return true }
            } else if command != #selector(NSResponder.cancelOperation(_:)) { return false }
            control.window?.makeFirstResponder(nil)
            control.window?.resignKey()
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSTextField {
        let field = Field()
        field.placeholderString = String(localized: "New Reminder")
        field.setAccessibilityLabel(String(localized: "New Reminder"))
        field.isBordered = false
        field.drawsBackground = false
        field.usesSingleLineMode = true
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != model.draft { field.stringValue = model.draft }
    }
}

struct RemindersCard: View {
    let active: Bool
    @ObservedObject var model: ReminderList

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Reminders").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let name = model.listName {
                    Text(verbatim: name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(Text(verbatim: name))
                }
            }
            if model.access == .fullAccess {
                if model.listName == nil {
                    Text("Choose a default list in Reminders.").font(.caption)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            if model.items.isEmpty {
                                Text(model.loading ? String(localized: "Loading…") : String(localized: "No incomplete reminders."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(model.items) { item in
                                HStack(spacing: 7) {
                                    Button { model.complete(item) } label: {
                                        Image(systemName: "circle").foregroundStyle(.secondary)
                                    }.buttonStyle(.plain).accessibilityLabel("Mark \(item.title) complete")
                                    Text(item.title).lineLimit(1).font(.system(size: 12))
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    HStack(spacing: 6) {
                        ReminderTitleField(model: model).frame(height: 20)
                        Button { model.add() } label: {
                            Image(systemName: "plus.circle.fill").font(.system(size: 16))
                        }.buttonStyle(.plain).accessibilityLabel("Add Reminder")
                            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } else if model.access == .restricted {
                Text("Access to Reminders is restricted on this Mac.").font(.caption)
            } else {
                Button(model.access == .denied ? String(localized: "Open Reminders Settings") : String(localized: "Connect Reminders")) {
                    Task { await model.connect() }
                }.controlSize(.small).disabled(model.requesting)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.yellow).lineLimit(2) }
            Spacer(minLength: 0)
        }
        .task(id: active) { if active { model.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in if active { model.refresh() } }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in
            if active { model.refresh() }
        }
    }
}
