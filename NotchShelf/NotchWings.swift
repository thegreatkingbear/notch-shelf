import AppKit
import Combine
import IOKit.hidsystem
import SwiftUI

struct WidgetGlyph: View {
    let item: WingWidget
    let usage: UsageSample?
    let playing: Bool
    var thermal = ProcessInfo.processInfo.thermalState
    var trayImage: NSImage?
    private static let ink = Color(white: 0.76)
    private static let track = Color(white: 0.27)
    private static let claude = NSImage(named: "ClaudeMark")
    private static let chatGPT = NSImage(named: "ChatGPTMark")

    var body: some View {
        Group {
            switch item {
            case .claude, .codex:
                let current = usage?.current == true
                ZStack {
                    Circle().stroke(Self.track, style: StrokeStyle(lineWidth: 2.4, dash: current ? [] : [2, 2]))
                    if current, let sample = usage, sample.percent < 100 {
                        Circle().trim(from: sample.percent / 100, to: 1)
                            .stroke(Self.ink, lineWidth: 2.4)
                            .rotationEffect(.degrees(-90))
                    }
                    if let mark = item == .claude ? Self.claude : Self.chatGPT {
                        Image(nsImage: mark).renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 13, height: 13)
                    }
                }.frame(width: 21, height: 21)
            case .playback:
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .semibold))
            case .thermal:
                Image(systemName: thermal.rawValue < 2 ? "thermometer.low" : "thermometer.high")
                    .font(.system(size: 16, weight: .medium))
            case .tray(_, let bundle, let name):
                if let image = trayImage ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first.flatMap({ TrayIcon.image(for: $0) }) {
                    Image(nsImage: image).renderingMode(.template).resizable().scaledToFit().frame(width: 18, height: 17)
                } else { Text(String(name.prefix(1))).font(.system(size: 13, weight: .semibold)) }
            }
        }.foregroundStyle(Self.ink).accessibilityHidden(true)
    }
}

private final class WingSelection: ObservableObject {
    @Published private(set) var item: WingWidget?
    private var items: [WingWidget] = []
    private var index = 0
    private var nextRotation: TimeInterval = 0

    func configure(_ items: [WingWidget]) {
        guard self.items != items else { return }
        self.items = items
        index = 0
        item = items.first
        nextRotation = ProcessInfo.processInfo.systemUptime + Double(WingPreferences.rotationSeconds)
    }

    func update(at time: TimeInterval, hovered: Bool) {
        guard items.count > 1 else { return }
        if hovered {
            nextRotation = time + Double(WingPreferences.rotationSeconds)
        } else if time >= nextRotation {
            index = (index + 1) % items.count
            item = items[index]
            nextRotation = time + Double(WingPreferences.rotationSeconds)
        }
    }
}

private struct WingFace: View {
    @ObservedObject var playback: PlaybackMonitor
    @ObservedObject var selection: WingSelection
    @ObservedObject var usage: UsageMonitor
    let isLeft: Bool
    let expanded: Bool
    let activate: (WingWidget) -> Void
    @State private var thermal = ProcessInfo.processInfo.thermalState

    private func label(_ item: WingWidget) -> String {
        switch item {
        case .claude, .codex:
            return usage.tooltip(item)
        case .playback: return playback.isPlaying ? String(localized: "Pause Media") : String(localized: "Play Media")
        case .thermal:
            let names = [String(localized: "Normal"), String(localized: "Moderate"), String(localized: "High"), String(localized: "Critical")]
            return String(localized: "Mac Thermal State") + " · " + (names.indices.contains(thermal.rawValue) ? names[thermal.rawValue] : String(localized: "Checking"))
        case .tray: return item.title
        }
    }

    var body: some View {
        ZStack(alignment: isLeft ? .leading : .trailing) {
            UnevenRoundedRectangle(topLeadingRadius: 0,
                bottomLeadingRadius: isLeft && !expanded ? 10 : 0,
                bottomTrailingRadius: !isLeft && !expanded ? 10 : 0, topTrailingRadius: 0)
                .fill(.black)
            if let item = selection.item {
                Button {
                    if item == .playback { MediaKey.send(NX_KEYTYPE_PLAY) } else { activate(item) }
                } label: {
                    WidgetGlyph(item: item, usage: usage.sample(item), playing: playback.isPlaying, thermal: thermal)
                        .frame(width: NotchWings.controlWidth).frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(label(item))
                .help(item == .claude || item == .codex ? "" : label(item))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification).receive(on: RunLoop.main)) { _ in
            thermal = ProcessInfo.processInfo.thermalState
        }
    }
}

enum MediaKey {
    static func send(_ code: Int32) {
        // Emit one complete media-key press. macOS routes it to the current player.
        guard AXIsProcessTrusted() else { return }
        for state in [NX_KEYDOWN, NX_KEYUP] {
            let flags = Int(state) << 8
            let key = (Int(code) << 16) | flags
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS), data1: key, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

final class NotchWings {
    static let controlWidth: CGFloat = 32
    private let playback: PlaybackMonitor
    private let left: NSPanel
    private let right: NSPanel
    private let leftSelection = WingSelection()
    private let rightSelection = WingSelection()
    private let hint = ShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let hintLabel = NSTextField(labelWithString: "")
    private var nextHintUpdate: TimeInterval = 0
    private let notch: CGRect
    private let expandedBand: CGRect
    private let barOrigin: CGPoint
    private let quartzBand: CGRect
    private let preferences: WingPreferences
    private let usage: UsageMonitor
    private let activate: (WingWidget) -> Void
    private var layoutChanges: AnyCancellable?
    private let alignShelf: (CGRect) -> Void
    private let worker = DispatchQueue(label: "NotchShelf.wingSpace", qos: .utility)
    private var checking = false
    private var nextCheck: TimeInterval = 0
    private var generation = 0
    private var lastTrusted = false
    private var expanded = false
    private var clearBand: CGRect
    private var menuBarHidden = false

    init(playback: PlaybackMonitor, preferences: WingPreferences, usage: UsageMonitor, notch: CGRect, shelfFrame: CGRect, screenLeft: CGFloat, primaryTop: CGFloat,
         alignShelf: @escaping (CGRect) -> Void, activate: @escaping (WingWidget) -> Void) {
        self.playback = playback
        self.notch = notch
        self.preferences = preferences
        self.usage = usage
        self.activate = activate
        self.alignShelf = alignShelf
        clearBand = notch
        expandedBand = CGRect(x: shelfFrame.minX, y: notch.minY, width: shelfFrame.width, height: notch.height)
        let quartzY = primaryTop - notch.maxY
        barOrigin = CGPoint(x: screenLeft, y: quartzY)
        // Search both sides far enough to slide a full-width shelf around an
        // adjacent menu while still enclosing the camera cutout.
        let extra = max(0, shelfFrame.width - notch.width)
        quartzBand = CGRect(x: notch.minX - extra, y: quartzY, width: notch.width + 2 * extra, height: notch.height)

        func makePanel(isLeft: Bool, selection: WingSelection) -> NSPanel {
            let panel = ShelfPanel(contentRect: notch, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
            panel.title = isLeft ? String(localized: "Left Notch Wing") : String(localized: "Right Notch Wing")
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = NSHostingView(rootView: WingFace(playback: playback, selection: selection, usage: usage, isLeft: isLeft, expanded: false,
                                                        activate: activate))
            view.sizingOptions = []
            panel.contentView = view
            return panel
        }
        left = makePanel(isLeft: true, selection: leftSelection)
        right = makePanel(isLeft: false, selection: rightSelection)
        hint.title = String(localized: "Notch Usage Details")
        hint.isOpaque = false
        hint.backgroundColor = .clear
        hint.ignoresMouseEvents = true
        hint.hidesOnDeactivate = false
        hint.level = NSWindow.Level(rawValue: left.level.rawValue + 1)
        hint.collectionBehavior = left.collectionBehavior
        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        background.layer?.cornerRadius = 8
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .white
        hintLabel.usesSingleLineMode = false
        hintLabel.maximumNumberOfLines = 0
        hintLabel.lineBreakMode = .byClipping
        background.addSubview(hintLabel)
        hint.contentView = background
        layoutChanges = preferences.$layout.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.layout() }
    }

    func contains(_ point: NSPoint) -> Bool {
        (left.isVisible && left.frame.contains(point)) || (right.isVisible && right.frame.contains(point))
    }

    func setExpanded(_ value: Bool, animated: Bool = true) {
        guard expanded != value else { return }
        expanded = value
        layout(animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func layout(animated: Bool = false) {
        // Both halves end at the same pixel, including in screenshots where
        // the physical camera cutout itself is transparent.
        let middle = notch.midX.rounded()
        // A hidden menu bar leaves the whole shelf width free for its background.
        let band = menuBarHidden ? expandedBand : clearBand
        for (panel, isLeft) in [(left, true), (right, false)] {
            let space = isLeft ? notch.minX - band.minX : band.maxX - notch.maxX
            let items = preferences.layout.items(isLeft ? .left : .right)
            let hasControl = !menuBarHidden && space >= Self.controlWidth && !items.isEmpty
            let selection = isLeft ? leftSelection : rightSelection
            selection.configure(hasControl ? items : [])
            guard expanded || hasControl else {
                if panel.isVisible { panel.orderOut(nil) }
                continue
            }
            let extensionWidth = expanded ? space : Self.controlWidth
            let start = isLeft ? notch.minX - extensionWidth : middle
            let end = isLeft ? middle : notch.maxX + extensionWidth
            let frame = CGRect(x: start, y: notch.minY, width: end - start, height: notch.height)
            if let view = panel.contentView as? NSHostingView<WingFace> {
                view.rootView = WingFace(playback: playback, selection: selection, usage: usage, isLeft: isLeft, expanded: expanded, activate: activate)
            }
            panel.ignoresMouseEvents = !hasControl
            if animated {
                if !panel.isVisible {
                    let half = CGRect(x: isLeft ? notch.minX : middle, y: notch.minY,
                                      width: isLeft ? middle - notch.minX : notch.maxX - middle, height: notch.height)
                    panel.setFrame(half, display: false)
                    panel.orderFront(nil)
                }
                NSAnimationContext.runAnimationGroup { context in
                    // Widen the shoulders early in the drop, within the free menu-bar space.
                    context.duration = expanded ? 0.24 : 0.26
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.25, 1)
                    panel.animator().setFrame(frame, display: true)
                }
            } else if panel.frame != frame {
                panel.setFrame(frame, display: true)
            }
            if !panel.isVisible { panel.orderFront(nil) }
        }
    }

    func invalidateLayout() {
        // An activation on another display can leave both wings in exactly
        // the same place. Wait for the measured geometry before ordering windows.
        generation += 1
        nextCheck = 0
    }

    func dismiss() {
        generation += 1
        hint.orderOut(nil)
        left.orderOut(nil)
        right.orderOut(nil)
    }

    func updateHover(at point: CGPoint, time: TimeInterval, enabled: Bool) {
        var target: (button: CGRect, screen: NSScreen)?
        for (panel, selection, isLeft) in [(left, leftSelection, true), (right, rightSelection, false)] {
            var button = panel.frame
            if !isLeft { button.origin.x = button.maxX - Self.controlWidth }
            button.size.width = Self.controlWidth
            let hovered = enabled && point.x >= button.minX && point.x < button.maxX
                && point.y >= button.minY && point.y <= button.maxY && panel.isVisible && panel.isOnActiveSpace
            selection.update(at: time, hovered: hovered)
            if hovered, let item = selection.item, item == .claude || item == .codex, let screen = panel.screen {
                target = (button, screen)
            }
        }
        guard let target else {
            if hint.isVisible { hint.orderOut(nil) }
            return
        }
        var size = hint.frame.size
        if !hint.isVisible || time >= nextHintUpdate {
            let text = usage.combinedTooltip
            if hintLabel.stringValue != text {
                hintLabel.stringValue = text
                hintLabel.sizeToFit()
                hintLabel.setFrameOrigin(CGPoint(x: 10, y: 7))
                size = CGSize(width: ceil(hintLabel.frame.width) + 20, height: ceil(hintLabel.frame.height) + 14)
            }
            nextHintUpdate = time + 1
        }
        let bounds = target.screen.frame
        let x = min(max(bounds.minX, target.button.midX - size.width / 2), bounds.maxX - size.width)
        let frame = CGRect(x: x.rounded(), y: target.button.minY - size.height - 3, width: size.width, height: size.height)
        if hint.frame != frame { hint.setFrame(frame, display: true) }
        if !hint.isVisible { hint.orderFront(nil) }
    }

    func refresh(at time: TimeInterval, trusted: Bool) {
        if trusted != lastTrusted {
            invalidateLayout()
            lastTrusted = trusted
            if !trusted {
                menuBarHidden = false
                clearBand = notch
                layout()
            }
        }
        guard trusted, !checking, time >= nextCheck else { return }
        nextCheck = time + 3
        checking = true
        let current = generation
        let menuOwnerPID = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier
        let band = quartzBand
        let origin = barOrigin
        worker.async { [weak self] in
            let measured = MenuBarAccess.menuBarLayout(in: band, barOrigin: origin, menuOwnerPID: menuOwnerPID)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.checking = false
                guard current == self.generation else { return }

                let occupied: [CGRect]
                switch measured {
                case .unavailable:
                    // The menu owner may be busy handling input. Retry on the
                    // next tick that is due without changing the last layout.
                    return
                case .hidden:
                    self.alignShelf(self.expandedBand)
                    if !self.menuBarHidden {
                        self.menuBarHidden = true
                        self.clearBand = self.notch
                        self.layout()
                    }
                    return
                case .visible(let frames):
                    occupied = frames
                }

                // Expand only through the contiguous free space on each side.
                var minX = band.minX
                var maxX = band.maxX
                for rect in occupied {
                    if rect.minX < self.notch.minX { minX = max(minX, min(self.notch.minX, ceil(rect.maxX + 1))) }
                    if rect.maxX > self.notch.maxX { maxX = min(maxX, max(self.notch.maxX, floor(rect.minX - 1))) }
                }
                let width = min(self.expandedBand.width, maxX - minX)
                let x = min(max(self.expandedBand.minX, minX), maxX - width)
                let available = CGRect(x: x, y: self.notch.minY, width: width, height: self.notch.height)
                self.alignShelf(available)
                if self.menuBarHidden || available != self.clearBand {
                    self.menuBarHidden = false
                    self.clearBand = available
                    self.layout()
                }
            }
        }
    }
}
