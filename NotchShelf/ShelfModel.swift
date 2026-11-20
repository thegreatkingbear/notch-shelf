import SwiftUI
import ApplicationServices

struct PlacementApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
}

final class ShelfModel: ObservableObject {
    @Published private(set) var items = [ShelfItem]()
    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published private(set) var loading = false
    @Published var message: String?
    @Published var expanded = false
    @Published var managing = false
    @Published private(set) var destinations = UserDefaults.standard.dictionary(forKey: "notchApps") as? [String: String] ?? [:]
    @Published private(set) var hidden = Set<String>()
    @Published private(set) var layoutError: String?
    let supportsPlacement = MenuBarFilter.isSupported()
    var onChoose: ((ShelfItem) -> Void)?
    private let filter = MenuBarFilter()
    private var requestedAllowed: Set<String>?
    private var requestedHidden = Set<String>()
    private var suspendedForClock = false
    private var nextClockCheck: TimeInterval = 0
    private var temporaryReveal: String?
    private var runningObservation: NSKeyValueObservation?
    private let worker = DispatchQueue(label: "NotchShelf.discovery", qos: .userInitiated)
    private var lastScan = Date.distantPast
    private let oldPins = Set(UserDefaults.standard.stringArray(forKey: "pins") ?? [])

    func start() {
        runningObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateLayout() }
        }
        refresh(force: true)
    }

    func stop() {
        runningObservation?.invalidate()
        requestedAllowed = nil
        filter.clear()
    }

    private func updateLayout() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var desired = Set(destinations.keys).intersection(running)
        if let temporaryReveal { desired.remove(temporaryReveal) }
        guard trusted, supportsPlacement, !suspendedForClock, !desired.isEmpty else {
            filter.clear()
            requestedAllowed = nil
            requestedHidden = []
            hidden = []
            layoutError = nil
            return
        }
        let allowed = running.subtracting(desired)
        guard allowed != requestedAllowed || desired != requestedHidden else { return }
        requestedHidden = desired
        requestedAllowed = allowed
        filter.applyAllowedBundles(Array(allowed)) { [weak self] success in
            guard let self else { return }
            self.hidden = success ? desired : []
            self.layoutError = success ? nil : String(localized: "Couldn’t apply the menu bar layout. Refresh to try again.")
            if !success { self.requestedAllowed = nil }
        }
    }

    // The menu bar filter also affects the system clock's Notification Center
    // action. Yield while using the clock, then restore the user's placement.
    func accommodateClock(at point: NSPoint, time: TimeInterval) {
        guard (!hidden.isEmpty || suspendedForClock), time >= nextClockCheck else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(point) }
        let nearClock = screen.map {
            point.x > $0.frame.maxX - 240 && point.y >= $0.frame.maxY - max(30, $0.safeAreaInsets.top)
        } ?? false
        if !nearClock && !suspendedForClock { return }
        nextClockCheck = time + (suspendedForClock ? 0.35 : 0.08)
        let overClock = nearClock && MenuBarAccess.isPointerOnClock(point)
        let suspend = overClock || (suspendedForClock && Self.notificationCenterOpen())
        if suspend != suspendedForClock {
            suspendedForClock = suspend
            updateLayout()
        }
    }

    private static func notificationCenterOpen() -> Bool {
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return false }
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { row in
            guard row[kCGWindowOwnerPID as String] as? Int32 == process.processIdentifier,
                  let level = row[kCGWindowLayer as String] as? Int, level > 0,
                  let bounds = row[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return (bounds["Height"] ?? 0) > 200
        }
    }

    var apps: [PlacementApp] {
        var entries = [String: PlacementApp]()
        for item in items where item.symbol == nil {
            guard !["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"].contains(item.bundleID),
                  !item.bundleID.hasPrefix("pid-"), !item.bundleID.hasPrefix("/") else { continue }
            entries[item.bundleID] = PlacementApp(id: item.bundleID, name: item.appName, icon: item.icon)
        }
        // A saved assignment can be returned to the menu bar even when its app is closed.
        for (id, name) in destinations where entries[id] == nil {
            entries[id] = PlacementApp(id: id, name: name, icon: NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.icon)
        }
        return entries.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var visibleItems: [ShelfItem] {
        guard supportsPlacement else { return items }
        var visible = items.filter { hidden.contains($0.bundleID) }
        let represented = Set(visible.map(\.bundleID))
        for id in hidden.subtracting(represented) {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { continue }
            let name = app.localizedName ?? destinations[id] ?? id
            visible.append(ShelfItem(id: id, name: name, bundleID: id, appName: name, icon: app.icon,
                                     trayIcon: TrayIcon.image(for: app), symbol: nil, element: nil, action: kAXPressAction))
        }
        return visible.sorted {
            if oldPins.contains($0.id) != oldPins.contains($1.id) { return oldPins.contains($0.id) }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func move(_ app: PlacementApp) {
        guard supportsPlacement, trusted else { return }
        if destinations[app.id] != nil { destinations.removeValue(forKey: app.id) }
        else { destinations[app.id] = app.name }
        UserDefaults.standard.set(destinations, forKey: "notchApps")
        updateLayout()
    }

    func syncPermission() {
        let current = AXIsProcessTrusted()
        guard trusted != current else { return }
        trusted = current
        updateLayout()
        if current { refresh(force: true) } else { items = []; managing = false }
    }

    static var permissionPaneName: String {
        if #available(macOS 27, *) { return String(localized: "Device Control and Data Access") }
        return String(localized: "Accessibility")
    }

    func refresh(force: Bool = false) {
        syncPermission()
        if force { updateLayout() }
        guard trusted, !loading, force || Date().timeIntervalSince(lastScan) > 8 else { return }
        loading = true
        worker.async {
            let snapshot = MenuBarAccess.scan()
            DispatchQueue.main.async {
                self.syncPermission()
                if self.trusted { self.items = snapshot }
                self.lastScan = Date()
                self.loading = false
            }
        }
    }

    func open(_ item: ShelfItem, on display: CGDirectDisplayID?, completion: @escaping (String?) -> Void) {
        Task { @MainActor in
            var result: AXError = .invalidUIElement
            if display == nil { result = await Task.detached { MenuBarAccess.press(item) }.value }
            // Some owners withdraw their AX elements while hidden. Reveal just that app,
            // reacquire the selected element, and apply its assignment again on dismissal.
            if result == .invalidUIElement || result == .actionUnsupported {
                temporaryReveal = item.bundleID
                updateLayout()
                defer { temporaryReveal = nil; updateLayout() }
                let deadline = Date().addingTimeInterval(2)
                repeat {
                    try? await Task.sleep(nanoseconds: 160_000_000)
                    let fresh = await Task.detached { MenuBarAccess.scan(only: item.bundleID) }.value
                    if let target = fresh.first(where: { $0.id == item.id }) ?? (item.id == item.bundleID ? fresh.first : nil) {
                        let before = Self.menuWindows(of: item.bundleID)
                        if let display {
                            let clicked = await Task.detached { MenuBarAccess.click(target, on: display) }.value
                            if !clicked { continue }
                            result = .success
                        } else { result = await Task.detached { MenuBarAccess.press(target) }.value }
                        if result == .success || result == .cannotComplete {
                            await waitForDismissal(of: item.bundleID, excluding: before)
                        }
                        break
                    }
                } while Date() < deadline && trusted
            }
            switch result {
            case .success: completion(nil)
            case .cannotComplete:
                completion(String(localized: "If the menu didn’t open, select the item again."))
            default:
                completion(display == nil ? String(localized: "Couldn’t open this item. Use Arrange Apps to move it back to the menu bar.") :
                               String(localized: "Couldn’t find this icon in the menu bar on this display."))
            }
        }
    }

    private static func menuWindows(of bundle: String) -> Set<UInt32> {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map(\.processIdentifier))
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(windows.compactMap { row in
            guard let pid = row[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid) else { return nil }
            return row[kCGWindowNumber as String] as? UInt32
        })
    }

    @MainActor private func waitForDismissal(of bundle: String, excluding before: Set<UInt32>) async {
        var opened = false
        let start = Date()
        repeat {
            let nowOpen = !Self.menuWindows(of: bundle).subtracting(before).isEmpty
            if opened && !nowOpen { return }
            opened = opened || nowOpen
            if !opened && Date().timeIntervalSince(start) > 1 { return }
            try? await Task.sleep(nanoseconds: 180_000_000)
        } while trusted && Date().timeIntervalSince(start) < 120
    }
}
