import AppKit
import SwiftUI

private struct Anchor: Equatable {
    let trigger: NSRect
    let panel: NSRect
    let hasCutout: Bool
    let screenLeft: CGFloat
    let primaryTop: CGFloat
    let display: CGDirectDisplayID?

    init?() {
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return nil }
        screenLeft = screen.frame.minX
        primaryTop = screens.first?.frame.maxY ?? screen.frame.maxY
        display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let top = screen.frame.maxY
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           screen.safeAreaInsets.top > 0, right.minX > left.maxX {
            hasCutout = true
            trigger = NSRect(x: left.maxX, y: top - screen.safeAreaInsets.top,
                             width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
        } else {
            hasCutout = false
            trigger = NSRect(x: screen.frame.midX - 52, y: top - 5, width: 104, height: 5)
        }
        let width = min(screen.frame.width, 390)
        panel = NSRect(x: round(trigger.midX - width / 2), y: trigger.minY - 184, width: width, height: 184)
    }
}

final class ShelfPanel: NSPanel {
    private let scrollRouter = ShelfScrollRouter()

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, let contentView, scrollRouter.handle(event, in: contentView) { return }
        super.sendEvent(event)
    }

    var allowsTextEntry = false
    override var canBecomeKey: Bool { allowsTextEntry }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = ShelfModel()
    private lazy var playback = PlaybackMonitor()
    private let preferences = WingPreferences()
    private lazy var usage = UsageMonitor(preferences: preferences)
    private var settingsWindow: NSWindow?
    private var settingsClose: NSObjectProtocol?
    private var anchor: Anchor?
    private var panel: ShelfPanel?
    private var openFrame = CGRect.zero
    private var springRoom: CGFloat = 0
    private var wings: NotchWings?
    private var timer: Timer?
    private var mouseMonitors: [Any] = []
    private var menuBarBands: [NSRect] = []
    private var enteredAt: TimeInterval?
    private var closeAfter: TimeInterval?
    private var lastPermissionCheck: TimeInterval = 0
    private var suppressUntilExit = false
    private var menuTracking = false
    private var selecting = false
    private var transition = 0
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Supply standard editing commands to the panel's native field editor.
        let menu = NSMenu()
        menu.addItem(withTitle: "Notch Shelf", action: nil, keyEquivalent: "").submenu = NSMenu(title: "Notch Shelf")
        let edit = NSMenu(title: String(localized: "Edit"))
        for (title, action, key) in [(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"),
                                     (String(localized: "Copy"), #selector(NSText.copy(_:)), "c"),
                                     (String(localized: "Paste"), #selector(NSText.paste(_:)), "v"),
                                     (String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        menu.addItem(withTitle: edit.title, action: nil, keyEquivalent: "").submenu = edit
        NSApp.mainMenu = menu
        let center = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                      NSWorkspace.didWakeNotification] {
            center.addObserver(self, selector: #selector(menuLayoutChanged), name: event, object: nil)
        }
        let menus = NotificationCenter.default
        menus.addObserver(self, selector: #selector(menuOpened), name: NSMenu.didBeginTrackingNotification, object: nil)
        menus.addObserver(self, selector: #selector(menuClosed), name: NSMenu.didEndTrackingNotification, object: nil)
        model.start()
        configureScreen()
        model.onChoose = { [weak self] item in self?.choose(item) }
        // Poll quickly only while the pointer is near a menu bar or the shelf is
        // busy. Elsewhere, a slow tick keeps widgets current and pointer
        // movement toward the top of a screen switches back to fast polling.
        let wake: (NSEvent) -> Void = { [weak self] _ in
            guard let self, self.timer?.timeInterval != Self.activeInterval,
                  self.isNearMenuBar(NSEvent.mouseLocation) else { return }
            self.tick()
        }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        mouseMonitors = [NSEvent.addGlobalMonitorForEvents(matching: moves, handler: wake),
                         NSEvent.addLocalMonitorForEvents(matching: moves) { wake($0); return $0 }].compactMap { $0 }
        schedule(Self.idleInterval)
        if !UserDefaults.standard.bool(forKey: "didIntroduce") {
            show(initial: true)
            UserDefaults.standard.set(true, forKey: "didIntroduce")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        model.stop()
    }

    private static let activeInterval: TimeInterval = 0.08
    private static let idleInterval: TimeInterval = 1

    private func schedule(_ interval: TimeInterval) {
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The strip along the top of each screen where the notch, wings and the
    /// clock respond to the pointer.
    private func isNearMenuBar(_ point: NSPoint) -> Bool {
        menuBarBands.contains { $0.contains(point) }
    }

    private func updateMenuBarBands() {
        menuBarBands = NSScreen.screens.map { screen in
            let height = max(48, screen.safeAreaInsets.top + 16)
            // Include the top edge itself, where the pointer rests against the bezel.
            return NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height + 1)
        }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) { configureScreen() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show(initial: true)
        return true
    }

    @objc private func menuOpened() { menuTracking = true; closeAfter = nil }
    @objc private func menuClosed() {
        menuTracking = false
        closeAfter = now + 1.2
    }

    @objc private func menuLayoutChanged() { wings?.invalidateLayout() }

    private func configureScreen() {
        updateMenuBarBands()
        let updated = Anchor()
        if anchor == updated, panel != nil {
            wings?.invalidateLayout()
            return
        }
        wings?.dismiss()
        wings = nil
        transition += 1
        panel?.orderOut(nil)
        model.expanded = false
        anchor = updated
        guard let anchor else { panel = nil; return }
        openFrame = anchor.panel
        springRoom = 0
        if anchor.hasCutout {
            wings = NotchWings(playback: playback, preferences: preferences, usage: usage, notch: anchor.trigger, shelfFrame: anchor.panel, screenLeft: anchor.screenLeft,
                               primaryTop: anchor.primaryTop, alignShelf: { [weak self] band in
                guard let self else { return }
                let width = max(band.width, min(anchor.panel.width, 312))
                self.openFrame = NSRect(x: round(band.midX - width / 2), y: anchor.panel.minY, width: width, height: anchor.panel.height)
                self.positionShelf()
            }, activate: { [weak self] in self?.activateWidget($0) })
        }
        let window = ShelfPanel(contentRect: anchor.panel, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        window.allowsTextEntry = true
        window.becomesKeyOnlyIfNeeded = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: ShelfView(model: model, playback: playback, notchWidth: anchor.trigger.width, openHeight: anchor.panel.height, openSettings: { [weak self] in self?.openSettings() }) { [weak self] in
            self?.openPermissionSettings()
        })
        window.setFrame(anchor.panel, display: false)
        panel = window
        enteredAt = nil
        closeAfter = nil
    }

    private func positionShelf() {
        guard let panel else { return }
        var frame = openFrame
        frame.origin.y -= springRoom
        frame.size.height += springRoom
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func tick() {
        let point = NSEvent.mouseLocation
        defer {
            let active = model.expanded || selecting || menuTracking || enteredAt != nil || closeAfter != nil
                || model.suspendedForClock || isNearMenuBar(point)
            schedule(active ? Self.activeInterval : Self.idleInterval)
        }
        guard let anchor, panel != nil else { return }
        let overNotch = anchor.trigger.insetBy(dx: -1, dy: -1).contains(point)
        let time = now
        model.accommodateClock(at: point, time: time)
        if (wings != nil || model.expanded || settingsWindow?.isVisible == true || !model.destinations.isEmpty) && time - lastPermissionCheck > 1.0 {
            lastPermissionCheck = time
            model.syncPermission()
        }
        wings?.refresh(at: time, trusted: model.trusted)
        wings?.updateHover(at: point, time: time, enabled: !selecting && !menuTracking && NSEvent.pressedMouseButtons == 0)
        guard !selecting, !menuTracking else { return }
        if model.expanded {
            let editing = panel?.isKeyWindow == true && (panel?.firstResponder as? NSTextView)?.isFieldEditor == true
            if editing || overNotch || wings?.contains(point) == true || openFrame.insetBy(dx: -2, dy: -2).contains(point) {
                closeAfter = nil
            } else if let deadline = closeAfter {
                if time >= deadline { hide() }
            } else { closeAfter = time + 0.35 }
        } else if overNotch && !suppressUntilExit {
            if let enteredAt {
                if time - enteredAt >= 0.14 { show() }
            } else { enteredAt = time }
        } else {
            enteredAt = nil
            if !overNotch { suppressUntilExit = false }
        }
    }

    private func show(initial: Bool = false) {
        guard let panel else { return }
        transition += 1
        let token = transition
        closeAfter = initial ? now + 12 : nil
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        springRoom = animate ? ShelfView.springRoom : 0
        positionShelf()
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        model.refresh()
        DispatchQueue.main.async { [weak self] in
            guard let self, token == self.transition else { return }
            self.wings?.setExpanded(true)
            withAnimation(animate ? .spring(response: 0.36, dampingFraction: 0.65) : nil, completionCriteria: .removed) {
                self.model.expanded = true
            } completion: {
                guard token == self.transition else { return }
                self.springRoom = 0
                self.positionShelf()
            }
        }
    }

    private func hide(immediately: Bool = false) {
        transition += 1
        let token = transition
        wings?.setExpanded(false, animated: !immediately)
        closeAfter = nil
        enteredAt = nil
        panel?.ignoresMouseEvents = true
        let animate = !immediately && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !animate { panel?.orderOut(nil) }
        withAnimation(animate ? .spring(response: 0.32, dampingFraction: 0.82) : nil, completionCriteria: .removed) {
            model.expanded = false
        } completion: { [weak self] in
            guard let self, token == self.transition else { return }
            self.panel?.orderOut(nil)
            self.springRoom = 0
            self.positionShelf()
        }
    }

    private func activateWidget(_ item: WingWidget) {
        switch item {
        case .thermal: show()
        case .claude, .codex: openSettings()
        case .playback: break
        case .tray(let id, let bundle, let name):
            let entries = model.visibleItems + model.items
            if let target = entries.first(where: { $0.id == id }) ?? (id == bundle ? entries.first { $0.bundleID == bundle } : nil) {
                choose(target)
            } else if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
                choose(ShelfItem(id: id, name: name, bundleID: bundle, appName: app.localizedName ?? name,
                                 icon: app.icon, symbol: nil, element: nil, action: kAXPressAction))
            } else {
                model.message = String(localized: "Make sure this menu bar app is running.")
                show()
            }
        }
    }

    private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 550),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = String(localized: "Notch Shelf Settings")
            window.isReleasedWhenClosed = false
            let settingsView = NSHostingView(rootView: ShelfSettings(preferences: preferences, model: model, usage: usage) { [weak self] in
                self?.openPermissionSettings()
            })
            settingsView.sizingOptions = []
            window.contentView = settingsView
            window.contentMinSize = NSSize(width: 800, height: 460)
            window.center()
            settingsClose = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.usage.settings(false)
            }
            settingsWindow = window
        }
        hide(immediately: true)
        model.refresh()
        usage.settings(true)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func openPermissionSettings() {
        let panes = ["com.apple.settings.PrivacySecurity.extension", "com.apple.preference.security"]
        for pane in panes {
            guard let url = URL(string: "x-apple.systempreferences:\(pane)?Privacy_Accessibility"),
                  NSWorkspace.shared.open(url) else { continue }
            model.message = nil
            suppressUntilExit = true
            hide(immediately: true)
            return
        }
        model.message = String(localized: "Enable NotchShelf.app in System Settings → Privacy & Security → \(ShelfModel.permissionPaneName).")
    }

    private func choose(_ item: ShelfItem) {
        guard !selecting, !menuTracking else { return }
        selecting = true
        suppressUntilExit = true
        model.message = nil
        let screen = panel?.screen
        let display = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        hide(immediately: true)
        model.open(item, on: NSScreen.screens.count > 1 ? display : nil) { [weak self] message in
            guard let self else { return }
            self.selecting = false
            self.model.message = message
            // A timed-out press may already have opened the owner's menu. Show the
            // result on the next hover so this panel never covers that menu.
            if message != nil { self.model.refresh(force: true) }
        }
    }
}

@main
struct NotchShelfApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
