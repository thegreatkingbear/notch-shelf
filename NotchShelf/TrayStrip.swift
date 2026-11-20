import SwiftUI

// Track the stationary viewport so moving icons and card transitions never take
// hover tracking away from it. Buttons underneath still receive their clicks.
private struct EdgeHover: NSViewRepresentable {
    var pages = false
    var scrolled: (CGFloat) -> Void
    var changed: (Int) -> Void

    func makeNSView(context: Context) -> EdgeTrackingView { EdgeTrackingView() }
    func updateNSView(_ view: EdgeTrackingView, context: Context) {
        view.pages = pages
        view.changed = changed
        view.scrolled = scrolled
    }
}

final class EdgeTrackingView: NSView {
    var changed: ((Int) -> Void)?
    var scrolled: ((CGFloat) -> Void)?
    var pages = false
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .mouseMoved],
                                  owner: self, userInfo: nil)
        addTrackingArea(next)
        area = next
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { changed?(0); return }
        changed?(p.x < 14 ? -1 : (p.x >= bounds.width - 14 ? 1 : 0))
    }
    override func mouseExited(with event: NSEvent) { changed?(0) }
}

// Route a scroll sequence to the viewport under its starting point. Vertical
// sequences continue to AppKit (including the agenda's native scroll view).
final class ShelfScrollRouter {
    private weak var target: EdgeTrackingView?
    private var horizontal: Bool?
    private var distance: CGFloat = 0
    private var didPage = false
    private var lastEvent: TimeInterval = -.infinity

    func handle(_ event: NSEvent, in root: NSView) -> Bool {
        let start = event.phase.contains(.began) || event.phase.contains(.mayBegin)
        let momentum = !event.momentumPhase.isEmpty
        let newWheelSequence = event.phase.isEmpty && event.timestamp - lastEvent > 0.25
        if !momentum && (start || newWheelSequence || lastEvent == -.infinity) {
            target = tracker(in: root, at: event.locationInWindow)
            horizontal = nil
            distance = 0
            didPage = false
        }
        lastEvent = event.timestamp
        guard let target, !target.isHiddenOrHasHiddenAncestor else { return false }
        let x = event.scrollingDeltaX, y = event.scrollingDeltaY
        if horizontal == nil && (x != 0 || y != 0) { horizontal = abs(x) > abs(y) }
        guard horizontal == true else { return false }
        let delta = -x * (event.hasPreciseScrollingDeltas ? 1 : 10)
        if target.pages {
            if !momentum && !didPage {
                distance += delta
                if abs(distance) >= 26 {
                    didPage = true
                    target.scrolled?(distance)
                }
            }
        } else if delta != 0 { target.scrolled?(delta) }
        return true
    }

    private func tracker(in view: NSView, at point: NSPoint) -> EdgeTrackingView? {
        guard !view.isHidden, view.bounds.contains(view.convert(point, from: nil)) else { return nil }
        if let view = view as? EdgeTrackingView { return view }
        for child in view.subviews.reversed() {
            if let match = tracker(in: child, at: point) { return match }
        }
        return nil
    }
}

struct TrayStrip: View {
    let items: [ShelfItem]
    let choose: (ShelfItem) -> Void
    @State private var offset: CGFloat = 0
    @State private var direction = 0
    @State private var hovered: String?
    private let pitch: CGFloat = 33

    var body: some View {
        GeometryReader { geo in
            let width = CGFloat(items.count) * pitch
            let limit = max(0, width - geo.size.width)
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(items) { item in
                        Button { choose(item) } label: {
                            Group {
                                if let icon = item.trayIcon {
                                    Image(nsImage: icon).renderingMode(icon.isTemplate ? .template : .original)
                                        .resizable().scaledToFit()
                                } else if let system = item.symbol {
                                    Image(systemName: system).resizable().scaledToFit()
                                } else {
                                    Text(String(item.appName.prefix(1))).font(.system(size: 13, weight: .bold))
                                }
                            }.frame(width: 21, height: 17)
                            .frame(width: pitch - 2, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(hovered == item.id ? 0.15 : 0)))
                            .frame(width: pitch).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(item.name)
                         .onHover { if $0 { hovered = item.id } else if hovered == item.id { hovered = nil } }
                    }
                }.fixedSize().offset(x: -min(offset, limit))
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
            .overlay {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 9).opacity(offset > 0 ? 1 : 0)
                    Spacer()
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 9).opacity(offset < limit ? 1 : 0)
                }.allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .background {
                EdgeHover(scrolled: { delta in offset = min(limit, max(0, offset + delta)) }) {
                    direction = limit > 0 ? $0 : 0
                }
            }
            .task(id: direction) {
                guard direction != 0 else { return }
                // Delay makes the endmost visible icon clickable without moving it away.
                do {
                    try await Task.sleep(for: .milliseconds(170))
                    while !Task.isCancelled {
                        let next = min(limit, max(0, offset + CGFloat(direction) * 1.8))
                        guard next != offset else { return }
                        offset = next
                        try await Task.sleep(for: .milliseconds(16))
                    }
                } catch {}
            }
            .onChange(of: limit) { _, new in offset = min(offset, new); direction = 0 }
            .accessibilityAdjustableAction { change in
                offset = min(limit, max(0, offset + (change == .increment ? pitch : -pitch)))
            }
        }.frame(height: 28)
    }
}

private struct CardSurface<Content: View>: View {
    let active: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 5)
            .accessibilityHidden(!active)
            .preferredColorScheme(.dark)
    }
}

enum ShelfCard: Int, CaseIterable {
    case music, calendar, reminders, notes

    func neighbor(_ direction: Int) -> Self {
        let cards = Self.allCases
        return cards[(rawValue + direction + cards.count) % cards.count]
    }
}

// The outgoing and incoming pages share one translated layer throughout a swipe.
private final class CardStripView: NSView {
    static let slideDuration = 0.28
    private let music: NSHostingView<CardSurface<MusicCard>>
    private let month: NSHostingView<CardSurface<CalendarCard>>
    private let tasks: NSHostingView<CardSurface<RemindersCard>>
    private let jottings: NSHostingView<CardSurface<NotesCard>>
    private let strip = NSView()
    private var selected: ShelfCard
    private var previous: ShelfCard?
    private var forward = true

    init(playback: PlaybackMonitor, selected: ShelfCard, reminders: ReminderList, notes: NoteLibrary) {
        self.selected = selected
        music = NSHostingView(rootView: CardSurface(active: selected == .music) { MusicCard(active: selected == .music, playback: playback) })
        month = NSHostingView(rootView: CardSurface(active: selected == .calendar) { CalendarCard(active: selected == .calendar) })
        tasks = NSHostingView(rootView: CardSurface(active: selected == .reminders) { RemindersCard(active: selected == .reminders, model: reminders) })
        jottings = NSHostingView(rootView: CardSurface(active: selected == .notes) { NotesCard(active: selected == .notes, model: notes) })
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        strip.wantsLayer = true
        addSubview(strip)
        for page in ShelfCard.allCases {
            let view = view(for: page)
            view.wantsLayer = true
            strip.addSubview(view)
        }
        music.sizingOptions = []
        month.sizingOptions = []
        tasks.sizingOptions = []
        jottings.sizingOptions = []
    }

    required init?(coder: NSCoder) { nil }

    private func view(for page: ShelfCard) -> NSView {
        switch page {
        case .music: return music
        case .calendar: return month
        case .reminders: return tasks
        case .notes: return jottings
        }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        strip.frame = NSRect(x: forward ? -width : 0, y: 0, width: 2 * width, height: bounds.height)
        for page in ShelfCard.allCases {
            let view = view(for: page)
            view.isHidden = page != selected && page != previous
            let onRight = (page == selected) == forward
            view.frame = NSRect(x: onRight ? width : 0, y: 0, width: width, height: bounds.height)
        }
    }

    func show(_ page: ShelfCard, forward: Bool, animated: Bool, playback: PlaybackMonitor, reminders: ReminderList, notes: NoteLibrary) {
        guard page != selected else { return }
        if selected == .reminders || selected == .notes, window?.isKeyWindow == true {
            window?.makeFirstResponder(nil)
            window?.resignKey()
        }
        previous = selected
        selected = page
        self.forward = forward
        music.rootView = CardSurface(active: page == .music) { MusicCard(active: page == .music, playback: playback) }
        month.rootView = CardSurface(active: page == .calendar) { CalendarCard(active: page == .calendar) }
        tasks.rootView = CardSurface(active: page == .reminders) { RemindersCard(active: page == .reminders, model: reminders) }
        jottings.rootView = CardSurface(active: page == .notes) { NotesCard(active: page == .notes, model: notes) }
        strip.layer?.removeAnimation(forKey: "slide")
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard animated, bounds.width > 0 else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = forward ? bounds.width : -bounds.width
        slide.toValue = 0
        slide.duration = Self.slideDuration
        slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        strip.layer?.add(slide, forKey: "slide")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if strip.layer?.animation(forKey: "slide") != nil { return self }
        return super.hitTest(point)
    }
}

private struct CardStrip: NSViewRepresentable {
    let playback: PlaybackMonitor
    let selection: ShelfCard
    let reminders: ReminderList
    let notes: NoteLibrary
    let forward: Bool
    let animated: Bool

    func makeNSView(context: Context) -> CardStripView { CardStripView(playback: playback, selected: selection, reminders: reminders, notes: notes) }
    func updateNSView(_ view: CardStripView, context: Context) {
        view.show(selection, forward: forward, animated: animated, playback: playback, reminders: reminders, notes: notes)
    }
}

struct InfoDeck: View {
    @ObservedObject var playback: PlaybackMonitor
    @Binding var selection: ShelfCard
    let reminders: ReminderList
    let notes: NoteLibrary
    @State private var forward = true
    @State private var edge = 0
    @State private var slidingUntil: TimeInterval = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func go(_ direction: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= slidingUntil else { return }
        slidingUntil = now + (reduceMotion ? 0 : CardStripView.slideDuration)
        forward = direction > 0
        selection = selection.neighbor(direction)
    }

    var body: some View {
        GeometryReader { geo in
            CardStrip(playback: playback, selection: selection, reminders: reminders, notes: notes, forward: forward, animated: !reduceMotion)
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped().contentShape(Rectangle())
            .background {
                EdgeHover(pages: true, scrolled: { delta in
                    edge = 0
                    go(delta > 0 ? 1 : -1)
                }) { edge = $0 }
            }
            .task(id: edge) {
                guard edge != 0 else { return }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                go(edge)
            }
            .accessibilityAction(named: "Next Card") { go(1) }
            .accessibilityAction(named: "Previous Card") { go(-1) }
        }
    }
}
