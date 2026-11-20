import AppKit
import Combine
import CoreAudio

/// Observes transport notifications when a player provides them. Core Audio
/// supplies the initial local state and output changes for other media apps.
final class PlaybackMonitor: ObservableObject {
    @Published private(set) var isPlaying = false

    private(set) var activeMusicApp: String?

    private static let notifications = [
        "com.apple.Music.playerInfo": "com.apple.Music",
        "com.spotify.client.PlaybackStateChanged": "com.spotify.client"
    ]
    private static let mediaApps = [
        "com.apple.Music", "com.spotify.client", "com.apple.QuickTimePlayerX",
        "com.apple.TV", "com.apple.podcasts", "com.colliderli.iina", "org.videolan.vlc",
        "com.apple.Safari", "com.apple.WebKit.GPU", "com.google.Chrome", "org.mozilla.firefox",
        "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi"
    ]

    private var reported = [String: Bool]()
    private var sources = [AudioObjectID: String]()
    private var subscriptions = Set<AnyCancellable>()
    private var listListener: AudioObjectPropertyListenerBlock?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let system = AudioObjectID(kAudioObjectSystemObject)

    init() {
        for (name, bundle) in Self.notifications {
            DistributedNotificationCenter.default().publisher(for: Notification.Name(name))
                .receive(on: DispatchQueue.main)
                .sink { [weak self] note in
                    guard let self, let state = note.userInfo?["Player State"] as? String else { return }
                    switch state.lowercased() {
                    case "playing": self.reported[bundle] = true
                    case "paused", "stopped": self.reported[bundle] = false
                    default: return
                    }
                    self.refreshPlayback()
                }.store(in: &subscriptions)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let id = app.bundleIdentifier, self.reported.removeValue(forKey: id) != nil else { return }
                self.refreshPlayback()
            }.store(in: &subscriptions)
        workspace.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reported.removeAll()
                self?.refreshSources()
            }.store(in: &subscriptions)

        listListener = { [weak self] _, _ in self?.refreshSources() }
        outputListener = { [weak self] _, _ in self?.refreshPlayback() }
        var list = address(kAudioHardwarePropertyProcessObjectList)
        if let listListener {
            AudioObjectAddPropertyListenerBlock(system, &list, .main, listListener)
        }
        refreshSources()
    }

    deinit {
        var list = address(kAudioHardwarePropertyProcessObjectList)
        if let listListener { AudioObjectRemovePropertyListenerBlock(system, &list, .main, listListener) }
        var output = address(kAudioProcessPropertyIsRunningOutput)
        if let outputListener {
            for id in sources.keys { AudioObjectRemovePropertyListenerBlock(id, &output, .main, outputListener) }
        }
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func refreshSources() {
        var list = address(kAudioHardwarePropertyProcessObjectList)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &list, 0, nil, &bytes) == noErr else { return }
        let stride = MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: Int(bytes) / stride)
        if !ids.isEmpty {
            let status = ids.withUnsafeMutableBytes { buffer in
                AudioObjectGetPropertyData(system, &list, 0, nil, &bytes, buffer.baseAddress!)
            }
            guard status == noErr else { return }
        }

        var next = [AudioObjectID: String]()
        for id in ids.prefix(Int(bytes) / stride) {
            var name = address(kAudioProcessPropertyBundleID)
            var raw: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout.size(ofValue: raw))
            guard AudioObjectGetPropertyData(id, &name, 0, nil, &size, &raw) == noErr,
                  let bundle = raw?.takeRetainedValue() as String? else { continue }
            // Chromium-based players may output through a helper process.
            if let owner = Self.mediaApps.first(where: { bundle == $0 || bundle.hasPrefix($0 + ".") }) {
                next[id] = owner
            }
        }
        var output = address(kAudioProcessPropertyIsRunningOutput)
        if let outputListener {
            for id in sources.keys where next[id] == nil {
                AudioObjectRemovePropertyListenerBlock(id, &output, .main, outputListener)
            }
            for id in next.keys where sources[id] == nil {
                AudioObjectAddPropertyListenerBlock(id, &output, .main, outputListener)
            }
        }
        sources = next
        refreshPlayback()
    }

    private func refreshPlayback() {
        var playingApps = Set(reported.filter { $0.value }.keys)
        for (id, bundle) in sources {
            // A paused player can keep an output stream open for a while.
            guard reported[bundle] == nil else { continue }
            var output = address(kAudioProcessPropertyIsRunningOutput)
            var active: UInt32 = 0
            var size = UInt32(MemoryLayout.size(ofValue: active))
            if AudioObjectGetPropertyData(id, &output, 0, nil, &size, &active) == noErr && active != 0 { playingApps.insert(bundle) }
        }
        if let owner = ["com.apple.Music", "com.spotify.client"].first(where: playingApps.contains) { activeMusicApp = owner }
        let playing = !playingApps.isEmpty
        if playing != isPlaying { isPlaying = playing }
    }
}
