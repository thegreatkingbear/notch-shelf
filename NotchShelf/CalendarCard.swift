import SwiftUI
@preconcurrency import EventKit

private struct AgendaEntry: Identifiable {
    let id: String
    let title: String
    let start: Date
    let allDay: Bool
    let color: Color
}

private actor CalendarReader {
    private let store = EKEventStore()

    func connect() async { _ = try? await store.requestFullAccessToEvents() }

    func entries(on date: Date) -> [AgendaEntry] {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let query = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: query).filter { $0.startDate < end && ($0.endDate > start || $0.startDate >= start) }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                AgendaEntry(id: "\(event.calendarItemIdentifier)/\(event.startDate.timeIntervalSinceReferenceDate)",
                            title: event.title ?? String(localized: "Event"), start: event.startDate, allDay: event.isAllDay,
                            color: event.calendar.cgColor.map { Color(cgColor: $0) } ?? .mint)
            }
    }
}

@MainActor
private final class Agenda: ObservableObject {
    @Published var entries = [AgendaEntry]()
    @Published var access = EKEventStore.authorizationStatus(for: .event)
    @Published var requesting = false
    private let reader = CalendarReader()
    private var revision = 0
    private var displayedDay: Date?

    func connect() async {
        guard !requesting else { return }
        requesting = true
        defer { requesting = false }
        if access == .denied || access == .restricted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        } else {
            await reader.connect()
        }
    }

    func refresh(on date: Date) {
        revision += 1
        let token = revision
        let day = Calendar.autoupdatingCurrent.startOfDay(for: date)
        if day != displayedDay { entries = []; displayedDay = day }
        access = EKEventStore.authorizationStatus(for: .event)
        guard access == .fullAccess else { entries = []; return }
        Task {
            let rows = await reader.entries(on: day)
            if revision == token { entries = rows }
        }
    }
}

struct CalendarCard: View {
    let active: Bool
    @State private var selectedDate: Date?
    @State private var browsedMonth: Date?
    private var selectedDay: Date { selectedDate ?? .now }
    @StateObject private var agenda = Agenda()
    @Environment(\.calendar) private var calendar
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(calendar.isDateInToday(selectedDay) ? String(localized: "Today’s Events") : String(localized: "Events for \(selectedDay.formatted(.dateTime.month().day()))")).font(.system(size: 13, weight: .semibold))
                    if agenda.access != .fullAccess {
                        Button(agenda.access == .denied || agenda.access == .restricted ? String(localized: "Open Calendar Settings") : String(localized: "Connect Calendar")) {
                            Task { await agenda.connect(); agenda.refresh(on: selectedDay) }
                        }.controlSize(.small).disabled(agenda.requesting)
                    } else if agenda.entries.isEmpty {
                        Text("No events on this day.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(agenda.entries) { entry in
                                    HStack(spacing: 6) {
                                        Capsule().fill(entry.color).frame(width: 2)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(entry.start.formatted(.dateTime.month().day()) + " · " +
                                                 (entry.allDay ? String(localized: "All day") : entry.start.formatted(date: .omitted, time: .shortened)))
                                                .font(.system(size: 9)).foregroundStyle(.secondary)
                                            Text(entry.title).font(.caption).lineLimit(2)
                                        }
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                TimelineView(.periodic(from: .now, by: 60)) { clock in month(browsedMonth ?? selectedDate ?? clock.date) }
                    .frame(width: min(145, geo.size.width * 0.43))
            }
        }
        .onAppear { agenda.refresh(on: selectedDay) }
        .onChange(of: active) { _, visible in if visible { agenda.refresh(on: selectedDay) } }
        .onChange(of: selectedDate) { _, _ in agenda.refresh(on: selectedDay) }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in if active { agenda.refresh(on: selectedDay) } }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in if active { agenda.refresh(on: selectedDay) } }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in if active { agenda.refresh(on: selectedDay) } }
    }

    private func month(_ displayed: Date) -> some View {
        let first = calendar.dateInterval(of: .month, for: displayed)?.start ?? displayed
        let count = calendar.range(of: .day, in: .month, for: displayed)?.count ?? 0
        let offset = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                monthArrow(-1, from: first)
                ViewThatFits(in: .horizontal) {
                    Text(first.formatted(.dateTime.year().month(.wide)))
                    Text(first.formatted(.dateTime.year().month(.abbreviated)))
                }
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1).frame(maxWidth: .infinity)
                monthArrow(1, from: first)
            }
            LazyVGrid(columns: columns, spacing: 1) {
                ForEach(0..<7, id: \.self) { index in
                    Text(symbols[(index + calendar.firstWeekday - 1) % 7])
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                ForEach(0..<(offset + count), id: \.self) { index in
                    let day = index - offset + 1
                    if day > 0, let date = calendar.date(byAdding: .day, value: day - 1, to: first) {
                        let selected = calendar.isDate(date, inSameDayAs: selectedDay)
                        Button {
                            selectedDate = calendar.isDateInToday(date) ? nil : date
                        } label: {
                            Text(String(day)).font(.system(size: 10, weight: selected ? .bold : .regular)).monospacedDigit()
                                .foregroundStyle(selected ? Color.black : (calendar.isDateInToday(date) ? .mint : .white))
                                .frame(maxWidth: .infinity, minHeight: 15)
                                .background { if selected { Circle().fill(.mint) } }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    } else {
                        Color.clear.frame(height: 15).accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func monthArrow(_ step: Int, from first: Date) -> some View {
        let label = step < 0 ? String(localized: "Previous Month") : String(localized: "Next Month")
        return Button {
            browsedMonth = calendar.date(byAdding: .month, value: step, to: first)
        } label: {
            Image(systemName: step < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label).help(label)
    }
}
