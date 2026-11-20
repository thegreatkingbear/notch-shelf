import SwiftUI
import IOKit.hidsystem

private struct Song {
    var title: String
    var artist: String
    var art: NSImage?
    var coverURL: URL?
    var key: String
    var duration: Double
    var position: Double
    var playing: Bool
    let sampled = Date()

    func elapsed(at date: Date) -> Double {
        min(duration, max(0, position + (playing ? date.timeIntervalSince(sampled) : 0)))
    }
}

@MainActor
private final class MusicDetails: ObservableObject {
    @Published var player: String?
    @Published var permission = Int32(errAEEventWouldRequireUserConsent)
    @Published var song: Song?
    @Published var requesting = false
    private let queue = DispatchQueue(label: "NotchShelf.music")
    private var busy = false
    private var scheduled = false
    private var nextArtworkAttempt = Date.distantPast

    func refresh(_ preferred: String?, ask: Bool = false) {
        guard !busy else { if ask { scheduled = true }; return }
        let available = ["com.apple.Music", "com.spotify.client"].filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
        let target = preferred.flatMap { available.contains($0) ? $0 : nil } ?? available.first
        if target != player { player = target; song = nil; permission = Int32(errAEEventWouldRequireUserConsent) }
        guard let target else { return }
        busy = true
        requesting = ask
        let previous = song
        let retryArtwork = previous?.art == nil && previous?.coverURL == nil && Date() >= nextArtworkAttempt
        let cachedKey = retryArtwork ? nil : previous?.key
        queue.async {
            let access = PlayerReader.permission(for: target, ask: ask)
            let row = access == noErr ? PlayerReader.read(target, previousArtworkKey: cachedKey) : nil
            var next: Song?
            if let row, let title = row["name"] as? String, let key = row["key"] as? String {
                let same = key == previous?.key
                let art = (row["art"] as? Data).flatMap(NSImage.init(data:)) ?? (same ? previous?.art : nil)
                let url = (row["url"] as? String).flatMap(URL.init(string:)) ?? (same ? previous?.coverURL : nil)
                next = Song(title: title, artist: row["artist"] as? String ?? "", art: art, coverURL: url,
                            key: key, duration: row["duration"] as? Double ?? 0, position: row["position"] as? Double ?? 0,
                            playing: row["playing"] as? Bool ?? false)
            }
            DispatchQueue.main.async {
                if next?.key != cachedKey { self.nextArtworkAttempt = Date().addingTimeInterval(12) }
                self.permission = access
                self.song = next
                self.busy = false
                self.requesting = false
                if self.scheduled { self.scheduled = false; self.refresh(preferred, ask: true) }
            }
        }
    }

    func seek(_ position: Double) {
        guard let player, permission == noErr, let song, song.duration > 0 else { return }
        let seconds = min(song.duration, max(0, position))
        queue.async {
            PlayerReader.seek(player, seconds: seconds)
            DispatchQueue.main.async { self.refresh(player) }
        }
    }

    func control(_ command: String) {
        guard let player, permission == noErr else { return }
        queue.async {
            PlayerReader.control(player, command: command)
            DispatchQueue.main.async { self.refresh(player) }
        }
    }
}

struct MusicCard: View {
    let active: Bool
    @ObservedObject var playback: PlaybackMonitor
    @StateObject private var details = MusicDetails()
    @State private var scrubbing: Double?

    var body: some View {
        GeometryReader { geo in
            let cover = min(94, geo.size.height - 12, geo.size.width * 0.26)
            HStack(spacing: geo.size.width > 220 ? 15 : 6) {
                if geo.size.width > 190 {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.09))
                        Image(systemName: "music.note").foregroundStyle(.secondary).font(.title)
                        if let art = details.song?.art {
                            Image(nsImage: art).resizable().scaledToFill()
                        } else if let url = details.song?.coverURL, url.scheme == "https" {
                            AsyncImage(url: url) { phase in phase.image?.resizable().scaledToFill() }
                        }
                    }.frame(width: max(1,cover), height: max(1,cover)).clipShape(RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 5) {
                    if let song = details.song {
                        Text(song.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(song.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        TimelineView(.periodic(from: .now, by: 1)) { tick in
                            let elapsed = scrubbing ?? song.elapsed(at: tick.date)
                            VStack(spacing: 3) {
                                GeometryReader { bar in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.white.opacity(0.19))
                                        Capsule().fill(.white.opacity(0.78))
                                            .frame(width: bar.size.width * (song.duration > 0 ? elapsed / song.duration : 0))
                                    }.frame(height: 3)
                                     .frame(maxHeight: .infinity)
                                     .contentShape(Rectangle())
                                     .gesture(DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            scrubbing = song.duration * min(1, max(0, value.location.x / max(1, bar.size.width)))
                                        }
                                        .onEnded { _ in
                                            if let scrubbing { details.seek(scrubbing) }
                                            scrubbing = nil
                                        })
                                }.frame(height: 10)
                                HStack {
                                    Text(clock(elapsed))
                                    Spacer()
                                    Text(clock(song.duration))
                                }.font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }.padding(.top, 2)
                         .accessibilityElement(children: .ignore)
                         .accessibilityLabel("Playback Position")
                         .accessibilityValue("\(clock(song.elapsed(at: .now))) / \(clock(song.duration))")
                         .accessibilityAdjustableAction { direction in
                             details.seek(song.elapsed(at: .now) + (direction == .increment ? 5 : -5))
                         }
                    } else if let player = details.player, details.permission != noErr {
                        Text(player == "com.apple.Music" ? "Apple Music" : "Spotify").font(.headline)
                        Button(details.permission == errAEEventNotPermitted ? String(localized: "Open Automation Settings") : String(localized: "Connect Player")) {
                            if details.permission == errAEEventNotPermitted {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
                            } else { details.refresh(player, ask: true) }
                        }.controlSize(.small).disabled(details.requesting)
                    } else {
                        Text("Nothing is playing").font(.headline)
                    }
                    HStack(spacing: 15) {
                        transport("backward.fill", String(localized: "Previous Track"), "previous", NX_KEYTYPE_PREVIOUS)
                        transport((details.song?.playing ?? playback.isPlaying) ? "pause.fill" : "play.fill",
                                  (details.song?.playing ?? playback.isPlaying) ? String(localized: "Pause") : String(localized: "Play"), "toggle", NX_KEYTYPE_PLAY)
                        transport("forward.fill", String(localized: "Next Track"), "next", NX_KEYTYPE_NEXT)
                    }.frame(maxWidth: .infinity).padding(.top, 2)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: active) {
            if active || details.player == nil { details.refresh(playback.activeMusicApp) }
            guard active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                details.refresh(playback.activeMusicApp)
            }
        }
    }

    private func clock(_ t: Double) -> String {
        let s = t.isFinite ? Int(max(0, min(t, 999999))) : 0
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func transport(_ symbol: String, _ title: String, _ command: String, _ key: Int32) -> some View {
        Button {
            if details.song != nil { details.control(command) } else { MediaKey.send(key) }
        } label: {
            Image(systemName: symbol).font(.system(size: 13, weight: .bold)).frame(width: 24, height: 22)
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}
