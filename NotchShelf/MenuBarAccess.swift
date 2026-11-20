import AppKit
import ApplicationServices

struct ShelfItem: Identifiable {
    let id: String
    let name: String
    let bundleID: String
    let appName: String
    let icon: NSImage?
    var trayIcon: NSImage? = nil
    let symbol: String?
    let element: AXUIElement?
    let action: String
}

enum MenuBarAccess {
    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func text(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = value(element, attribute) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let systemSymbols = [
        "wifi": "wifi", "battery": "battery.75", "bluetooth": "antenna.radiowaves.left.and.right",
        "clock": "clock", "controlcenter": "switch.2", "sound": "speaker.wave.2",
        "focusmode": "moon", "timemachine": "clock.arrow.circlepath", "airdrop": "airplayaudio"
    ]

    static func scan(only bundleID: String? = nil) -> [ShelfItem] {
        guard AXIsProcessTrusted() else { return [] }
        var result = [ShelfItem]()
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != getpid() {
            if let bundleID, app.bundleIdentifier != bundleID { continue }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.12)
            // The owner's extras bar also contains items obscured by the front app's menus.
            guard let raw = value(root, kAXExtrasMenuBarAttribute),
                  CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
            let bar = raw as! AXUIElement
            let bundle = app.bundleIdentifier ?? app.bundleURL?.path ?? "pid-\(app.processIdentifier)"
            let appName = app.localizedName ?? bundle
            var elements = [AXUIElement]()
            for child in children(bar) {
                // MenuBarAgent (macOS 27) wraps each system menu extra in a group.
                if text(child, kAXRoleAttribute) == kAXGroupRole {
                    elements.append(contentsOf: children(child))
                } else {
                    elements.append(child)
                }
            }
            var occurrences = [String: Int]()
            for (index, element) in elements.enumerated() {
                let identifier = text(element, kAXIdentifierAttribute)
                let isSystemExtra = identifier?.hasPrefix("com.apple.menuextra.") == true
                // The extras bar can also contain the system overflow disclosure.
                guard text(element, kAXRoleAttribute) == kAXMenuBarItemRole || isSystemExtra else { continue }
                var actions: CFArray?
                AXUIElementCopyActionNames(element, &actions)
                let supported = actions as? [String] ?? []
                guard let action = [kAXPressAction, kAXShowMenuAction].first(where: supported.contains) else { continue }
                let label = text(element, kAXDescriptionAttribute) ?? text(element, kAXTitleAttribute) ?? text(element, kAXHelpAttribute)
                let fallback = elements.count > 1 ? "\(appName) \(index + 1)" : appName
                let name = label ?? (isSystemExtra ? identifier?.components(separatedBy: ".").last : nil) ?? fallback
                // Some extras only have changing titles (battery, clock, system monitors).
                // Preserve pins using the AX identifier, or the owner's extras order.
                let key = identifier.map { "ax-\($0)" } ?? "slot-\(index)"
                let occurrence = occurrences[key, default: 0]
                occurrences[key] = occurrence + 1
                let suffix = identifier?.components(separatedBy: ".").last?.lowercased() ?? ""
                result.append(ShelfItem(id: "\(bundle)/\(key)/\(occurrence)", name: name,
                                        bundleID: bundle, appName: appName, icon: app.icon,
                                        trayIcon: TrayIcon.image(for: app, identifier: identifier),
                                        symbol: isSystemExtra ? systemSymbols[suffix] ?? "menubar.rectangle" : nil,
                                        element: element, action: action))
            }
        }
        return result.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var values: CFArray?
        let keys = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, keys, .stopOnError, &values) == .success,
              let pair = values as? [CFTypeRef], pair.count == 2,
              CFGetTypeID(pair[0]) == AXValueGetTypeID(), CFGetTypeID(pair[1]) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(pair[0] as! AXValue, .cgPoint, &origin),
              AXValueGetValue(pair[1] as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func menuBar(at point: CGPoint, fallbackPID: pid_t?) -> AXUIElement? {
        // With separate Spaces, the menu on an inactive display can belong to
        // a different app. Ask for the menu at the Apple end of this display.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit {
            if text(hit, kAXRoleAttribute) == kAXMenuBarRole { return hit }
            if let parent = value(hit, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() {
                let bar = parent as! AXUIElement
                if text(bar, kAXRoleAttribute) == kAXMenuBarRole { return bar }
            }
        }
        guard let fallbackPID else { return nil }
        let app = AXUIElementCreateApplication(fallbackPID)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let raw = value(app, kAXMenuBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    enum MenuBarLayout {
        case visible([CGRect])
        case hidden
        case unavailable
    }

    // The band and AX/WindowServer frames are in global Quartz coordinates. Read
    // the underlying owners directly; a system hit test would hit our overlay.
    static func menuBarLayout(in band: CGRect, barOrigin: CGPoint, menuOwnerPID: pid_t?) -> MenuBarLayout {
        guard AXIsProcessTrusted() else { return .unavailable }
        if #available(macOS 27, *) {
            // While a full-screen menu bar is hidden (or sliding between Spaces),
            // its old AX geometry can still be returned. Only measure a bar
            // that WindowServer is actually displaying at this screen's origin.
            let level = Int(CGWindowLevelForKey(.mainMenuWindow))
            guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return .unavailable }
            let visible = windows.contains { row in
                guard row[kCGWindowLayer as String] as? Int == level,
                      let raw = row[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: raw) else { return false }
                return abs(rect.minX - barOrigin.x) < 1 && abs(rect.minY - barOrigin.y) < 1
                    && rect.height <= 64 && rect.contains(CGPoint(x: band.midX, y: band.midY))
            }
            guard visible else { return .hidden }
        }
        guard let bar = menuBar(at: CGPoint(x: barOrigin.x + 20, y: band.midY), fallbackPID: menuOwnerPID),
              let barFrame = frame(of: bar),
              let menus = value(bar, kAXChildrenAttribute) as? [AXUIElement] else { return .unavailable }
        var occupied = menus.compactMap(frame(of:)).map {
            $0.offsetBy(dx: barOrigin.x - barFrame.minX, dy: barOrigin.y - barFrame.minY)
        }

        if #available(macOS 27, *) {
            guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return .unavailable }
            let host = AXUIElementCreateApplication(agent.processIdentifier)
            AXUIElementSetMessagingTimeout(host, 0.15)
            guard let windows = value(host, kAXWindowsAttribute) as? [AXUIElement] else { return .unavailable }
            var foundBar = false
            for window in windows {
                guard let bar = frame(of: window), bar.height <= 64,
                      bar.intersects(band) else { continue }
                guard let entries = value(window, kAXChildrenAttribute) as? [AXUIElement] else { continue }
                foundBar = true
                occupied.append(contentsOf: entries.compactMap(frame(of:)))
            }
            guard foundBar else { return .unavailable }
        } else {
            guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return .unavailable }
            let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
            for window in windows where window[kCGWindowLayer as String] as? Int == statusLevel {
                guard window[kCGWindowOwnerPID as String] as? pid_t != getpid(),
                      let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
                occupied.append(rect)
            }
        }
        return .visible(occupied.filter { $0.insetBy(dx: -1, dy: 0).intersects(band) })
    }

    static func isPointerOnClock(_ point: NSPoint) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.08)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(primary.frame.maxY - point.y), &hit) == .success,
              let hit else { return false }
        let clock = "com.apple.menuextra.clock"
        if text(hit, kAXIdentifierAttribute) == clock { return true }
        guard text(hit, kAXRoleAttribute) == kAXGroupRole else { return false }
        return children(hit).contains { text($0, kAXIdentifierAttribute) == clock }
    }

    // AXPress has no display argument. The owner's extras bar may describe the
    // external display even while the pointer and shelf are on the MacBook.
    static func click(_ item: ShelfItem, on display: CGDirectDisplayID) -> Bool {
        guard AXIsProcessTrusted(), CGDisplayIsActive(display) != 0,
              let element = item.element else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return false }
        let bounds = CGDisplayBounds(display)
        var candidates = Set<CGPoint>()
        func add(_ rect: CGRect) {
            let center = CGPoint(x: rect.midX.rounded(), y: rect.midY.rounded())
            if bounds.contains(center), center.y < bounds.minY + 64 { candidates.insert(center) }
        }
        if let rect = frame(of: element), bounds.contains(rect), rect.midY < bounds.minY + 64 {
            add(rect)
        }

        if #available(macOS 27, *),
           let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first {
            let host = AXUIElementCreateApplication(agent.processIdentifier)
            AXUIElementSetMessagingTimeout(host, 0.15)
            for window in value(host, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                guard let bar = frame(of: window), bar.height <= 64,
                      bounds.contains(CGPoint(x: bar.midX, y: bar.midY)),
                      abs(bar.minY - bounds.minY) < 3 else { continue }
                for group in children(window) {
                    guard let rect = frame(of: group), bar.contains(CGPoint(x: rect.midX, y: rect.midY)),
                          children(group).contains(where: { child in
                              var owner: pid_t = 0
                              return AXUIElementGetPid(child, &owner) == .success && owner == pid
                          }) else { continue }
                    add(rect)
                }
            }
        } else {
            // Older systems expose status items as individual WindowServer windows.
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            for row in windows where row[kCGWindowOwnerPID as String] as? Int32 == pid &&
                row[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.statusWindow)) {
                if let raw = row[kCGWindowBounds as String] as? NSDictionary,
                   let rect = CGRect(dictionaryRepresentation: raw), rect.height <= 64 { add(rect) }
            }
        }

        let root = AXUIElementCreateApplication(pid)
        let extras = value(root, kAXExtrasMenuBarAttribute)
        let barItems = extras.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? children($0 as! AXUIElement) : nil } ?? []
        let unique = barItems.filter { text($0, kAXRoleAttribute) == kAXMenuBarItemRole }.count == 1
        let system = AXUIElementCreateSystemWide()
        for point in candidates {
            var raw: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &raw) == .success,
                  let hit = raw else { continue }
            var owner: pid_t = 0
            AXUIElementGetPid(hit, &owner)
            let role = text(hit, kAXRoleAttribute)
            let matched = CFEqual(hit, element) || (role == kAXGroupRole && children(hit).contains { CFEqual($0, element) })
            // The host sometimes reports the owner's AXMenuBar for a replica.
            // That identifies the item only when this owner has exactly one.
            guard matched || (unique && owner == pid && (role == kAXMenuBarRole || role == kAXMenuBarItemRole)) else { continue }
            guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return false }
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return true
        }
        return false
    }

    static func press(_ item: ShelfItem) -> AXError {
        guard let element = item.element else { return .invalidUIElement }
        AXUIElementSetMessagingTimeout(element, 0.6)
        return AXUIElementPerformAction(element, item.action as CFString)
    }
}
