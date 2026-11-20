import SwiftUI

// Keep the top attached to the menu bar. The middle of the lower edge
// leads the corners in transit, then settles into a flat edge at rest.
private struct ShelfOutline: Shape {
    var progress: CGFloat
    let collapsedWidth: CGFloat
    let openHeight: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = min(max(progress, 0), 1)
        let width = collapsedWidth + (rect.width - collapsedWidth) * (1 - pow(1 - p, 2))
        let bottom = min(rect.height, max(0, progress * openHeight))
        let bow = 12 * sin(.pi * p)
        let side = max(0, bottom - bow)
        let radius = min(23, side, width / 2)
        let left = rect.midX - width / 2, right = rect.midX + width / 2
        return Path { path in
            path.move(to: CGPoint(x: left, y: 0))
            path.addLine(to: CGPoint(x: right, y: 0))
            path.addLine(to: CGPoint(x: right, y: side - radius))
            path.addQuadCurve(to: CGPoint(x: right - radius, y: side), control: CGPoint(x: right, y: side))
            path.addQuadCurve(to: CGPoint(x: left + radius, y: side), control: CGPoint(x: rect.midX, y: side + 2 * bow))
            path.addQuadCurve(to: CGPoint(x: left, y: side - radius), control: CGPoint(x: left, y: side))
            path.closeSubpath()
        }
    }
}

struct ShelfView: View {
    static let springRoom: CGFloat = 20
    @ObservedObject var model: ShelfModel
    @ObservedObject var playback: PlaybackMonitor
    let notchWidth: CGFloat
    let openHeight: CGFloat
    let openSettings: () -> Void
    let openPermissionSettings: () -> Void

    @State private var selectedCard = ShelfCard.music
    @StateObject private var reminders = ReminderList()
    @StateObject private var notes = NoteLibrary()

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .top) {
                Color.black
                VStack(spacing: 2) {
                    HStack(spacing: 5) {
                        if model.managing {
                            Text("Arrange Apps").font(.headline)
                            Spacer()
                            Button("Done") { model.managing = false }.controlSize(.small)
                        } else if model.trusted {
                            TrayStrip(items: model.visibleItems) { model.onChoose?($0) }
                        } else { Spacer() }
                        settings
                    }.padding(.leading, 9).padding(.trailing, 11).frame(height: 30)
                    if model.managing && model.trusted {
                        ScrollView {
                            LazyVStack(spacing: 3) {
                                ForEach(model.apps) { app in placementRow(app) }
                            }
                        }.padding(.horizontal, 12)
                    } else if !model.trusted {
                        emptyState("hand.raised", String(localized: "Allow Menu Bar Access"),
                                   String(localized: "In Settings, enable NotchShelf.app under “\(ShelfModel.permissionPaneName)”.")) {
                            Button("Open Permission Settings", action: openPermissionSettings)
                                .buttonStyle(.borderedProminent)
                        }
                    } else if model.expanded {
                        InfoDeck(playback: playback, selection: $selectedCard, reminders: reminders, notes: notes)
                    } else { Spacer() }
                    if let message = model.layoutError ?? model.message {
                        Text(message).font(.caption).foregroundStyle(.yellow)
                            .lineLimit(2).padding(.horizontal, 12)
                    }
                }
                .padding(.top, 1).padding(.bottom, 6)
                .frame(width: width, height: openHeight, alignment: .top)
                .opacity(model.expanded ? 1 : 0)
            }
            .mask(ShelfOutline(progress: model.expanded ? 1 : 0, collapsedWidth: notchWidth, openHeight: openHeight))
        }
        .preferredColorScheme(.dark)
    }

    private func placementRow(_ app: PlacementApp) -> some View {
        let inNotch = model.destinations[app.id] != nil
        return Button {
            model.move(app)
        } label: {
            HStack(spacing: 9) {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 21, height: 21)
                } else {
                    Image(systemName: "app").frame(width: 21)
                }
                Text(app.name).lineLimit(1)
                Spacer()
                Label(inNotch ? String(localized: "Notch") : String(localized: "Menu Bar"), systemImage: inNotch ? "tray.fill" : "menubar.rectangle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(inNotch ? Color.mint : Color.secondary)
            }
            .padding(.horizontal, 9).frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.name + ", " + (inNotch ? String(localized: "Move to Menu Bar") : String(localized: "Move to Notch")))
        .help(inNotch ? String(localized: "Move to Menu Bar") : String(localized: "Move to Notch"))
    }

    private var settings: some View {
        Menu {
            if model.trusted && model.supportsPlacement {
                Button(model.managing ? String(localized: "Finish Arranging Apps") : String(localized: "Arrange Apps")) {
                    model.managing.toggle()
                    if model.managing { model.refresh(force: true) }
                }
            }
            Button("Refresh") { model.message = nil; model.refresh(force: true) }
                .disabled(!model.trusted || model.loading)
            Button("Settings…", action: openSettings)
            Divider()
            Button("Quit Notch Shelf") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape.fill").font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
         .accessibilityLabel("Settings Menu")
    }

    private func emptyState<Content: View>(_ symbol: String, _ title: String, _ detail: String,
                                           @ViewBuilder action: () -> Content) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            action()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
