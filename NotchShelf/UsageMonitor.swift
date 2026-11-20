import AppKit
import Combine
import Darwin

struct UsageSample: Equatable {
    let percent: Double
    let windowMinutes: Int
    let observed: Date
    var reset: Date? = nil

    var current: Bool {
        Date().timeIntervalSince(observed) < 30 * 60 && (reset.map { $0 > Date() } ?? true)
    }

    var period: String {
        switch windowMinutes {
        case 10080: return String(localized: "Weekly")
        case let minutes where minutes > 0:
            let unit: Duration.UnitsFormatStyle.Unit = minutes.isMultiple(of: 60) ? .hours : .minutes
            return Duration.seconds(Double(minutes) * 60).formatted(.units(allowed: [unit], width: .wide))
        default: return String(localized: "Current limit")
        }
    }

    func resetDetail(at now: Date) -> String {
        guard let reset else { return String(localized: "Reset time unavailable") }
        let remaining = reset.timeIntervalSince(now)
        guard remaining > 0 else { return String(localized: "Reset time passed · awaiting update") }
        guard remaining >= 60 else { return String(localized: "Resets in less than a minute") }
        let duration = Duration.seconds(remaining.rounded(.down))
        let format = Duration.UnitsFormatStyle(allowedUnits: [.days, .hours, .minutes], width: .wide,
                                              maximumUnitCount: 2, fractionalPart: .hide(rounded: .down))
        return String(localized: "Resets in \(duration.formatted(format))")
    }
}

final class UsageMonitor: ObservableObject {
    private static let services: [WingWidget] = [.claude, .codex]
    @Published private var samples = [WingWidget: [UsageSample]]()
    private let preferences: WingPreferences
    private var timer: Timer?
    private var changes: AnyCancellable?
    private var wake: AnyCancellable?
    private var login: Process?
    @Published private(set) var claudeConnection = ClaudeUsage.Connection.checking
    @Published private(set) var connecting = false
    private var busy = Set<WingWidget>()
    private var refreshAfterRead = Set<WingWidget>()
    private var next = [WingWidget: Date]()
    private var settingsVisible = false

    init(preferences: WingPreferences) {
        self.preferences = preferences
        changes = preferences.$layout.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
        wake = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.next.removeAll(); self?.refresh() }
        let tick = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.samples.isEmpty { self.objectWillChange.send() }
            self.refresh()
        }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
        refresh()
    }

    deinit {
        timer?.invalidate()
        if let login, login.isRunning { login.terminate() }
    }

    func settings(_ visible: Bool) {
        settingsVisible = visible
        if visible { refresh() }
    }

    func sample(_ widget: WingWidget) -> UsageSample? {
        let windows = samples[widget] ?? []
        return windows.first(where: \.current) ?? windows.first
    }

    func detail(_ widget: WingWidget) -> String {
        guard let value = sample(widget) else {
            return widget == .claude ? claudeConnection.detail : String(localized: "Waiting for Codex limits")
        }
        return summary(value, for: widget)
    }

    func tooltip(_ widget: WingWidget) -> String {
        guard let windows = samples[widget], !windows.isEmpty else { return widget.title + " · " + detail(widget) }
        let now = Date()
        let lines = windows.map { summary($0, for: widget) + " · " + $0.resetDetail(at: now) }
        return widget.title + " · " + lines.joined(separator: "\n")
    }

    var combinedTooltip: String {
        Self.services.map(tooltip).joined(separator: "\n\n")
    }

    private func summary(_ value: UsageSample, for widget: WingWidget) -> String {
        let percent = (value.percent / 100).formatted(.percent.precision(.fractionLength(0)))
        let text = value.period + " · " + String(localized: "\(percent) used")
        if value.current { return text }
        if widget == .claude && claudeConnection == .needsLogin { return String(localized: "Connect account · last recorded: \(text)") }
        return String(localized: "Last recorded · \(text)")
    }

    func connectClaude() {
        guard login == nil else { return }
        guard let cli = ClaudeUsage.executable() else {
            NSWorkspace.shared.open(URL(string: "https://code.claude.com/docs/en/setup")!)
            return
        }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["auth", "login", "--claudeai"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.login === finished else { return }
                self.login = nil
                self.connecting = false
                if finished.terminationStatus == 0 {
                    self.next.removeValue(forKey: .claude)
                    self.read(.claude, force: true)
                } else { self.claudeConnection = .needsLogin }
            }
        }
        login = process
        do {
            try process.run()
            connecting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak process] in
                if let process, process.isRunning { process.terminate() }
            }
        } catch { login = nil; claudeConnection = .unavailable }
    }

    func openClaudeUsage() {
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") != nil
        if let url = URL(string: installed ? "claude://claude.ai/settings/usage" : "https://claude.ai/settings/usage") {
            NSWorkspace.shared.open(url)
        }
        if installed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.read(.claude, force: true) }
        }
    }

    func refresh(force: Bool = false) {
        let assigned = preferences.layout.left + preferences.layout.right
        guard settingsVisible || force || Self.services.contains(where: assigned.contains) else { return }
        for widget in Self.services {
            read(widget, force: force)
        }
    }

    private func read(_ widget: WingWidget, force: Bool) {
        if busy.contains(widget) {
            if force { refreshAfterRead.insert(widget) }
            return
        }
        guard force || Date() >= next[widget, default: .distantPast] else { return }
        busy.insert(widget)
        next[widget] = Date().addingTimeInterval(widget == .codex ? 120 : 300)
        DispatchQueue.global(qos: .utility).async {
            let claude = widget == .claude ? ClaudeUsage.fetch() : nil
            let windows = claude?.0 ?? CodexUsage.read()
            DispatchQueue.main.async {
                self.busy.remove(widget)
                if let claude {
                    self.claudeConnection = claude.1
                    if claude.1 == .needsLogin && self.settingsVisible {
                        self.next[widget] = Date().addingTimeInterval(30)
                    }
                }
                if let first = windows.first, first.observed >= (self.samples[widget]?.first?.observed ?? .distantPast) {
                    self.samples[widget] = windows
                } else {
                    // Allow a previously valid ring to expire even on failed refreshes.
                    self.objectWillChange.send()
                }
                if self.refreshAfterRead.remove(widget) != nil { self.read(widget, force: true) }
            }
        }
    }
}

enum ClaudeUsage {
    enum Connection {
        case checking, connected, needsLogin, notInstalled, unavailable
        var detail: String {
            switch self {
            case .checking: return String(localized: "Checking Claude limits")
            case .connected: return String(localized: "Claude subscription connected")
            case .needsLogin: return String(localized: "Connect your Claude subscription account")
            case .notInstalled: return String(localized: "Install Claude Code to connect")
            case .unavailable: return String(localized: "Waiting for Claude limits")
            }
        }
    }

    static func executable() -> URL? {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser
        let standalone = [home.appendingPathComponent(".local/bin/claude"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude")]
        if let cli = standalone.first(where: { files.isExecutableFile(atPath: $0.path) }) { return cli }
        let desktop = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = (try? files.contentsOfDirectory(at: desktop, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for version in versions.sorted(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }) {
            let builds = (try? files.contentsOfDirectory(at: version, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for build in builds {
                let cli = build.appendingPathComponent("claude.app/Contents/MacOS/claude")
                if files.isExecutableFile(atPath: cli.path) { return cli }
            }
        }
        return nil
    }

    private struct Envelope: Decodable {
        struct Payload: Decodable {
            struct Usage: Decodable {
                struct Window: Decodable {
                    let utilization: Double?
                    let resets_at: String?
                }
                struct Windows: Decodable {
                    let five_hour: Window?
                    let seven_day: Window?
                }
                let rate_limits_available: Bool
                let subscription_type: String?
                let rate_limits: Windows?
            }
            let response: Usage?
        }
        let response: Payload
    }

    static func decode(_ data: Data) -> ([UsageSample], Connection) {
        guard let reply = (try? JSONDecoder().decode(Envelope.self, from: data))?.response.response else { return ([], .unavailable) }
        guard reply.rate_limits_available else { return ([], reply.subscription_type == nil ? .needsLogin : .unavailable) }
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        let now = Date()
        var windows: [UsageSample] = []
        for (window, minutes) in [(reply.rate_limits?.five_hour, 300), (reply.rate_limits?.seven_day, 10080)] {
            guard let window, let pct = window.utilization, (0...100).contains(pct) else { continue }
            let reset = window.resets_at.flatMap { fractional.date(from: $0) ?? iso.date(from: $0) }
            windows.append(UsageSample(percent: pct, windowMinutes: minutes, observed: now, reset: reset))
        }
        return (windows, windows.isEmpty ? .unavailable : .connected)
    }

    static func fetch() -> ([UsageSample], Connection) {
        guard let cli = executable() else { return (read(), .notInstalled) }
        let data = UsageCLI.exchange(cli, ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                                           "--no-session-persistence", "--safe-mode", "--strict-mcp-config", "--tools", ""],
            initialize: #"{"type":"control_request","request_id":"notch-init","request":{"subtype":"initialize"}}"#,
            queries: [#"{"type":"control_request","request_id":"notch-usage","request":{"subtype":"get_usage","skip_behaviors":true}}"#]) { message in
                guard message["type"] as? String == "control_response", let reply = message["response"] as? [String: Any] else { return .other }
                switch reply["request_id"] as? String {
                case "notch-init": return reply["subtype"] as? String == "success" ? .initialized : .failed
                case "notch-usage": return .result
                default: return .other
                }
            }
        let (windows, state) = data.map(decode) ?? ([], .unavailable)
        return (windows.isEmpty ? read() : windows, state)
    }
    private struct History: Decodable {
        struct Sample: Decodable {
            let t: Double
            let u: [String: Double]?
            let fh: Double?
            let sd: Double?
        }
        let samples: [Sample]
    }

    static func read() -> [UsageSample] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        let cached = (try? Data(contentsOf: url)).map(history) ?? []
        if let first = cached.first, Date().timeIntervalSince(first.observed) < 60 { return cached }
        let displayed = screenReading()
        return displayed.isEmpty ? cached : displayed
    }

    static func history(_ data: Data) -> [UsageSample] {
        guard let last = (try? JSONDecoder().decode(History.self, from: data))?.samples.max(by: { $0.t < $1.t }) else { return [] }
        let date = Date(timeIntervalSince1970: last.t / 1000)
        guard date <= Date().addingTimeInterval(60) else { return [] }
        return [(300, last.u?["fh"] ?? last.fh), (10080, last.u?["sd"] ?? last.sd)].compactMap { minutes, value in
            guard let value, (0...100).contains(value) else { return nil }
            return UsageSample(percent: value, windowMinutes: minutes, observed: date)
        }
    }

    // Read only labelled usage meters in Claude's own web surface. A closed
    // settings page simply leaves the last dated sample in place.
    private static func screenReading() -> [UsageSample] {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return value
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        var remaining = 1400
        let now = Date()
        var windows: [Int: UsageSample] = [:]
        func find(_ element: AXUIElement, depth: Int, inClaude: Bool) {
            guard windows.count < 2, remaining > 0, depth < 32, ProcessInfo.processInfo.systemUptime < deadline else { return }
            remaining -= 1
            let role = attribute(element, kAXRoleAttribute) as? String
            var inside = inClaude
            if role == "AXWebArea" { inside = (attribute(element, kAXURLAttribute) as? URL)?.host == "claude.ai" }
            if inside && (role == "AXLevelIndicator" || role == "AXProgressIndicator") {
                let label = (attribute(element, kAXTitleAttribute) as? String ?? "").lowercased()
                let session = ["current session", "현재 세션", "現在のセッション", "当前会话", "目前的工作階段", "session actuelle", "aktuelle sitzung", "текущий сеанс", "текущая сессия"].contains(label)
                let week = ["this week", "weekly limits", "이번 주", "주간 한도", "今週", "週間上限", "本周", "每周限额", "本週", "每週限額", "cette semaine", "limites hebdomadaires", "diese woche", "wöchentliche limits", "эта неделя", "недельные лимиты"].contains(label)
                if session || week, let text = attribute(element, kAXValueAttribute) as? String,
                   let range = text.range(of: #"[0-9]+(?:[.,][0-9]+)?\s*(?=%)"#, options: .regularExpression),
                   let value = Double(text[range].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
                   (0...100).contains(value) {
                    let minutes = session ? 300 : 10080
                    windows[minutes] = UsageSample(percent: value, windowMinutes: minutes, observed: now)
                }
            }
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                find(child, depth: depth + 1, inClaude: inside)
            }
        }
        for window in attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            find(window, depth: 0, inClaude: false)
            if !windows.isEmpty { break }
        }
        return [300, 10080].compactMap { windows[$0] }
    }
}

enum CodexUsage {
    private struct Reply: Decodable {
        struct Rate: Decodable {
            struct Window: Decodable {
                let usedPercent: Double
                let windowDurationMins: Int?
                let resetsAt: Double?
            }
            let primary: Window?
            let secondary: Window?
        }
        struct Result: Decodable {
            let rateLimits: Rate?
            let rateLimitsByLimitId: [String: Rate]?
        }
        let result: Result?
    }

    static func windows(_ line: Data) -> [UsageSample] {
        guard let result = (try? JSONDecoder().decode(Reply.self, from: line))?.result,
              let limit = result.rateLimitsByLimitId?["codex"] ?? result.rateLimits else { return [] }
        let now = Date()
        let windows = [limit.primary, limit.secondary].compactMap { value -> UsageSample? in
            guard let value, (0...100).contains(value.usedPercent) else { return nil }
            return UsageSample(percent: value.usedPercent, windowMinutes: value.windowDurationMins ?? 0,
                               observed: now, reset: value.resetsAt.map(Date.init(timeIntervalSince1970:)))
        }
        return windows.sorted { $0.windowMinutes == 300 && $1.windowMinutes != 300 }
    }

    static func read() -> [UsageSample] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [URL]()
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            paths += ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"].map(app.appendingPathComponent)
        }
        paths += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"].map { URL(fileURLWithPath: $0) }
        paths.append(home.appendingPathComponent(".local/bin/codex"))
        guard let cli = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return [] }
        let lines = UsageCLI.exchange(cli, ["app-server", "--listen", "stdio://"],
            initialize: #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"notch_shelf","version":"1.0"}}}"#,
            queries: [#"{"method":"initialized"}"#, #"{"id":2,"method":"account/rateLimits/read","params":null}"#]) { message in
                switch message["id"] as? Int {
                case 1: return message["error"] == nil ? .initialized : .failed
                case 2: return .result
                default: return .other
                }
            }
        return lines.map(windows) ?? []
    }
}

private enum UsageCLI {
    enum Reply { case initialized, result, failed, other }

    static func exchange(_ executable: URL, _ arguments: [String], initialize: String, queries: [String],
                         identify: ([String: Any]) -> Reply) -> Data? {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        func send(_ json: String) throws {
            try input.fileHandleForWriting.write(contentsOf: Data((json + "\n").utf8))
        }
        do {
            try send(initialize)
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            var buffer = Data(), bytes = [UInt8](repeating: 0, count: 8192)
            var sent = false
            while ProcessInfo.processInfo.systemUptime < deadline && buffer.count < 1_048_576 {
                let ms = Int32(max(1, (deadline - ProcessInfo.processInfo.systemUptime) * 1000))
                let polled = poll(&fd, 1, ms)
                if polled == -1 && errno == EINTR { continue }
                guard polled > 0 else { return nil }
                let n = Darwin.read(fd.fd, &bytes, bytes.count)
                guard n > 0 else { return nil }
                buffer.append(contentsOf: bytes.prefix(n))
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    switch identify(message) {
                    case .initialized where !sent:
                        for query in queries { try send(query) }
                        sent = true
                    case .result where sent: return line
                    case .failed: return nil
                    default: continue
                    }
                }
            }
        } catch { return nil }
        return nil
    }
}
