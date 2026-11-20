import SwiftUI

enum WingWidget: Codable, Identifiable, Hashable {
    case claude, codex, playback, thermal
    case tray(item: String, bundle: String, name: String)

    static let builtins: [Self] = [.claude, .codex, .playback, .thermal]

    var id: String {
        switch self {
        case .claude: return "usage.claude"
        case .codex: return "usage.codex"
        case .playback: return "media.playback"
        case .thermal: return "system.thermal"
        case .tray(let item, _, _): return "tray." + item
        }
    }

    var title: String {
        switch self {
        case .claude: return String(localized: "Claude Usage")
        case .codex: return String(localized: "Codex Usage")
        case .playback: return String(localized: "Play / Pause")
        case .thermal: return String(localized: "Mac Thermal State")
        case .tray(_, _, let name): return name
        }
    }

    static func tray(_ item: ShelfItem) -> Self {
        .tray(item: item.id, bundle: item.bundleID, name: item.name)
    }
}

enum WingColumn: String, CaseIterable {
    case left, library, right
    var title: String {
        switch self { case .left: return String(localized: "Left"); case .library: return String(localized: "Widgets and Apps"); case .right: return String(localized: "Right") }
    }
}

struct WingLayout: Codable, Equatable {
    var left: [WingWidget] = [.claude, .codex]
    var right: [WingWidget] = [.playback]

    func items(_ side: WingColumn) -> [WingWidget] { side == .left ? left : right }

    mutating func move(_ widget: WingWidget, to side: WingColumn, before anchor: String? = nil) {
        guard anchor != widget.id else { return }
        left.removeAll { $0.id == widget.id }
        right.removeAll { $0.id == widget.id }
        guard side != .library else { return }
        var list = items(side)
        let insertion = list.firstIndex { $0.id == anchor } ?? list.endIndex
        list.insert(widget, at: insertion)
        if side == .left { left = list } else { right = list }
    }
}

final class WingPreferences: ObservableObject {
    static let rotationSeconds = 6
    private let defaults: UserDefaults
    private static let key = "wingWidgetLayout.v1"
    @Published private(set) var layout: WingLayout

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(WingLayout.self, from: $0) } ?? WingLayout()
    }

    func move(_ item: WingWidget, to side: WingColumn, before anchor: String? = nil) {
        var next = layout
        next.move(item, to: side, before: anchor)
        guard next != layout, let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: Self.key)
        layout = next
    }
}

struct WingSettings: View {
    @ObservedObject var preferences: WingPreferences
    @ObservedObject var model: ShelfModel
    @ObservedObject var usage: UsageMonitor
    let openPermissions: () -> Void
    @State private var dropColumn: WingColumn?

    private var library: [WingWidget] {
        let eligible = Set(model.apps.map(\.id))
        let shelf = model.visibleItems.filter { eligible.contains($0.bundleID) }
        let represented = Set(shelf.map(\.bundleID))
        let others = model.items.filter { eligible.contains($0.bundleID) && !represented.contains($0.bundleID) }
        return WingWidget.builtins + (shelf + others).map(WingWidget.tray)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Collapsed Notch").font(.title2.bold())
            Text("Drag items from the center to either side. Items on the same side appear in order, switching every \(WingPreferences.rotationSeconds) seconds.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                ForEach(WingColumn.allCases, id: \.self) { side in column(side) }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack {
                    usageButtons
                    Spacer()
                    permissionsButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack { usageButtons }
                    permissionsButton
                }
            }.controlSize(.small)
        }
        .padding(20)
        .frame(minWidth: 650, minHeight: 360)
    }

    @ViewBuilder private var usageButtons: some View {
        if usage.claudeConnection != .connected {
            let title = usage.claudeConnection == .notInstalled
                ? String(localized: "Install Claude Code…") : String(localized: "Connect Claude Account…")
            Button(usage.connecting ? String(localized: "Connecting to Claude…") : title) {
                usage.connectClaude()
            }.disabled(usage.connecting)
        }
        Button("Open Claude Usage") { usage.openClaudeUsage() }
        Button("Refresh Usage") { usage.refresh(force: true) }
    }

    private var permissionsButton: some View {
        Button("Accessibility Settings…", action: openPermissions)
    }

    private func entries(_ side: WingColumn) -> [WingWidget] {
        side == .library ? library : preferences.layout.items(side)
    }

    private func accept(_ ids: [String], side: WingColumn, before: String? = nil) -> Bool {
        let choices = library + preferences.layout.left + preferences.layout.right
        guard ids.count == 1, let widget = choices.first(where: { $0.id == ids[0] }) else { return false }
        preferences.move(widget, to: side, before: before)
        return true
    }

    private func column(_ side: WingColumn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(side.title).font(.headline).padding(.leading, 4)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(entries(side)) { item in
                        HStack(spacing: 7) {
                            WidgetGlyph(item: item, usage: usage.sample(item), playing: false)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.callout).lineLimit(1)
                                if side == .library && (item == .claude || item == .codex) {
                                    Text(usage.detail(item)).font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).frame(minHeight: 35)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                        .draggable(item.id)
                        .dropDestination(for: String.self) { ids, _ in accept(ids, side: side, before: side == .library ? nil : item.id) }
                        .contextMenu {
                            Button("Move Left") { preferences.move(item, to: .left) }
                            Button("Move Right") { preferences.move(item, to: .right) }
                            if side != .library { Button("Remove from Notch") { preferences.move(item, to: .library) } }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.title)
                        .accessibilityValue(item == .claude || item == .codex ? usage.detail(item) : "")
                        .accessibilityAction(named: "Move Left") { preferences.move(item, to: .left) }
                        .accessibilityAction(named: "Move Right") { preferences.move(item, to: .right) }
                        .accessibilityAction(named: "Remove from Notch") { preferences.move(item, to: .library) }
                    }
                    if entries(side).isEmpty { Text("Drop Here").font(.caption).foregroundStyle(.secondary).padding(.vertical, 12) }
                }.padding(5).frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(dropColumn == side ? Color.accentColor : Color.secondary.opacity(0.22)) .allowsHitTesting(false) }
            .dropDestination(for: String.self) { ids, _ in accept(ids, side: side) } isTargeted: { over in
                if over { dropColumn = side } else if dropColumn == side { dropColumn = nil }
            }
        }.frame(maxWidth: .infinity)
    }
}
